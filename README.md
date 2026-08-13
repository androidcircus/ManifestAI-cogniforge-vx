# CogniForge Rack

Build package for a **virtual-machine-based GPU cluster** running an AI video
generation platform. Pipelines are composed from drag-and-drop modules in a
web UI, submitted to Argo Workflows on RKE2, and executed on GPU worker VMs
(Wan 2.1 for image-to-video generation).

[![Open in Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/androidcircus/ManifestAI-cogniforge-vx/HEAD/notebooks/rack-demo.ipynb)

> **One-token setup** (GitHub + Render + Colab + base44):
> `GH_TOKEN=<PAT> bash scripts/boot-onboarding.sh`

> This is the "virtual machine GPU cluster" edition: the compute nodes are
> KVM/libvirt VMs instead of physical servers. Each worker VM is assigned a
> physical GPU (or a vGPU/MIG slice) via PCI passthrough. Everything else in
> the stack is identical to a bare-metal build.

## Repository layout

```
hardware/            VM-based resource plan (BOM.csv) and rack layout
network/             InfiniBand host setup + management network IPs
provisioning/        Vagrant, cloud-init, QEMU emulator, and AWS (EC2 + Terraform)
kubernetes/          RKE2 install, NVIDIA GPU Operator, local storage
rack-engine/         FastAPI backend + React/react-flow frontend
modules/wan21/       Wan 2.1 inference module (API + CLI + Docker)
modules/stub-video/  CPU-only placeholder generator (no-GPU / dev path)
workflows/           Argo Workflow templates
monitoring/          Prometheus config + Grafana dashboards
scripts/             deploy / build-images / test / push-to-github / make-release
notebooks/           Colab + base44 demo notebook (stub-video + GEMM kernel)
docs/                quickstart.md, architecture.md, cloud-gpu.md
render.yaml          Render Blueprint (API + dashboard)
```

## Quick start

See [docs/quickstart.md](docs/quickstart.md). High level:

1. Provision VMs: `cd provisioning && vagrant up`
2. Install RKE2 + GPU Operator: run `kubernetes/rke2-install.sh` on the control plane
3. Deploy the stack: `scripts/deploy-cluster.sh`
4. Test: `scripts/test-generation.sh`

## Deploy targets

| Target | Artifact | Docs |
|--------|----------|------|
| VM cluster (KVM/libvirt) | `provisioning/Vagrantfile` | `docs/quickstart.md` |
| AWS (EC2 + ECR) | `provisioning/ec2/bringup-ec2.sh`, `provisioning/ec2/terraform` | `docs/cloud-gpu.md` §1.6 |
| Render (dashboard + API) | `render.yaml` | `scripts/deploy-cluster.sh` notes |
| Colab / base44 | `notebooks/rack-demo.ipynb` | notebook intro |
| No-GPU dev/emulation | `provisioning/emulator/*` + `modules/stub-video` | `provisioning/emulator/README.md` |

## CI & releases

- `./.github/workflows/ci.yml` runs GEMM, backend pytest, frontend build and the
  stub-video smoke test on every push.
- `./scripts/push-to-github.sh` pushes to `androidcircus/ManifestAI-cogniforge-vx`
  (override with `REPO_URL` / first arg).
- `./scripts/make-release.sh` tags a source zip into `dist/`.

## License

Unlicensed - internal build package.
