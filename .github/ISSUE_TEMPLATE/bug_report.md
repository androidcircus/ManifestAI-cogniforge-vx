---
name: Bug report
about: Something is wrong with the rack stack, emulator, or module
title: "[bug] "
labels: bug
assignees: ""
---

**What broke**

One sentence on the observed failure.

**How to reproduce**

Steps:
1. Command / URL used
2. `kubectl`/Argo/pipeline state observed
3.

**Expected vs actual**

- Expected:
- Actual:

**Environment**

- Deploy target: `emulator` / `VM cluster (Vagrant)` / `AWS EC2` / `Render` / `Colab`
- Module: `wan21` / `stub-video` / other
- Node tier: `tier1` / `tier2` / `tier3`
- GPU / VRAM (if a GPU node):
- Rack Engine version or commit: `git rev-parse HEAD`
- How run: `MODULE_TYPE=stub-video ./scripts/test-generation.sh` etc.

**Logs**

Paste the relevant excerpt (`kubectl describe pod/wf`, qtest output, API response).

**Checklist before filing**

- [ ] Reproduced with the latest commit on `main`
- [ ] Distinct from existing issues
- [ ] `provisioning/emulator/test-gemm.sh` still passes on your machine (GEMM level)