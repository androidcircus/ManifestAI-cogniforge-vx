#!/bin/bash
# scripts/deploy-cluster.sh
# Deploys the full rack stack onto the RKE2 cluster.
#
# Run on the control-plane VM with KUBECONFIG set:
#   export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
#   ./scripts/deploy-cluster.sh
set -euo pipefail

cd "$(dirname "$0")/.."

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/rke2/rke2.yaml}"
REGISTRY="${REGISTRY:-manifestai}"
NS="${NS:-default}"

echo "==> [1/7] Storage"
kubectl apply -f kubernetes/storage-class.yaml

echo "==> [2/7] Mount /mnt/nvme on every worker"
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: rack-init-mnt
  namespace: default
spec:
  selector:
    matchLabels: {app: rack-init-mnt}
  template:
    metadata:
      labels: {app: rack-init-mnt}
    spec:
      hostNetwork: true
      containers:
        - name: init
          image: busybox:1.36
          command: ["sh", "-c", "mkdir -p /mnt/nvme && sleep infinity"]
          volumeMounts:
            - name: mnt
              mountPath: /mnt
          securityContext: {privileged: true}
      volumes:
        - name: mnt
          hostPath: {path: /mnt, type: DirectoryOrCreate}
EOF
kubectl rollout status ds/rack-init-mnt --timeout=120s || true

echo "==> [3/7] Rack Engine backend"
# Package every modules/<dir>/module.yaml into a single configMap so the
# backend finds them at startup (RACK_MODULES_DIR=/modules). Key names keep
# the subdirectory, e.g. wan21/module.yaml, stub-video/module.yaml.
rm -rf /tmp/rack-modules-cm && mkdir -p /tmp/rack-modules-cm
for d in modules/*/; do
  if [ -f "${d}module.yaml" ]; then
    rel="${d#modules/}"                 # e.g. "wan21/", "stub-video/"
    mkdir -p "/tmp/rack-modules-cm/${rel}"
    cm_file="/tmp/rack-modules-cm/${rel}module.yaml"
    cp "${d}module.yaml" "${cm_file}"
    # Keep the module's image tag in sync with the registry used for builds.
    # build-images.sh tags each module ${REGISTRY}/<dir>:${VERSION}; rewrite the
    # staged copy (never the repo file) so Argo steps pull the right image.
    if [ "${REGISTRY}" != "manifestai" ]; then
      img_name="${rel%/}"
      python3 - "${cm_file}" "${REGISTRY}/${img_name}:${IMAGE_TAG:-latest}" <<'PY'
import sys
path, newimg = sys.argv[1], sys.argv[2]
out = [l if not l.startswith("image:") else f"image: {newimg}\n"
       for l in open(path, encoding="utf-8")]
open(path, "w", encoding="utf-8").writelines(out)
PY
    fi
  fi
done
kubectl create configmap rack-modules --from-file=/tmp/rack-modules-cm \
  -n "${NS}" -o yaml --dry-run=client | kubectl apply -f - || true
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: rack-engine-backend, namespace: ${NS}}
spec:
  replicas: 1
  selector: {matchLabels: {app: rack-engine-backend}}
  template:
    metadata: {labels: {app: rack-engine-backend}}
    spec:
      containers:
        - name: backend
          image: ${REGISTRY}/rack-engine:latest
          imagePullPolicy: IfNotPresent
          ports: [{containerPort: 8000}]
          env:
            - {name: RACK_MODULES_DIR, value: /modules}
            - {name: RACK_OUTPUT_DIR, value: /mnt/outputs}
            - {name: RACK_ENGINE_CONFIG, value: /app/config.yaml}
          volumeMounts:
            - {name: modules, mountPath: /modules}
            - {name: outputs, mountPath: /mnt/outputs}
      volumes:
        - name: modules
          configMap: {name: rack-modules}
        - name: outputs
          persistentVolumeClaim: {claimName: rack-outputs}
EOF
kubectl rollout status deployment/rack-engine-backend --timeout=180s
kubectl expose deployment rack-engine-backend --port=8000 --target-port=8000 \
  --type=NodePort -n "${NS}" --dry-run=client -o yaml | kubectl apply -f - || true

echo "==> [4/7] Rack Engine frontend (nginx serving the static build)"
(
  cd rack-engine/frontend
  npm install
  REACT_APP_API_BASE="${RACK_ENGINE_URL:-http://localhost:8000}" npm run build
  docker build -t "${REGISTRY}/rack-engine-frontend:latest" .
)
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: rack-engine-frontend, namespace: ${NS}}
spec:
  replicas: 1
  selector: {matchLabels: {app: rack-engine-frontend}}
  template:
    metadata: {labels: {app: rack-engine-frontend}}
    spec:
      containers:
        - name: frontend
          image: ${REGISTRY}/rack-engine-frontend:latest
          imagePullPolicy: IfNotPresent
          ports: [{containerPort: 80}]
EOF
kubectl rollout status deployment/rack-engine-frontend --timeout=180s
kubectl expose deployment rack-engine-frontend --port=80 --target-port=80 \
  --type=NodePort -n "${NS}" --dry-run=client -o yaml | kubectl apply -f - || true

echo "==> [5/7] Monitoring"
kubectl apply -f monitoring/prometheus-config.yaml || true

echo "==> [6/7] Register modules with the Rack Engine"
for d in modules/*/; do
  if [ -f "${d}module.yaml" ]; then
    name="${d#modules/}"; name="${name%/}"
    MODULE_JSON=$(python3 -c '
import json, yaml, sys
with open(sys.argv[1]) as f: d = yaml.safe_load(f)
print(json.dumps({"id": d["id"], "name": d["name"],
                  "category": d.get("category", "generation"),
                  "icon": d.get("icon", "module"), "definition": d}))
' "${d}module.yaml")
    echo "  registering ${name}"
    curl -s -X POST http://rack-engine-backend:8000/modules \
      -H "Content-Type: application/json" -d "${MODULE_JSON}" || true
  fi
done

echo "==> [7/7] Post-deploy checks"
kubectl get pods -n gpu-operator | head -n 12 || true
kubectl get workflows -n "${NS}" || true

echo
echo "✅ Deployment complete."
echo "   API:      http://<node-ip>:$(kubectl get svc rack-engine-backend -n ${NS} -o jsonpath='{.spec.ports[0].nodePort}')"
echo "   Frontend: http://<node-ip>:$(kubectl get svc rack-engine-frontend -n ${NS} -o jsonpath='{.spec.ports[0].nodePort}')"
