#!/bin/bash
# provisioning/cloud-init/worker.sh
# Joins a worker VM to the RKE2 cluster.
#
# Requires:
#   RKE2_URL   - server endpoint (https://<control-plane>:9345)
#   RKE2_TOKEN - node token from the control plane. Provide it via Vagrant
#                env or export it before re-running this script:
#                  export RKE2_TOKEN=$(cat /var/lib/rancher/rke2/server/node-token)
set -euo pipefail

RKE2_URL="${RKE2_URL:?Set RKE2_URL (e.g. https://cogniforge-cp:9345)}"

echo "==> Installing RKE2 agent"
curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="agent" sudo sh -

sudo mkdir -p /etc/rancher/rke2
if [ -n "${RKE2_TOKEN:-}" ]; then
  echo "server: ${RKE2_URL}" | sudo tee /etc/rancher/rke2/config.yaml
  echo "token: ${RKE2_TOKEN}" | sudo tee -a /etc/rancher/rke2/config.yaml
  sudo systemctl enable rke2-agent
  sudo systemctl start rke2-agent
  echo "==> Worker agent started."
else
  echo "==> WARNING: RKE2_TOKEN not set. Write /etc/rancher/rke2/config.yaml"
  echo "    manually (server + token) then: sudo systemctl start rke2-agent"
fi

echo "==> Installing GPU prerequisites (toolkit components are delivered by"
echo "    the NVIDIA GPU Operator, but drivers must match the host GPU):"
sudo apt-get update
sudo apt-get install -y pciutils kmod

echo "==> Worker bootstrap complete."
