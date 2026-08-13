# rack-engine/backend/app/scheduler.py
# Submits pipelines to Argo Workflows and polls their status.
#
# The argo-workflows SDK talks to the Argo Workflows server REST API. In the
# cluster that is the `argo-workflows-server` service (namespace `argo`),
# reachable from the Rack Engine pod. Override via config.yaml -> argo_host.
import os
import uuid
from typing import Any, Dict, Optional

import yaml

PIPELINE_REGISTRY: Dict[str, str] = {}  # pipeline_id -> workflow name

_workflow_api = None


def _config_path() -> str:
    return os.environ.get(
        "RACK_ENGINE_CONFIG",
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "config.yaml"),
    )


def load_config() -> Dict[str, Any]:
    with open(_config_path(), "r", encoding="utf-8") as fh:
        return yaml.safe_load(fh) or {}


def _get_workflow_api():
    """Lazily build the Argo WorkflowServiceApi client."""
    global _workflow_api
    if _workflow_api is not None:
        return _workflow_api

    cfg = load_config()
    host = cfg.get("argo_host", "http://argo-workflows-server.argo:2746")

    from argo_workflows import ApiClient, Configuration
    from argo_workflows.api.workflow_service_api import WorkflowServiceApi

    argo_cfg = Configuration(host=host)
    _workflow_api = WorkflowServiceApi(ApiClient(argo_cfg))
    return _workflow_api


def _module_defs(modules_dir: str) -> Dict[str, Dict[str, Any]]:
    """Read module.yaml files from a directory, keyed by module id.

    Handles both layouts:
      /modules/wan21/module.yaml   (repo tree, one dir per module)
      /modules/module.yaml         (configMap mount, files at the root)
    """
    defs: Dict[str, Dict[str, Any]] = {}
    if not os.path.isdir(modules_dir):
        return defs

    candidates = [os.path.join(modules_dir, "module.yaml")]
    for entry in os.scandir(modules_dir):
        if entry.is_dir():
            candidates.append(os.path.join(entry.path, "module.yaml"))

    for mod_file in candidates:
        if not os.path.isfile(mod_file):
            continue
        with open(mod_file, "r", encoding="utf-8") as fh:
            data = yaml.safe_load(fh) or {}
        mod_id = data.get("id") or data.get("name") or os.path.basename(os.path.dirname(mod_file))
        defs[mod_id] = data
    return defs


