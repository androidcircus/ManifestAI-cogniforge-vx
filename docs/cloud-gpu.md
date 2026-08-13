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
skip section 2 (drivers usually come preinstalled on the AMI/image) — go straight
to section 4.

## 1.5 Running all three tiers in one cluster

The rack is designed for a **mixed node pool** — one cluster, three tiers:

| Tier | Node | Runs |
|------|------|------|
| 1 | CPU-only (control plane or small worker) | Infra, `stub-video`, CPU jobs |
| 2 | GPU with 16–24GB VRAM (g4dn/A10G/L4/T4) | Smaller/quantized models; currently idle for the 14B model |
| 3 | GPU with 40GB+ VRAM (p4d A100, p5 H100) | `wan21` (14B) |

`wan21/module.yaml` declares a `node_selector` (`cogniforge.rack/tier: tier3`)
so its pods never land on a 24GB tier-2 node. The scheduler copies that into
the Argo template; modules without one (e.g. `stub-video`) schedule anywhere.

Label the nodes accordingly:

```bash
kubectl label node <gpu-node-40gb> cogniforge.rack/tier=tier3
kubectl label node <gpu-node-24gb> cogniforge.rack/tier=tier2
```

To actually use tier-2 nodes, add a module that fits (e.g. a quantized or
1B-class video model) with its own `node_selector` and `gpu: 1`; the same
`resources` + `node_selector` fields drive everything.

## 1.6 AWS bring-up, step by step (console + CLI)

The fastest path is `provisioning/ec2/bringup-ec2.sh` (see
`provisioning/ec2/README.md`) or the Terraform module for the same layout.
This is the manual equivalent.

**Console — create a key pair + instance (tier3 example):**
1. EC2 → Key Pairs → Create → download the `.pem`.
2. EC2 → Instances → Launch. Pick **Amazon Linux 2023** AMI.
3. For the control plane choose `t3.medium`; for a GPU worker choose
   `p4d.24xlarge` (A100 40GB) or `p5.48xlarge` (H100 80GB) — tier3.
   For a cheap demo choose `g4dn.xlarge` (16GB) — tier2, no 14B model.
4. Instance Type → Configure: attach your key pair, allow SSH.
5. Security Group: open **22**, **6443**, **9345**, **30000–32767** to your IP
   (or the rack's CIDR).
6. Storage: 60GB root for the CP, 200GB for GPU nodes (model weights).
7. IAM: assign the instance profile with `AmazonEC2ContainerRegistryPowerUser`
   so `aws ecr get-login-password` works without keys.
8. Advanced → User data: leave empty — SSH in after boot and run
   `bringup-ec2.sh` yourself (or use the Terraform module, which injects
   `user_data` automatically).
9. Launch. Then run `bringup-ec2.sh` on the CP as root.

**CLI (equivalent, from your laptop):**

```bash
aws ec2 run-instances --image-id $(aws ec2 describe-images --owners amazon \
  --filters 'Name=name,Values=al2023-ami-2023.*-x86_64' --query 'reverse(sort_by(Images,&CreationDate))[0].ImageId' --output text) \
  --instance-type p4d.24xlarge --key-name my-key \
  --security-group-ids <sg> --subnet-id <subnet> --iam-instance-profile Name=cogniforge-rack-node \
  --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=200}' \
  --user-data "$(cat provisioning/ec2/bringup-ec2.sh)"
```

**ECR — create the repos and push images:**

```bash
aws ecr create-repository --repository-name cogniforge/rack-engine
aws ecr create-repository --repository-name cogniforge/wan21
aws ecr create-repository --repository-name cogniforge/stub-video
aws ecr create-repository --repository-name cogniforge/rack-engine-frontend
aws ecr create-repository --repository-name cogniforge/base
# push (on a machine with Docker + this repo):
REGISTRY=$(aws ecr describe-repositories --query 'repositories[?repositoryName==`cogniforge/rack-engine`].repositoryUri' --output text | sed 's#/rack-engine##')
REGISTRY=$REGISTRY ./scripts/build-images.sh
```

**On the CP instance:**

```bash
sudo su -
REGION=us-east-1 \
REGISTRY=<ecr-prefix-without-repo-name> \
NODE_TIER=tier1 RKE2_TOKEN=CHANGE_ME \
bash /opt/cogniforge-rack/provisioning/ec2/bringup-ec2.sh
```

The script ends with `kubectl get nodes -o wide`. From your laptop:

```bash
scp -i my-key.pem ec2-user@<cp-ip>:/etc/rancher/rke2/rke2.yaml .
kubectl --kubeconfig ./rke2.yaml get nodes -o wide
curl http://<cp-ip>:$(kubectl --kubeconfig ./rke2.yaml get svc -n default rack-engine-backend -o jsonpath='{.spec.ports[0].nodePort}')
```

Expose the API/frontend NodePorts (30080/30081) to the internet through the SG
if the UI must be reachable beyond your IP.

## 2. Install the NVIDIA GPU Operator (drivers + device plugin)

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

## 3. Node labels (optional)

For a single-GPU cluster, a simple boolean is enough:

```bash
kubectl label node gpu-worker-01 cogniforge.rack/gpu=true
```

For mixed tier-1/tier-2/tier-3 pools, use `cogniforge.rack/tier=tier2|tier3`
instead (see section 1.5) so the wan21 `node_selector` works out of the box.

## 4. Install Argo Workflows

If you are not using `kubernetes/rke2-install.sh` (which installs Argo on the
server), deploy it the usual way:

```bash
kubectl create namespace argo
kubectl apply -n argo -f https://github.com/argoproj/argo-workflows/releases/download/v3.6.5/install.yaml
```

The backend expects `argo-workflows-server` at
`http://argo-workflows-server.argo:2746` (see `rack-engine/backend/config.yaml`).

## 5. Build and push the images

```bash
REGISTRY=my.registry.example.com/cogniforge ./scripts/build-images.sh
```

This builds `base` (CUDA layer), `wan21` (real model), `stub-video` (CPU
placeholder), the Rack Engine API and the frontend, then pushes them. Then
deploy with the **same** `REGISTRY` (plus `IMAGE_TAG` if you did not use
`latest`); `deploy-cluster.sh` rewrites the `image:` field in the staged
module definitions to `${REGISTRY}/<module>:<tag>` so Argo steps pull from
exactly where you pushed:

## 6. Deploy

```bash
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
REGISTRY=my.registry.example.com/cogniforge ./scripts/deploy-cluster.sh
```

`deploy-cluster.sh` packages every `modules/*/module.yaml` into the
`rack-modules` configMap (so the backend discovers `wan21` and `stub-video`
at startup), deploys the backend + frontend, and registers the modules.

## 7. Generate

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
