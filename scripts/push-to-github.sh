#!/usr/bin/env bash
# scripts/push-to-github.sh
# Pushes this repo to a GitHub remote.
#
# Usage:
#   GH_TOKEN=<personal-access-token> ./scripts/push-to-github.sh
#   ./scripts/push-to-github.sh https://github.com/androidcircus/ManifestAI-cogniforge-vx.git
#
# Default remote is the primary CogniForge repo. Other manifests:
#   - AIONCoreManifest-AI-Video          https://github.com/androidcircus/AIONCoreManifest-AI-Video
#   - ManifestAI-cogniforge-vx   (default) https://github.com/androidcircus/ManifestAI-cogniforge-vx
#   - Manifest-AI-Videos                 https://github.com/androidcircus/Manifest-AI-Videos
#   - Manifest-AI-Video                  https://github.com/androidcircus/Manifest-AI-Video
set -euo pipefail

cd "$(dirname "$0")/.."

DEFAULT_REPO="https://github.com/androidcircus/ManifestAI-cogniforge-vx.git"
REPO_URL="${1:-${REPO_URL:-$DEFAULT_REPO}}"
BRANCH="${BRANCH:-main}"

if [ -n "${GH_TOKEN:-}" ]; then
  # Inject the token as basic auth without ever writing it to the config file.
  repo="${REPO_URL/https:\/\//https:\/\/x-access-token:${GH_TOKEN}@}"
  HEADER="--header Authorization:${GH_TOKEN}"
  PUSH_URL="$repo"
else
  PUSH_URL="$REPO_URL"
fi

git remote remove cogniforge 2>/dev/null || true
git remote add cogniforge "$REPO_URL"

echo "==> Pushing $(git rev-parse --short HEAD) -> ${REPO_URL} (${BRANCH})"
if [ -n "${GH_TOKEN:-}" ]; then
  git push "$PUSH_URL" "HEAD:${BRANCH}"
else
  git push -u cogniforge "HEAD:${BRANCH}"
fi

echo "==> Done. Push complete."
[ -n "${GH_TOKEN:-}" ] && echo "    (used a scoped token for auth)"