# rack-engine/backend/tests/test_scheduler.py
# Unit tests for the Argo workflow builder. Run with: pytest rack-engine/backend
from pathlib import Path

from app.models import Pipeline, PipelineModule
from app.scheduler import _build_workflow

_REPO = Path(__file__).resolve().parents[3]  # rack-engine/backend/tests -> repo root
MODULES_DIR = str(_REPO / "modules")
CFG = {"image_registry": "manifestai"}


def _wf(module_type: str):
    pipe = Pipeline(
        name="ci-check",
        modules=[
            PipelineModule(id="n1", type=module_type, params={"image_url": "x", "duration": 5})
        ],
    )
    return _build_workflow(CFG, pipe, MODULES_DIR)


def _step(wf):
    return wf["spec"]["templates"][1]


def test_stub_video_requests_no_gpu():
    step = _step(_wf("stub-video"))
    res = step["container"]["resources"]
    assert "nvidia.com/gpu" not in res["requests"]
    assert "nvidia.com/gpu" not in res["limits"]
    assert "nodeSelector" not in step


def test_stub_video_points_at_registry_image():
    step = _step(_wf("stub-video"))
    assert step["container"]["image"] == "manifestai/stub-video:latest"


def test_wan21_requests_one_gpu():
    step = _step(_wf("wan21"))
    assert step["container"]["resources"]["requests"]["nvidia.com/gpu"] == "1"
    assert step["container"]["resources"]["limits"]["nvidia.com/gpu"] == "1"


def test_wan21_pins_to_tier3_nodes():
    step = _step(_wf("wan21"))
    assert step["nodeSelector"] == {"cogniforge.rack/tier": "tier3"}


def test_wan21_uses_declared_image():
    step = _step(_wf("wan21"))
    assert step["container"]["image"] == "manifestai/wan21:latest"


def test_no_generator_raises():
    import pytest

    pipe = Pipeline(name="empty", modules=[])
    with pytest.raises(ValueError):
        _build_workflow(CFG, pipe, MODULES_DIR)