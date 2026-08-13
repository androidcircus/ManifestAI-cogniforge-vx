# Changelog

All notable changes to the CogniForge Rack build package are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Planned (next iteration)

- Tier-2 (16–24 GB VRAM) module that fits: quantized / 1B-class video model with
  its own `node_selector` + `gpu: 1`.
- AWS: `provisioning/ec2/bringup-ec2.sh` multi-node flow hardening (verified on
  a real p4d/p5 instance).
- GitHub Actions coverage for the QEMU device e2e (qtest) when a runner with
  AVX-512 + a QEMU build is available.

## [0.1.0] - 2026-08-13

### Added

- **Emulated CogniForge GPU device** (`provisioning/emulator/cogniforge-gpu.c`)
  in a patched QEMU: MMIO registers (`REG_CMD`, `REG_CMD_RESULT`, `REG_VERSION`,
  `REG_STATUS`, `REG_VRAM_SIZE`), 128 MiB VRAM BAR, and a packed 60-byte GEMM
  command block built around the standalone FP32 kernel.
- **FP32 GEMM library** (`provisioning/emulator/cogniforge-gemm.[ch]`): scalar
  + AVX-512 FMA kernels, accumulation mode, `COGNIFORGE_GEMM_MAX_DIM 4096`,
  error codes (OK/BAD_PARAMS/DIM_TOO_LARGE), no QEMU dependencies.
- **End-to-end device test** `provisioning/emulator/test-device-gemm.py`: drives
  the device over QEMU `qtest` (PCI scan at 00:01.0, BAR programming, VRAM
  command+matrices), asserts exact `C = A·B` results and rejects bad magic.
- **Standalone GEMM checks** `test-gemm.c` / `test-gemm.sh` (scalar + AVX-512).
- **CPU-only stub-video module** (`modules/stub-video`): real `.mp4` from
  procedurally-drawn frames so the full UI → Rack Engine → Argo path works
  without a GPU or the 14B model.
- **Rack Engine scheduler** (`rack-engine/backend/app/scheduler.py`): builds Argo
  Workflow manifests, per-module GPU capacity (only modules that declare GPUs
  request `nvidia.com/gpu`), and per-module `node_selector` for tier pinning.
- **Mixed tier support**: `wan21/module.yaml` pins to `cogniforge.rack/tier=tier3`
  (40 GB+ VRAM); stub-video schedules anywhere. Nodes labeled per tier.
- **Cloud deployment tooling** (`scripts/`): `deploy-cluster.sh` (single
  configMap for all module defs, registry image rewrite, module registration,
  NodePort exposure), `build-images.sh`, `test-generation.sh` (`MODULE_TYPE`).
- **AWS bring-up**: `provisioning/ec2/bringup-ec2.sh` (RKE2 single-node, ECR
  login via instance role, GPU Operator, tier labels, deploy wrapper) + a full
  Terraform module (VPC, SG, ECR repos x5, IAM, control plane, N GPU workers).
- **Render blueprint** (`render.yaml` + `Dockerfile.render`): FastAPI API +
  React dashboard on a single Blueprint; WS base auto-derived from API base.
- **Colab / base44 demo** (`notebooks/rack-demo.ipynb`): generates a stub video
  and compiles/verifies the same CogniForge GEMM kernel, no GPU or Docker.
- **GitHub Actions CI** (`.github/workflows/ci.yml`): GEMM (scalar + AVX-512 on
  capable runners), backend pytest, frontend production build, stub-video smoke.
- **Release + onboarding tooling**: `scripts/make-release.sh` (`dist/` zip),
  `VERSION`, `scripts/push-to-github.sh`, `scripts/boot-onboarding.sh`
  (one-token setup of GitHub + Render + Colab + base44), Colab badge in README.
- **Docs**: `docs/cloud-gpu.md` (GPU Operator, Argo, ECR, three-tier layout, AWS
  console/CLI walkthrough), quickstart deploy-target table, README overview.

### Changed

- `modules/wan21/module.yaml` gained `node_selector:
  {cogniforge.rack/tier: tier3}` in resources.
- `rack-engine/frontend/src/api.js` derives `WS_BASE` from `API_BASE` so
  https/ws upgrades work on Render and elsewhere without extra config.
- Scheduler moved to `rack-engine/backend/app/scheduler.py` with explicit
  module-driven resource + node selection.

### Fixed

- **GEMM command layout**: `CogniForgeMmaCmd` was 64 bytes with implicit padding;
  now `QEMU_PACKED` → stable 60-byte layout (`REG_CMD` magic `CGGE` respected,
  bad-magic returns `0xFFFFFFFF` result + `0x80000001` status).
- **BAR mapping**: 32-bit BARs whose end address would hit `UINT32_MAX` are not
  mapped by QEMU; BARs at `0xE0000000` (MMIO) / `0xF0000000` (128 MiB VRAM) map
  correctly.
- **qtest byte I/O**: line-based text mode reordered output; tests now use raw
  byte reads/writes for request/response framing.

### Verified

- GEMM scalar + AVX-512: all correctness/error-code cases pass.
- Device e2e over qtest: `C=[19, 22, 43, 50]` matches expectations; bad-magic
  rejected.
- Scheduler pytest (6/6): stub-video requests no GPU; wan21 requests 1 GPU and
  pins to tier3.
- stub-video renders a real MP4 (CPU-only).

[0.1.0]: https://github.com/androidcircus/ManifestAI-cogniforge-vx/releases/tag/v0.1.0