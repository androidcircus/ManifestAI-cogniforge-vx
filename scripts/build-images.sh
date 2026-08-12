#!/bin/bash
# scripts/build-images.sh
# Builds every container image the rack needs and pushes them to the registry
# the cluster pulls from. Run from the repo root on a machine with docker.
#
#   REGISTRY=my.registry.example.com/cogniforge ./scripts/build-images.sh
#
# Without REGISTRY images are tagged as manifestai/<name>:latest and pushed to
# Docker Hub. For a local RKE2/K3s node set REGISTRY=127.0.0.1:5001 and push
# to an in-cluster registry, or `docker save` + import directly on the node.
set -euo pipefail

cd "$(dirname "$0")/.."

REGISTRY="${REGISTRY:-manifestai}"
PUSH="${PUSH:-1}"       # 0 to build without pushing
VERSION="${VERSION:-latest}"

img() { echo "${REGISTRY}/$1:${VERSION}"; }

build() {
  local name="$1" dir="$2"
  echo "==> building ${name} from ${dir}"
  docker build -t "$(img "${name}")" "${dir}"
  if [ "${PUSH}" = "1" ]; then
    docker push "$(img "${name}")"
  fi
}

[ "${PUSH}" = "1" ] && echo "==> registry: ${REGISTRY} (pushing)" || \
  echo "==> registry: ${REGISTRY} (build only)"

build base modules/base/pytorch-cuda        # NVIDIA CUDA base layer for wan21
build wan21 modules/wan21                   # real Wan 2.1 14B, needs GPUs
build stub-video modules/stub-video         # CPU-only placeholder generator
build rack-engine rack-engine/backend       # Rack Engine API
build rack-engine-frontend rack-engine/frontend

echo
echo "==> done. Images:"
docker images | grep -E "${REGISTRY}/" | grep "${VERSION}" || true
echo
echo "   Next: ./scripts/deploy-cluster.sh"