def _build_workflow(cfg: Dict[str, Any], pipeline, modules_dir: str) -> Dict[str, Any]:
    """Translate a Pipeline model into an Argo Workflow manifest."""
    module_defs = _module_defs(modules_dir)

    generator = next((m for m in pipeline.modules if m.type in module_defs), None)
    if generator is None:
        generator = next((m for m in pipeline.modules if m.type in ("wan21",)), None)
    if generator is None:
        raise ValueError("Pipeline has no generator module (e.g. 'wan21')")

    mod_def = module_defs.get(generator.type, {})
    params = generator.params or {}
    image = mod_def.get("image") or f"{cfg.get('image_registry', 'manifestai')}/{generator.type}:latest"
    gpu = mod_def.get("resources", {}).get("gpu", 1)
    gpu = gpu if isinstance(gpu, int) and gpu > 0 else 0
    memory = mod_def.get("resources", {}).get("memory", "32Gi")
    cpu = mod_def.get("resources", {}).get("cpu", 4)
    # Restrict which node tier runs this module. Nodes in a mixed cluster
    # (GPU-less control plane, 24GB tier-2 GPUs, 40GB+ tier-3 GPUs) must be
    # labeled so a 14B model never lands on a too-small GPU.
    node_selector = mod_def.get("resources", {}).get("node_selector", {}) or {}

    resources = {
        "limits": {"memory": memory, "cpu": str(cpu)},
        "requests": {"memory": memory, "cpu": str(cpu)},
    }
    if gpu:
        resources["limits"]["nvidia.com/gpu"] = str(gpu)
        resources["requests"]["nvidia.com/gpu"] = str(gpu)

    safe_name = (pipeline.name or "pipeline").lower().replace("_", "-")
    safe_name = "".join(c for c in safe_name if c.isalnum() or c == "-")[:40] or "pipeline"

    image_url = str(params.get("image_url", ""))
    duration = str(params.get("duration", 5))

    # Container-level requests/limits. nvidia.com/gpu is added ONLY when the
    # module asks for GPUs: argo/kubernetes would otherwise place the request
    # on already-allocated capacity and a gpu:0 stub module would never run.
    step_resources = {
        "limits": {"memory": memory, "cpu": str(cpu)},
        "requests": {"memory": memory, "cpu": str(cpu)},
    }
    if gpu:
        step_resources["limits"]["nvidia.com/gpu"] = str(gpu)
        step_resources["requests"]["nvidia.com/gpu"] = str(gpu)

    return {
        "apiVersion": "argoproj.io/v1alpha1",
        "kind": "Workflow",
        "metadata": {"generateName": f"rack-{safe_name}-"},
        "spec": {
            "entrypoint": "main",
            "templates": [
                {
                    "name": "main",
                    "steps": [
                        [
                            {
                                "name": "generate",
                                "template": f"{generator.type}-generate",
                                "arguments": {
                                    "parameters": [
                                        {"name": "image_url", "value": image_url},
                                        {"name": "duration", "value": duration},
                                    ]
                                },
                            }
                        ]
                    ],
                },
                {
                    "name": f"{generator.type}-generate",
                    "inputs": {
                        "parameters": [
                            {"name": "image_url"},
                            {"name": "duration"},
                        ]
                    },
                    **({"nodeSelector": node_selector} if node_selector else {}),
                    "container": {
                        "image": image,
                        "command": ["python", "generate.py"],
                        "args": [
                            "--image-url", "{{inputs.parameters.image_url}}",
                            "--duration", "{{inputs.parameters.duration}}",
                            "--output", "/app/outputs/out.mp4",
                        ],
                        "resources": step_resources,
                    },
                    "outputs": {
                        "artifacts": [
                            {
                                "name": "video",
                                "path": "/app/outputs/out.mp4",
                                "archive": {"none": {}},
                            }
                        ]
                    },
                },
            ],
        },
    }


def submit_pipeline(pipeline, pipeline_id: str) -> str:
    """Submit the pipeline to Argo. Returns the workflow name."""
    cfg = load_config()
    modules_dir = os.environ.get(
        "RACK_MODULES_DIR", cfg.get("modules_dir", "/modules")
    )
    wf = _build_workflow(cfg, pipeline, modules_dir)

    namespace = cfg.get("namespace", "default")
    api = _get_workflow_api()
    resp = api.create_workflow(
        namespace=namespace, body=wf, _check_return_type=False
    )
    name = resp["metadata"]["name"] if isinstance(resp, dict) else resp.metadata.name
    PIPELINE_REGISTRY[pipeline_id] = name
    return name


def get_pipeline_status(pipeline_id: str) -> Dict[str, Any]:
    """Return the Argo phase for a submitted pipeline."""
    workflow_name = PIPELINE_REGISTRY.get(pipeline_id)
    if not workflow_name:
        return {"status": "unknown", "reason": "no workflow submitted", "workflow_name": None}

    namespace = load_config().get("namespace", "default")
    api = _get_workflow_api()
    resp = api.get_workflow(namespace=namespace, name=workflow_name, _check_return_type=False)
    wf = resp if isinstance(resp, dict) else resp.to_dict()
    status = wf.get("status") or {}

    phase = status.get("phase", "Pending")
    return {
        "status": phase.lower(),
        "progress": status.get("progress"),
        "workflow_name": workflow_name,
        "message": status.get("message"),
        "started_at": status.get("startedAt"),
        "finished_at": status.get("finishedAt"),
    }
