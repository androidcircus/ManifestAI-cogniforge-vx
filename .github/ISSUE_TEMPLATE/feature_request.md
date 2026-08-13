---
name: Feature request
about: New capability for the rack, emulator, modules, or deployment
title: "[feat] "
labels: enhancement
assignees: ""
---

**What should happen**

Describe the capability and the user it serves.

**Where it lives**

- [ ] `provisioning/emulator` (CogniForge GPU device / GEMM)
- [ ] `modules/*` (wan21, stub-video, or a new module)
- [ ] `rack-engine` (backend scheduler / frontend)
- [ ] `kubernetes` / `workflows` (cluster + Argo)
- [ ] Deploy target: `AWS` / `Render` / `Colab-base44` / `GitHub CI`
- [ ] Docs / tooling (`scripts/`, CHANGELOG, README)

**Acceptance criteria**

- [ ] Hidden, small, checkable items

**Impact on tiers**

How does this affect tier-1 (CPU-only), tier-2 (16–24 GB), tier-3 (40 GB+)?
If it requests GPUs, it must include a `node_selector` so it never lands on the
wrong tier.

**Verification plan**

Commands or notebook cells that prove it works without a real GPU where
possible (cloud: `stub-video` + the CogniForge GEMM kernel).