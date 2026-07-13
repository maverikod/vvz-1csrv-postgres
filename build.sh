#!/usr/bin/env bash
set -euo pipefail
set +x

ROOT="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$ROOT/.env"
IMAGE="docker.io/vasilyvz/vvz-1csrv-postgres:8.3.27.2214-dual-8.3.19.1351-r1"
PINNED_DIGEST="sha256:386ecbad5e5c709f589668aed5aa657c5f570f36a675567ce5b8aab75af67c23"

docker build --pull=false -f "$ROOT/Dockerfile.8.3.27" -t "$IMAGE" "$ROOT"

remote_digest="$(docker manifest inspect --verbose "$IMAGE" 2>/dev/null \
  | sed -n 's/^[[:space:]]*"digest": "\([^"]*\)",/\1/p' | head -1 || true)"
if [[ -n "$remote_digest" ]]; then
  [[ "$remote_digest" == "$PINNED_DIGEST" ]] || {
    echo "Refusing to overwrite immutable tag: remote=$remote_digest expected=$PINNED_DIGEST" >&2
    exit 1
  }
  echo "Remote immutable tag already matches $PINNED_DIGEST; push skipped."
else
  [[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE" >&2; exit 1; }
  DOCKERHUB_PAT="$(sed -n 's/^DOCKERHUB_PAT=//p' "$ENV_FILE" | tail -1)"
  [[ -n "$DOCKERHUB_PAT" ]] || { echo "DOCKERHUB_PAT is missing" >&2; exit 1; }
  tmp_config="$(mktemp -d)"
  trap 'rm -rf "$tmp_config"' EXIT
  export DOCKER_CONFIG="$tmp_config"
  printf '%s' "$DOCKERHUB_PAT" | docker login --username vasilyvz --password-stdin
  unset DOCKERHUB_PAT
  docker push "$IMAGE"
fi

verified_digest="$(docker manifest inspect --verbose "$IMAGE" \
  | sed -n 's/^[[:space:]]*"digest": "\([^"]*\)",/\1/p' | head -1)"
[[ "$verified_digest" == "$PINNED_DIGEST" ]]
"$ROOT/packaging/build-deb-8.3.27.sh"
