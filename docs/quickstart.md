# Quickstart - CogniForge Rack (VM GPU cluster)

Build the rack end-to-end. Physical hosts provide the GPUs; the cluster nodes
are **virtual machines**.

## 0. Prerequisites (per physical host)

- Linux with KVM/libvirt: `apt install qemu-kvm libvirt-daemon-system vagrant`
- `vagrant plugin install vagrant-libvirt`
- NVIDIA drivers NOT bound to the host (see `provisioning/gpu-passthrough.md`)

## 1. Provision the VMs

```bash
cd provisioning

# Boot a VM from the installer ISO with a virtual GPU (virtio-gpu):
#   ISO=./ubuntu-24.04.2-live-server-amd64.iso ./emulator/run-vm.sh cogniforge-cp
#
# OR create everything with Vagrant (faster for dev):
vagrant up            # cogniforge-cp + 8 GPU workers (WORKER_COUNT=8)
./scripts/attach-gpu.sh
# reboot each worker so the passed-through GPU initializes
```

## 2. Install Kubernetes (RKE2)

On the control plane:

```bash
cd cogniforge-rack
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
MODE=server ./kubernetes/rke2-install.sh
```

On every worker (copy the token printed by the server):

```bash
MODE=agent RKE2_URL=https://cogniforge-cp:9345 RKE2_TOKEN=<token> ./kubernetes/rke2-install.sh
```

Verify:

```bash
kubectl get nodes            # all VMs Ready
kubectl get pods -n gpu-operator   # driver + device-plugin DaemonSets running
kubectl get nodes -o jsonpath='{.items[*].status.capacity.nvidia\.com/gpu}'
```

## 3. Build the images

```bash
# Builds base (CUDA), wan21, stub-video, rack-engine and the frontend.
# REGISTRY=my.registry.example.com/cogniforge ./scripts/build-images.sh
./scripts/build-images.sh
```

For running the stack on **real GPU nodes** (cloud or bare metal) instead of
the emulated rack, follow `docs/cloud-gpu.md`. To try the full pipeline
without any GPU at all, use the `stub-video` module (CPU-only placeholder).

## 4. Deploy the stack

```bash
./scripts/deploy-cluster.sh
```

## 5. Run the end-to-end test

```bash
RACK_ENGINE=http://<node-ip>:<api-nodePort> ./scripts/test-generation.sh
```

No GPU? Run the same test against the placeholder generator:

```bash
RACK_ENGINE=http://<node-ip>:<api-nodePort> MODULE_TYPE=stub-video \
  ./scripts/test-generation.sh
```

You should see the pipeline transition `pending -> running -> succeeded` and a
video file downloaded. Watch the UI:

```bash
# open http://<node-ip>:<frontend-nodePort>
# or run the dev UI locally:
cd rack-engine/frontend && npm install && npm start
```

## 6. (Optional) Try the emulated accelerator device

```bash
# Only if you built QEMU with cogniforge-gpu.c (see provisioning/emulator/)
qemu-system-x86_64 ... -device cogniforge-gpu,sm_count=256,vram_size=2G
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Worker has no GPU after boot | Re-run `provisioning/scripts/attach-gpu.sh`, then `virsh reboot <vm>` |
| `nvidia.com/gpu` capacity missing | Check `kubectl get pods -n gpu-operator`; device-plugin DaemonSet on workers |
| Workflow stays `Pending` | No node with `nvidia.com/gpu`; check `kubectl describe pod` for scheduler messages |
| `argo-workflows-server` unreachable | Confirm `kubernetes/rke2-install.sh` installed Argo; backend `config.yaml` `argo_host` matches |
