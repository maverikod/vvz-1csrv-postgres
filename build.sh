#!/usr/bin/env bash
# Build the co-installable Debian package, then build and publish only the
# 1C 8.3.27.2214 image.
# Docker Hub authentication is read from DOCKERHUB_PAT in the project-root .env.

set -euo pipefail

# Never allow a caller's xtrace setting to expose secret handling below.
set +x

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEB_BUILD="$ROOT/packaging/build-deb-8.3.27.sh"
ENV_FILE="$ROOT/.env"
DOCKERFILE="$ROOT/Dockerfile.8.3.27"
DOCKER_REGISTRY="docker.io"
DOCKER_USER="vasilyvz"
IMAGE_REF="${DOCKER_REGISTRY}/${DOCKER_USER}/vvz-1csrv-postgres:8.3.27.2214"

die() {
  printf 'build.sh: %s\n' "$1" >&2
  exit 1
}

[[ -x "$DEB_BUILD" ]] || die "Debian package builder not found or not executable: $DEB_BUILD"
printf 'Building the co-installable Debian package...\n'
"$DEB_BUILD"

command -v docker >/dev/null 2>&1 || die "docker is not installed or is not in PATH"
[[ -f "$DOCKERFILE" ]] || die "Dockerfile not found: $DOCKERFILE"
[[ -f "$ENV_FILE" ]] || die ".env not found: $ENV_FILE"

# Parse exactly one assignment without sourcing or evaluating .env. Values may
# be unquoted or enclosed in one matching pair of single/double quotes. Docker
# Hub PATs do not contain whitespace, so whitespace-bearing values are rejected.
DOCKERHUB_PAT=''
pat_assignments=0
while IFS= read -r env_line || [[ -n "$env_line" ]]; do
  if [[ "$env_line" =~ ^[[:space:]]*(export[[:space:]]+)?DOCKERHUB_PAT[[:space:]]*= ]]; then
    ((pat_assignments += 1))
    ((pat_assignments == 1)) || die "DOCKERHUB_PAT is defined more than once in .env"

    assignment_prefix="${BASH_REMATCH[0]}"
    raw_value="${env_line:${#assignment_prefix}}"
    [[ -n "$raw_value" ]] || die "DOCKERHUB_PAT is empty in .env"
    [[ ! "$raw_value" =~ [[:space:]] ]] || die "DOCKERHUB_PAT must not contain whitespace"

    first_char="${raw_value:0:1}"
    if [[ "$first_char" == "'" || "$first_char" == '"' ]]; then
      ((${#raw_value} >= 2)) || die "DOCKERHUB_PAT has malformed quotes in .env"
      last_char="${raw_value: -1}"
      [[ "$last_char" == "$first_char" ]] || die "DOCKERHUB_PAT has malformed quotes in .env"
      DOCKERHUB_PAT="${raw_value:1:${#raw_value}-2}"
      [[ "$DOCKERHUB_PAT" != *"$first_char"* ]] || die "DOCKERHUB_PAT has malformed quotes in .env"
    else
      [[ "$raw_value" != *"'"* && "$raw_value" != *'"'* ]] || die "DOCKERHUB_PAT has malformed quotes in .env"
      DOCKERHUB_PAT="$raw_value"
    fi

    [[ -n "$DOCKERHUB_PAT" ]] || die "DOCKERHUB_PAT is empty in .env"
  fi
done < "$ENV_FILE"

((pat_assignments == 1)) || die "DOCKERHUB_PAT is not defined in .env"

DOCKER_CONFIG_DIR=''
cleanup() {
  if [[ -n "$DOCKER_CONFIG_DIR" && -d "$DOCKER_CONFIG_DIR" ]]; then
    rm -rf -- "$DOCKER_CONFIG_DIR"
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

umask 077
DOCKER_CONFIG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/docker-config-8.3.27.XXXXXX")"
chmod 700 "$DOCKER_CONFIG_DIR"
export DOCKER_CONFIG="$DOCKER_CONFIG_DIR"

printf 'Authenticating to %s as %s...\n' "$DOCKER_REGISTRY" "$DOCKER_USER"
printf '%s\n' "$DOCKERHUB_PAT" | docker login \
  --username "$DOCKER_USER" \
  --password-stdin \
  "$DOCKER_REGISTRY"
unset DOCKERHUB_PAT raw_value env_line assignment_prefix first_char last_char

printf 'Building %s...\n' "$IMAGE_REF"
docker build \
  --file "$DOCKERFILE" \
  --tag "$IMAGE_REF" \
  "$ROOT"

printf 'Pushing %s...\n' "$IMAGE_REF"
docker push "$IMAGE_REF"

printf 'Published %s\n' "$IMAGE_REF"
