#!/bin/bash
# kubernetes/rke2-install.sh
# Bootstraps RKE2 on the VM cluster.
#
#   MODE=server ./rke2-install.sh    # on cogniforge-cp (installs full stack)
#   MODE=agent   RKE2_TOKEN=<tok> ./rke2-install.sh   # on each worker
#
# Server mode additionally installs Helm, the NVIDIA GPU Operator and
# Argo Workflows.
set -euo pipefail

MODE="${MODE:?Set MODE=server or MODE=agent}"
RKE2_URL="${RKE2_URL:-https://cogniforge-cp:9345}"

# ---------------------------------------------------------------------------
if [ "${MODE}" = "server" ]; then
  echo "==> Installing RKE2 server"
  curl -sfL https://get.rke2.io | sudo sh -
  sudo systemctl enable rke2-server
  sudo systemctl start rke2-server

  echo "==> Waiting for API server"
  until sudo /var/lib/rancher/rke2/bin/kubectl get nodes >/dev/null 2>&1; do sleep 3; done
  export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
  export PATH="/var/lib/rancher/rke2/bin:${PATH}"

  echo "==> Installing Helm"
  curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
  chmod 700 /tmp/get_helm.sh
  /tmp/get_helm.sh

  echo "==> Adding Helm repos"
  helm repo add nvidia https://nvidia.github.io/gpu-operator
  helm repo add argo https://argoproj.github.io/argo-helm
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  helm repo update

  echo "==> Installing NVIDIA GPU Operator"
  helm install gpu-operator nvidia/gpu-operator \
    -n gpu-operator --create-namespace \
    -f kubernetes/gpu-operator-values.yaml
  kubectl -n gpu-operator rollout status daemonset/gpu-operator -w || true

  echo "==> Installing Argo Workflows"
  helm install argo argo/argo-workflows -n argo --create-namespace \
    --set server.serviceType=ClusterIP \
    --set controller.workflowNamespaces={default,argo}
  kubectl -n argo rollout status deployment/argo-workflows-server || true

  echo "==> Installing Prometheus + Grafana"
  helm install monitoring prometheus-community/kube-prometheus-stack \
    -n monitoring --create-namespace \
    --set grafana.adminPassword=cogniforge \
    --set prometheus.prometheusSpec.scrapeInterval=30s

  echo "==> Node token for workers:"
  sudo cat /var/lib/rancher/rke2/server/node-token
  echo "==> Server ready."

# ---------------------------------------------------------------------------
elif [ "${MODE}" = "agent" ]; then
  echo "==> Installing RKE2 agent"
  curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="agent" sudo sh -
  sudo mkdir -p /etc/rancher/rke2
  printf 'server: %s\ntoken: %s\n' "${RKE2_URL}" "${RKE2_TOKEN:?Set RKE2_TOKEN}" \
    | sudo tee /etc/rancher/rke2/config.yaml >/dev/null
  sudo systemctl enable rke2-agent
  sudo systemctl start rke2-agent
  echo "==> Agent started. Check: kubectl get nodes"
else
  echo "Unknown MODE=${MODE} (expected server|agent)" >&2
  exit 1
fi
