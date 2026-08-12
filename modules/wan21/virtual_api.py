# modules/wan21/virtual_api.py
# Wan 2.1 inference module - FastAPI server (interactive / streaming use).
#
# Uses the real Wan 2.1 image-to-video pipeline from diffusers
# (Wan-AI/Wan2.1-I2V-14B-480P-Diffusers), loaded lazily on first request.
#
# Endpoints:
#   POST /generate   {"image_url": "...", "duration": 5}
#   GET  /status/{job_id}
#   GET  /download/{job_id}
import os
import torch
import uuid

from fastapi import FastAPI, BackgroundTasks
from fastapi.responses import FileResponse
from pydantic import BaseModel

app = FastAPI(title="Wan 2.1 Inference Module")

MODEL_ID = os.environ.get("WAN_MODEL_ID", "Wan-AI/Wan2.1-I2V-14B-480P-Diffusers")
OUTPUT_DIR = os.environ.get("WAN_OUTPUT_DIR", "/app/outputs")

_pipe = None
jobs: dict[str, dict] = {}


def get_pipeline():
    """Load the Wan 2.1 diffusers pipeline once, reuse across requests."""
    global _pipe
    if _pipe is None:
        from diffusers import WanImageToVideoPipeline
        from transformers import T5EncoderModel

        text_encoder = T5EncoderModel.from_pretrained(
            MODEL_ID, subfolder="text_encoder", torch_dtype=torch.bfloat16
        )
        _pipe = WanImageToVideoPipeline.from_pretrained(
            MODEL_ID,
            text_encoder=text_encoder,
            torch_dtype=torch.bfloat16,
        )
        if torch.cuda.is_available():
            _pipe.to("cuda")
        else:
            _pipe.enable_model_cpu_offload()
    return _pipe


class GenerationRequest(BaseModel):
    image_url: str
    duration: int = 5


def _generate(job_id: str, image_url: str, duration: int) -> None:
    try:
        from diffusers.utils import export_to_video, load_image

        pipe = get_pipeline()
        image = load_image(image_url).convert("RGB")

        # Wan 2.1 works on 16-frame chunks at the target length.
        frames = pipe(
            image=image,
            duration=duration * 16,
            num_frames=16,
            height=480,
            width=832,
            guidance_scale=5.0,
            num_inference_steps=50,
            generator=torch.manual_seed(42),
        ).frames[0]

        os.makedirs(OUTPUT_DIR, exist_ok=True)
        out_path = os.path.join(OUTPUT_DIR, f"{job_id}.mp4")
        export_to_video(frames, out_path, fps=16)

        jobs[job_id]["status"] = "completed"
        jobs[job_id]["file_path"] = out_path
    except Exception as exc:  # surface failures to the caller
        jobs[job_id]["status"] = "failed"
        jobs[job_id]["error"] = str(exc)


@app.post("/generate")
async def generate(req: GenerationRequest, background_tasks: BackgroundTasks):
    job_id = str(uuid.uuid4())
    jobs[job_id] = {"status": "queued", "file_path": None}
    background_tasks.add_task(_generate, job_id, req.image_url, req.duration)
    return {"job_id": job_id, "status": "queued"}


@app.get("/status/{job_id}")
async def status(job_id: str):
    return jobs.get(job_id, {"status": "not_found"})


@app.get("/download/{job_id}")
async def download(job_id: str):
    job = jobs.get(job_id)
    if not job or job.get("status") != "completed" or not job.get("file_path"):
        return {"error": "Job not ready"}
    if not os.path.exists(job["file_path"]):
        return {"error": "File missing"}
    return FileResponse(job["file_path"], media_type="video/mp4", filename=f"{job_id}.mp4")
