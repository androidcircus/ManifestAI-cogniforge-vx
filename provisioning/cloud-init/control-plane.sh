#!/bin/bash
# provisioning/cloud-init/control-plane.sh
# Bootstraps the control-plane VM: RKE2 server, kubectl, Helm, node token output.
set -euo pipefail

echo "==> Installing RKE2 server"
curl -sfL https://get.rke2.io | sudo sh -
sudo systemctl enable rke2-server
sudo systemctl start rke2-server

echo "==> Waiting for RKE2 to become ready"
until sudo /var/lib/rancher/rke2/bin/kubectl get nodes >/dev/null 2>&1; do
  sleep 3
done

echo "==> Setting up kubectl for the vagrant user"
mkdir -p /home/vagrant/.kube
sudo cp /etc/rancher/rke2/rke2.yaml /home/vagrant/.kube/config
sudo chown -R vagrant:vagrant /home/vagrant/.kube

echo "==> Installing Helm"
curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 /tmp/get_helm.sh
/tmp/get_helm.sh

echo "==> RKE2 node token (use this to join workers):"
sudo cat /var/lib/rancher/rke2/server/node-token

echo "==> Control plane ready."
