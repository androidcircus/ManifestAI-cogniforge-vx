#!/bin/bash
# scripts/test-generation.sh
# End-to-end test: submit a pipeline through the Rack Engine API, poll Argo,
# then download the produced video.
#
# Usage: RACK_ENGINE=http://<node-ip>:<nodePort> ./scripts/test-generation.sh
set -euo pipefail

RACK_ENGINE="${RACK_ENGINE:-http://localhost:8000}"
IMAGE_URL="${IMAGE_URL:-https://example.com/cat.jpg}"
# Generator module to use. "stub-video" needs no GPU and is the emulator/
# no-GPU dev path; "wan21" is the real ~14B model on a GPU node.
MODULE_TYPE="${MODULE_TYPE:-wan21}"

echo "==> Submitting pipeline to ${RACK_ENGINE}"
RESP=$(curl -s -X POST "${RACK_ENGINE}/pipelines" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"e2e-test\",
    \"modules\": [
      {\"id\": \"input-1\", \"type\": \"input\", \"params\": {\"image_url\": \"${IMAGE_URL}\"}},
      {\"id\": \"gen-1\", \"type\": \"${MODULE_TYPE}\", \"params\": {\"image_url\": \"${IMAGE_URL}\", \"duration\": 5}},
      {\"id\": \"out-1\", \"type\": \"output\", \"params\": {}}
    ],
    \"connections\": [
      {\"source\": \"input-1\", \"target\": \"gen-1\"},
      {\"source\": \"gen-1\", \"target\": \"out-1\"}
    ]
  }")

PIPELINE_ID=$(echo "${RESP}" | python3 -c "import sys, json; print(json.load(sys.stdin)['pipeline_id'])")
echo "Pipeline: ${PIPELINE_ID}"

echo "==> Polling status (10s interval)"
for i in $(seq 1 120); do
  STATUS=$(curl -s "${RACK_ENGINE}/pipelines/${PIPELINE_ID}/status")
  PHASE=$(echo "${STATUS}" | python3 -c "import sys, json; print(json.load(sys.stdin).get('status', 'unknown'))")
  echo "  [${i}] ${PHASE} - ${STATUS}" | head -c 400; echo
  case "${PHASE}" in
    succeeded)
      echo "✅ Video generation complete!"
      break
      ;;
    failed)
      echo "❌ Pipeline failed: ${STATUS}"
      exit 1
      ;;
  esac
  sleep 10
done

if [ "${PHASE:-}" != "succeeded" ]; then
  echo "❌ Timed out waiting for the pipeline." >&2
  exit 1
fi

echo "==> Downloading video"
curl -s -o "rack-output-${PIPELINE_ID}.mp4" \
  "${RACK_ENGINE}/pipelines/${PIPELINE_ID}/output"
echo "🎬 Saved rack-output-${PIPELINE_ID}.mp4"
ls -lh "rack-output-${PIPELINE_ID}.mp4"
