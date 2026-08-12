# rack-engine/backend/app/main.py
# CogniForge Rack Engine - FastAPI backend.
#
# REST API consumed by the React frontend:
#   GET  /modules                        list available pipeline modules
#   POST /modules                        register a module definition
#   POST /pipelines                      submit a pipeline graph to Argo
#   GET  /pipelines/{id}                 pipeline definition
#   GET  /pipelines/{id}/status          Argo workflow phase
#   GET  /pipelines/{id}/output          download the produced video
#   WS   /ws                             real-time status broadcasts
import asyncio
import json
import os
import uuid
from contextlib import asynccontextmanager

import yaml
from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse

from . import scheduler
from .models import ModuleRegister, Pipeline
from .websocket import ConnectionManager


@asynccontextmanager
async def lifespan(_app: FastAPI):
    _load_module_files()
    yield


app = FastAPI(title="CogniForge Rack Engine", version="1.0.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

manager = ConnectionManager()

PIPELINES: dict[str, dict] = {}

# --- Module definitions -----------------------------------------------------
DEFAULT_MODULES = [
    {"id": "input", "name": "Image Input", "category": "data", "icon": "image"},
    {"id": "wan21", "name": "Wan 2.1 Video Generator", "category": "generation", "icon": "video"},
    {"id": "stub-video", "name": "Placeholder Video (no GPU)", "category": "generation", "icon": "video"},
    {"id": "output", "name": "Video Output", "category": "data", "icon": "download"},
]

MODULES: dict[str, dict] = {m["id"]: dict(m) for m in DEFAULT_MODULES}


def _modules_dir() -> str:
    cfg = scheduler.load_config()
    return os.environ.get("RACK_MODULES_DIR", cfg.get("modules_dir", "/modules"))


def _load_module_files() -> None:
    base = _modules_dir()
    if not os.path.isdir(base):
        return
    candidates = [os.path.join(base, "module.yaml")]
    candidates += [os.path.join(entry.path, "module.yaml") for entry in os.scandir(base) if entry.is_dir()]
    for mod_file in candidates:
        if not os.path.isfile(mod_file):
            continue
        with open(mod_file, "r", encoding="utf-8") as fh:
            data = yaml.safe_load(fh) or {}
        mod_id = data.get("id") or data.get("name") or os.path.basename(os.path.dirname(mod_file))
        MODULES[mod_id] = {
            "id": mod_id,
            "name": data.get("name", mod_id),
            "category": data.get("category", "generation"),
            "icon": data.get("icon", "module"),
            "definition": data,
        }


def _output_dir() -> str:
    cfg = scheduler.load_config()
    return os.environ.get("RACK_OUTPUT_DIR", cfg.get("output_dir", "/app/outputs"))


def _output_for(pipeline_id: str):
    out_dir = _output_dir()
    if not os.path.isdir(out_dir):
        return None
    prefix = f"{pipeline_id}."
    for name in os.listdir(out_dir):
        if name.startswith(prefix):
            return os.path.join(out_dir, name)
    return None


# --- REST endpoints ---------------------------------------------------------
@app.get("/health")
async def health():
    return {"status": "healthy"}


@app.get("/modules")
async def list_modules():
    return list(MODULES.values())


@app.post("/modules")
async def register_module(module: ModuleRegister):
    MODULES[module.id] = {
        "id": module.id,
        "name": module.name,
        "category": module.category,
        "icon": module.icon,
        "definition": module.definition,
    }
    base = _modules_dir()
    if os.path.isdir(base):
        dest = os.path.join(base, module.id)
        os.makedirs(dest, exist_ok=True)
        with open(os.path.join(dest, "module.yaml"), "w", encoding="utf-8") as fh:
            yaml.safe_dump(module.definition or {}, fh)
    return {"id": module.id, "registered": True}


@app.post("/pipelines")
async def create_pipeline(pipeline: Pipeline):
    if not pipeline.modules:
        raise HTTPException(400, "Pipeline must contain at least one module")

    pipeline_id = str(uuid.uuid4())
    PIPELINES[pipeline_id] = pipeline.model_dump()

    try:
        workflow_name = await asyncio.to_thread(
            scheduler.submit_pipeline, pipeline, pipeline_id
        )
    except Exception as exc:  # surface submission errors to the frontend
        raise HTTPException(502, f"Workflow submission failed: {exc}")

    await manager.broadcast(
        json.dumps({"event": "pipeline.submitted", "pipeline_id": pipeline_id})
    )
    return {
        "pipeline_id": pipeline_id,
        "workflow_name": workflow_name,
        "status": "submitted",
    }


@app.get("/pipelines/{pipeline_id}")
async def get_pipeline(pipeline_id: str):
    pipeline = PIPELINES.get(pipeline_id)
    if not pipeline:
        raise HTTPException(404, "Pipeline not found")
    return pipeline


@app.get("/pipelines/{pipeline_id}/status")
async def pipeline_status(pipeline_id: str):
    if pipeline_id not in PIPELINES:
        raise HTTPException(404, "Pipeline not found")
    status = await asyncio.to_thread(scheduler.get_pipeline_status, pipeline_id)
    return status


@app.get("/pipelines/{pipeline_id}/output")
async def pipeline_output(pipeline_id: str):
    if pipeline_id not in PIPELINES:
        raise HTTPException(404, "Pipeline not found")
    path = _output_for(pipeline_id)
    if not path:
        raise HTTPException(404, "Output not ready. Check /pipelines/{id}/status")
    return FileResponse(path, media_type="video/mp4", filename=os.path.basename(path))


# --- WebSocket ---------------------------------------------------------------
@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await manager.connect(websocket)
    try:
        while True:
            data = await websocket.receive_text()
            await manager.broadcast(data)
    except WebSocketDisconnect:
        manager.disconnect(websocket)



