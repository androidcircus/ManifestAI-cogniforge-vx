#!/usr/bin/env bash
# scripts/make-release.sh
# Builds a versioned source artifact of the last commit.
#
# Optional preflight: run the standalone GEMM test first.
#   ./scripts/make-release.sh            # dist/cogniforge-rack-v0.1.0.zip
#   ./scripts/make-release.sh v1.2.3
set -euo pipefail

cd "$(dirname "$0")/.."

TAG="${1:-$(cat VERSION)}"
TAG="${TAG#v}"
OUT="dist/cogniforge-rack-v${TAG}.zip"
mkdir -p dist

if [ "${PREFLIGHT:-1}" = "1" ] && command -v gcc >/dev/null 2>&1; then
  echo "==> preflight: standalone GEMM test"
  ( cd provisioning/emulator && bash test-gemm.sh )
fi

echo "==> archiving HEAD -> ${OUT}"
git archive --format=zip --prefix="cogniforge-rack-v${TAG}/" -o "${OUT}" HEAD

echo "==> done: $(du -h "${OUT}" | cut -f1)  ${OUT}"