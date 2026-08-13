<!-- Use this template for every PR. Delete the parts that don't apply. -->

## Summary

What this PR does, in one or two sentences. Link any issue:
Closes #<issue>

## Verification

State exactly what you ran — with no GPU where possible:

- [ ] `bash provisioning/emulator/test-gemm.sh` (scalar + AVX-512)
- [ ] `python provisioning/emulator/test-device-gemm.py <qemu-system-x86_64>` (qtest e2e)
- [ ] `python -m pytest rack-engine/backend/tests`
- [ ] `MODULE_TYPE=stub-video ./scripts/test-generation.sh` (full pipeline, no GPU)
- [ ] `npm run build` / UI change shown
- [ ] Code only touched docs/scripts — verified via `bash -n` / JSON parse

## Deploy targets touched

- [ ] `emulator` (QEMU device/GEMM)
- [ ] `modules/*` (image/CLI/generate.py)
- [ ] `rack-engine` (backend/frontend)
- [ ] `AWS` (`provisioning/ec2/*`)
- [ ] `Render` (`render.yaml`, `Dockerfile.render`)
- [ ] `Colab/base44` (`notebooks/`)
- [ ] CI / release (`scripts/`, `.github/`, VERSION, CHANGELOG)

## Impact on tiers

Whether this changes which node tier runs something. Any module that requests a
GPU must keep a `node_selector` so it can never land below 40 GB (tier-3) if it
needs it, else it will OOM on tier-2.

## Notes for reviewer

Anything unusual: image tags, ECR/registry rewrites, BAR alignments, qtest
byte-I/O, or a changed CHANGELOG entry.