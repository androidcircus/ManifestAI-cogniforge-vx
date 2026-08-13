#!/usr/bin/env bash
# scripts/boot-onboarding.sh
# One-token setup for the GitHub / Render / Colab / base44 targets.
#
# Flow:
#   GH_TOKEN=<PAT> ./scripts/boot-onboarding.sh
#
#     1. validates the token and hands back to you (never prints the token)
#     2. picks the GitHub repo (default: ManifestAI-cogniforge-vx)
#     3. pushes the latest commit
#     4. prints the exact Render Blueprint / Colab / base44 URLs to use
#
# Requires: git, curl. No node, npm, docker, aws or gh needed.
# Works from any machine (tested on the build box). PAT scope: "repo"
# (both "repo" and "workflow" if you include the CI workflow).
set -euo pipefail

cd "$(dirname "$0")/.."

# ---------------------------------------------------------------------------
GITHUB_USER="androidcircus"
DEFAULT_REPO="ManifestAI-cogniforge-vx"
EXTRA_REPOS=(
  "AIONCoreManifest-AI-Video"
  "Manifest-AI-Videos"
  "Manifest-AI-Video"
)
BRANCH="${BRANCH:-main}"
TAG="$([ -f VERSION ] && cat VERSION || echo 0.1.0)"

# ---------------------------------------------------------------------------
echo "==> Diagnosing local tools"
for t in git curl; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing: $t" >&2; exit 1; }
done
echo "    git: $(git --version | awk '{print $3}')   curl: $(curl --version | head -1)"
echo

# ---------------------------------------------------------------------------
if [ -z "${GH_TOKEN:-}" ]; then
  echo "GH_TOKEN is not set.
Create one at:  https://github.com/settings/tokens/new
Recommended scopes: repo  (+  workflow  if you deploy the CI in .github/).
Then rerun this script with it exported:

    \$env:GH_TOKEN = 'ghp_xxxx'   # PowerShell  (or  export GH_TOKEN=ghp_xxxx)
    bash scripts/boot-onboarding.sh
" >&2
  exit 1
fi

echo "==> Validating token (identity is masked; your token stays out of the repo)"
API="https://api.github.com/user"
who="$(curl -fsS -H "Authorization: token ${GH_TOKEN}" -H "Accept: application/vnd.github+json" "$API")"
who_login="$(printf '%s' "$who" | grep -m1 '"login"' | sed -E 's/.*: *"([^"]+)".*/\1/')"
who_name="$(printf '%s' "$who" | grep -m1 '"name"' | sed -E 's/.*: *"([^"]+)".*/\1/' || true)"
echo "    authenticated as: ${who_name:-${who_login}}"
if [ -n "$who_login" ] && [ "$who_login" != "$GITHUB_USER" ]; then
  echo "NOTE: token belongs to ${who_login}, not https://github.com/${GITHUB_USER}." >&2
  echo "      Continuing anyway (it will just target that account's repos)." >&2
fi
echo

# ---------------------------------------------------------------------------
echo "==> Choosing the repo to push to"
echo "  0) ${DEFAULT_REPO}"
i=1
for r in "${EXTRA_REPOS[@]}"; do
  printf '  %d) %s\n' "$i" "$r"
  i=$((i+1))
done
printf 'Choosing repo index (0-3) [0]: '
read -r idx || idx=0
idx="${idx:-0}"
if [ "$idx" = "0" ]; then REPO="$DEFAULT_REPO"; else REPO="${EXTRA_REPOS[$((idx-1))]}"; fi
echo "    -> ${GITHUB_USER}/${REPO}"

# full URL = https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_USER}/${REPO}.git
PUSH_URL="https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_USER}/${REPO}.git"
echo

echo "==> Checking repo exists on GitHub"
code="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: token ${GH_TOKEN}" \
  "https://api.github.com/repos/${GITHUB_USER}/${REPO}")"
echo "    github.com/${GITHUB_USER}/${REPO}  -> HTTP ${code}"
if [ "$code" = "404" ]; then
  echo "    repo does not exist yet; creating it..."
  curl -fsS -X POST -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -d "{\"name\":\"${REPO}\",\"description\":\"CogniForge Rack - AI video generation platform\",\"has_issues\":true}" \
    "https://api.github.com/user/repos" >/dev/null
  echo "    created."
fi

echo
echo "==> Pushing HEAD to main"
git remote remove cogniforge 2>/dev/null || true
git remote add cogniforge "https://github.com/${GITHUB_USER}/${REPO}.git"
# The token goes only in the one-shot URL below — never written to .git/config.
git push "$PUSH_URL" "HEAD:${BRANCH}" --force-with-lease 2>/dev/null \
  || git push "$PUSH_URL" "HEAD:${BRANCH}"
git remote set-url cogniforge "https://github.com/${GITHUB_USER}/${REPO}.git"
echo "    pushed $(git rev-parse --short HEAD) -> ${GITHUB_USER}/${REPO}:${BRANCH}"

# ---------------------------------------------------------------------------
echo
echo "==> Your targets are ready"
REPO_HTML="https://github.com/${GITHUB_USER}/${REPO}"
NB_PATH="notebooks/rack-demo.ipynb"
printf '
  GitHub      : %s
  Raw readme  : %s/raw/%s/README.md

  Render      : https://dashboard.render.com/select-repo?type=blueprint
                (select %s/%s; render.yaml is auto-detected)

  Colab       : https://colab.research.google.com/github/%s/%s/HEAD/%s
  base44      : import from: %s/blob/%s/%s

  CI on GitHub once pushed:
                open %s/actions
  Release zip : dist/cogniforge-rack-v%s.zip  (or: bash scripts/make-release.sh)
' \
  "$REPO_HTML" "$REPO_HTML" "$BRANCH" \
  "$GITHUB_USER" "$REPO" \
  "$GITHUB_USER" "$REPO" "$NB_PATH" \
  "$REPO_HTML" "$BRANCH" "$NB_PATH" \
  "$REPO_HTML" \
  "$TAG"

echo "==> done."