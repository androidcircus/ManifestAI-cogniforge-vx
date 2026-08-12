# Architecture - CogniForge Rack

## Overview

```
                  ┌────────────────────────────────────────────┐
  Browser ───────►│ React UI (react-flow)  ──/api──┐            │
                  │  drag modules, connect, deploy │            │
                  └─────────────────────────────── │            │
                                                    ▼            │
                                   ┌───────────────────────────┐ │
                                   │ Rack Engine API (FastAPI) │ │
                                   │  /pipelines  /modules     │ │
                                   │  /ws  (status broadcast)  │ │
                                   └───────────┬───────────────┘ │
                                               │ submit           │
                                               ▼                  │
                                   ┌───────────────────────────┐  │
                                   │ Argo Workflows            │  │
                                   │  workflow per pipeline    │  │
                                   └───────────┬───────────────┘  │
                                               │ schedule on       │
                                               ▼                   │
   ┌───────────────┬───────────────┬───────────┴──────────┐        │
   │ Worker VM 01  │ Worker VM 02  │ ...  Worker VM 08    │        │
   │ H100 (vfio)   │ H100 (vfio)   │    H100 (vfio)       │        │
   │ wan21 pod     │ wan21 pod     │    wan21 pod         │        │
   └───────────────┴───────────────┴──────────────────────┘        │
```

## Components

### Hardware / VMs (`hardware/`, `provisioning/`)

- Two physical hosts, four H100s each. Workers are KVM/libvirt VMs; each
  worker receives one physical GPU via `vfio-pci` passthrough
  (`provisioning/gpu-passthrough.md`).
- Alternatively the `provisioning/emulator/` scripts boot VMs from an
  installer ISO with a **virtual GPU** (`virtio-gpu-pci`) and an optional
  emulated compute device (`cogniforge-gpu.c`, BAR0 MMIO / BAR2 doorbell /
  BAR4 VRAM).

### Kubernetes (`kubernetes/`)

- RKE2 (server on `cogniforge-cp`, agents on workers).
- NVIDIA GPU Operator publishes each passed-through GPU as
  `nvidia.com/gpu` capacity; device-plugin schedules GPU workloads.
- `local-nvme` StorageClass + per-node PVs back pipeline output volumes.

### Rack Engine (`rack-engine/`)

- **Backend (FastAPI)**:
  - `POST /pipelines` - validates the graph, translates it to an Argo
    Workflow manifest, submits, and returns `pipeline_id`.
  - `GET /pipelines/{id}/status` - polls Argo for the phase/progress.
  - `GET /pipelines/{id}/output` - serves the finished mp4.
  - `WS /ws` - broadcasts submission/status events to the UI.
  - `GET/POST /modules` - module registry (loaded from `module.yaml` files).
- **Frontend (React + `@xyflow/react`)**:
  - Drag modules from the palette onto the canvas, connect input → generator
    → output, edit parameters, deploy. Live status via `react-use-websocket`.

### Modules (`modules/`)

- `wan21`: Wan 2.1 image-to-video. `virtual_api.py` is the interactive API;
  `generate.py` is the CLI entrypoint Argo invokes (a step must start,
  produce a file, and exit). Both load `Wan-AI/Wan2.1-I2V-14B-480P-Diffusers`
  lazily with `torch.bfloat16`.
- `base/pytorch-cuda`: shared image (CUDA 12.4 + ffmpeg) that module images
  build on.

### Workflows (`workflows/`)

- `video-pipeline.yaml`: entrypoint → `wan21-generate` step with
  `nvidia.com/gpu: 1`, 32Gi memory, node affinity for GPU workers, and a
  `video` artifact output to the shared output PVC.

### Monitoring (`monitoring/`)

- Prometheus scrapes the Rack Engine, Argo, and DCGM exporter metrics
  (`DCGM_FI_DEV_GPU_UTIL`, ...); the Grafana dashboard renders GPU
  utilization and workflow phases.

## Request flow (end to end)

1. User drops `wan21` onto the canvas, sets `image_url` / `duration`, clicks
   Deploy.
2. Frontend POSTs the graph to the backend.
3. Backend builds an Argo Workflow manifest (image from `module.yaml`),
   submits it, stores the `pipeline_id → workflow` mapping.
4. Argo schedules the `wan21-generate` step on a GPU worker; the pod runs
   `generate.py`, writes `/mnt/outputs/out.mp4` (local NVMe PV), and archives
   the artifact.
5. Frontend polls `GET /pipelines/{id}/status` (or receives `WS /ws` events)
   until `succeeded`, then fetches `GET /pipelines/{id}/output`.

## Security notes (production hardening)

- Replace `allow_origins=["*"]` / NodePort exposure with an ingress +
  TLS (cert-manager) and OIDC on Argo.
- Push images to a private registry; pin digests.
- Add RBAC so the Rack Engine can only create Workflows in its namespace.
