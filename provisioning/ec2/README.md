# EC2 provisioning (AWS)

## 1. One-shot script: `bringup-ec2.sh`

Runs the whole bring-up on a fresh Amazon Linux 2023 / Ubuntu instance:
RKE2, Helm, NVIDIA GPU Operator, Argo, node-tier labels, then
`scripts/deploy-cluster.sh`.

```bash
REGION=us-east-1 \
REGISTRY=123456789012.dkr.ecr.us-east-1.amazonaws.com/cogniforge \
NODE_TIER=tier1 \
RKE2_TOKEN=<shared-token> \
bash provisioning/ec2/bringup-ec2.sh          # on the control plane
```

GPU workers join with `RKE2_TOKEN` + `RKE2_SERVER=<cp-ip>` and `NODE_TIER=tier3`.

## 2. Terraform module: `terraform/`

One command infra: VPC, security group (SSH/RKE2/NodePort), ECR repos for all
five images, an instance-profile for ECR + SSM, the control plane, and
`gpu_worker_count` GPU nodes (type/tier selectable).

```bash
terraform -chdir=provisioning/ec2/terraform init
terraform -chdir=provisioning/ec2/terraform plan \
  -var ssh_key_name=my-key -var rke2_token=<shared-token> \
  -var gpu_worker_count=1 -var gpu_instance_type=p4d.24xlarge \
  -var gpu_tier=tier3
terraform -chdir=provisioning/ec2/terraform apply \
  -var ... 
```

`user_data` on each instance clones the rack repo and runs
`bringup-ec2.sh` with the right tier; workers embed the control plane's
private IP as `RKE2_SERVER`.

## 3. Minimum instance sizes for real Wan 2.1 (tier3)

| Model config          | Instance            | VRAM  |
|-----------------------|---------------------|-------|
| 14B fp16              | p4d.24xlarge (A100) | 40 GB |
| 14B fp16 high-res     | p5.48xlarge (H100)  | 80 GB |

g4dn/g5 (16-24 GB) are tier-2: unsuitable for the 14B model; keep them for
smaller jobs or leave `gpu_worker_count=0`.