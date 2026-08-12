# rack-engine/backend/app/models.py
# Pydantic models for the pipeline graph submitted from the frontend.
from typing import Any, Dict, List, Optional
from pydantic import BaseModel, Field


class PipelineModule(BaseModel):
    """One node on the canvas, e.g. an input, a generator or an output."""

    id: str = Field(..., description="Node id on the canvas")
    type: str = Field(..., description="Module type, e.g. 'wan21'")
    params: Dict[str, Any] = Field(default_factory=dict)


class PipelineConnection(BaseModel):
    """An edge connecting two canvas nodes."""

    id: Optional[str] = None
    source: str = Field(..., description="Source node id")
    source_handle: Optional[str] = "out"
    target: str = Field(..., description="Target node id")
    target_handle: Optional[str] = "in"


class Pipeline(BaseModel):
    name: str = "untitled-pipeline"
    modules: List[PipelineModule] = Field(default_factory=list)
    connections: List[PipelineConnection] = Field(default_factory=list)


class ModuleRegister(BaseModel):
    """Body for POST /modules to register a new module definition."""

    id: str
    name: str
    category: str = "generation"
    icon: str = "module"
    definition: Optional[Dict[str, Any]] = None
