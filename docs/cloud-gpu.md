# Deploying the rack on real GPU nodes (cloud / bare metal)

This is the path for **actual Wan 2.1 inference**: run the stack on machines
that have real NVIDIA GPUs (A100/H100/L4/A10G/RTX 4xxx ...). The
`provisioning/emulator` flow and `modules/stub-video` exist so the UI,
Rack Engine and Argo plumbing can be exercised *without* GPUs; this document
covers switching on real compute.

## 0. Node topology

- 1 control-plane node (no GPU needed) running RKE2 server, Argo, Rack Engine.
- N worker nodes, each with at least one full NVIDIA GPU and the RKE2 agent.
- A container registry the nodes can pull from (Docker Hub, a private registry,
  or an in-cluster one such as `registry:2`).

Managed Kubernetes (EKS/GKE/AKS) works too: provision a GPU node pool and
skip step 1 (drivers usually come preinstalled on the AMI/image) — go straight
to step 2.

## 1. Install the NVIDIA GPU Operator (drivers + device plugin)

On the control plane, with a kubeconfig:

```bash
helm repo add nvidia https://nvidia.github.io/gpu-operator
helm repo update
helm install gpu-operator nvidia/gpu-operator \
  -n gpu-operator --create-namespace \
  -f kubernetes/gpu-operator-values.yaml
```

`kubernetes/gpu-operator-values.yaml` ships with the driver + device-plugin
enabled and `mig.strategy: none`. The device plugin is what advertises
`nvidia.com/gpu` capacity on each worker.

Watch it come up:

```bash
kubectl -n gpu-operator rollout status ds/nvidia-gpu-operator
kubectl get pods -n gpu-operator
kubectl get nodes -o jsonpath='{.items[*].status.capacity.nvidia\.com/gpu}'
```

If you want to slice GPUs into MIG instances (share one A100/H100 between
several modules), set `mig.strategy: mixed` and follow the MIG page in the
operator docs; each module still requests whole-GPU `nvidia.com/gpu` units.

## 2. Node labels (optional)

Label nodes by tier so modules can be steered with a nodeSelector later:

```bash
kubectl label node gpu-worker-01 cogniforge.rack/gpu=true
```

## 3. Install Argo Workflows

If you are not using `kubernetes/rke2-install.sh` (which installs Argo on the
server), deploy it the usual way:

```bash
kubectl create namespace argo
kubectl apply -n argo -f https://github.com/argoproj/argo-workflows/releases/download/v3.6.5/install.yaml
```

The backend expects `argo-workflows-server` at
`http://argo-workflows-server.argo:2746` (see `rack-engine/backend/config.yaml`).

## 4. Build and push the images

```bash
REGISTRY=my.registry.example.com/cogniforge ./scripts/build-images.sh
```

This builds `base` (CUDA layer), `wan21` (real model), `stub-video` (CPU
placeholder), the Rack Engine API and the frontend, then pushes them. Then
deploy with the **same** `REGISTRY` (plus `IMAGE_TAG` if you did not use
`latest`); `deploy-cluster.sh` rewrites the `image:` field in the staged
module definitions to `${REGISTRY}/<module>:<tag>` so Argo steps pull from
exactly where you pushed:

## 5. Deploy

```bash
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
REGISTRY=my.registry.example.com/cogniforge ./scripts/deploy-cluster.sh
```

`deploy-cluster.sh` packages every `modules/*/module.yaml` into the
`rack-modules` configMap (so the backend discovers `wan21` and `stub-video`
at startup), deploys the backend + frontend, and registers the modules.

## 6. Generate

Real GPU path:

```bash
RACK_ENGINE=http://<node-ip>:<api-nodePort> ./scripts/test-generation.sh
```

GPU-less smoke path (same code path, no GPU needed — great for CI or when GPU
nodes are still spinning up):

```bash
RACK_ENGINE=http://<node-ip>:<api-nodePort> MODULE_TYPE=stub-video \
  ./scripts/test-generation.sh
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Workflow stays `Pending` | No node advertises `nvidia.com/gpu`. Check `kubectl get pods -n gpu-operator` and the device-plugin pod logs; confirm drivers match the GPU (`nvidia-smi` in the node). |
| Pod `ErrImagePull` | Registry credentials missing on nodes, or `imagePullPolicy: IfNotPresent` with an image that was never pushed. Push with `./scripts/build-images.sh` and check the image name in the workflow step. |
| `driver` pod CrashLoopBackOff | Kernel modules for the installed driver missing/incompatible; see the GPU Operator's driver doc. On managed K8s, prefer an image that already ships the driver. |
| Backend can't reach Argo | `argo_host` in `config.yaml` must point at the Argo server service; confirm `kubectl get svc -n argo argo-workflows-server`. |
