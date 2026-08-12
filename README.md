# CogniForge Rack

Build package for a **virtual-machine-based GPU cluster** running an AI video
generation platform. Pipelines are composed from drag-and-drop modules in a
web UI, submitted to Argo Workflows on RKE2, and executed on GPU worker VMs
(Wan 2.1 for image-to-video generation).

> This is the "virtual machine GPU cluster" edition: the compute nodes are
> KVM/libvirt VMs instead of physical servers. Each worker VM is assigned a
> physical GPU (or a vGPU/MIG slice) via PCI passthrough. Everything else in
> the stack is identical to a bare-metal build.

## Repository layout

```
hardware/            VM-based resource plan (BOM.csv) and rack layout
network/             InfiniBand host setup + management network IPs
provisioning/        Vagrant + cloud-init that create the cluster VMs
kubernetes/          RKE2 install, NVIDIA GPU Operator, local storage
rack-engine/         FastAPI backend + React/react-flow frontend
modules/wan21/       Wan 2.1 inference module (API + CLI + Docker)
workflows/           Argo Workflow templates
monitoring/          Prometheus config + Grafana dashboards
scripts/             deploy-cluster.sh and test-generation.sh
docs/                quickstart.md and architecture.md
```

## Quick start

See [docs/quickstart.md](docs/quickstart.md). High level:

1. Provision VMs: `cd provisioning && vagrant up`
2. Install RKE2 + GPU Operator: run `kubernetes/rke2-install.sh` on the control plane
3. Deploy the stack: `scripts/deploy-cluster.sh`
4. Test: `scripts/test-generation.sh`

## License

Unlicensed - internal build package.
