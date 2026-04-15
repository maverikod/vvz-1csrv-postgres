#!/usr/bin/env bash
# Один прогон: сборка .deb, сборка Docker-образа, push на реестр (по умолчанию Docker Hub).
#
# Требуется: docker login (один раз на машине).
#
# Переменные окружения (все необязательны):
#   DOCKER_REGISTRY   — по умолчанию docker.io
#   DOCKER_USER       — учётная запись на Hub, по умолчанию vasilyvz
#   DOCKER_IMAGE      — имя репозитория, по умолчанию vvz-1csrv-postgres
#   DOCKERFILE        — Dockerfile в корне проекта, по умолчанию Dockerfile
#   IMAGE_TAG         — дополнительный тег (по умолчанию = версия из DEBIAN/control)
#
# Примеры:
#   ./scripts/release.sh
#   DOCKER_USER=mylogin ./scripts/release.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

: "${DOCKER_REGISTRY:=docker.io}"
: "${DOCKER_USER:=vasilyvz}"
: "${DOCKER_IMAGE:=vvz-1csrv-postgres}"
: "${DOCKERFILE:=Dockerfile}"

DEB_VER="$(grep -m1 '^Version:' "$ROOT/packaging/debian/vvz-1csrv-postgres/DEBIAN/control" | awk '{print $2}')"
: "${IMAGE_TAG:=${DEB_VER}}"

DEB_PATH="$ROOT/packaging/vvz-1csrv-postgres_${DEB_VER}_all.deb"
IMAGE_REF="${DOCKER_REGISTRY}/${DOCKER_USER}/${DOCKER_IMAGE}"

echo "=== [1/3] Сборка пакета vvz-1csrv-postgres (${DEB_VER}) ==="
"$ROOT/packaging/build-deb.sh"
[[ -f "$DEB_PATH" ]] || { echo "release: не найден $DEB_PATH" >&2; exit 1; }

echo "=== [2/3] Сборка образа (${DOCKERFILE}) ==="
docker build \
  -f "$ROOT/$DOCKERFILE" \
  -t "${IMAGE_REF}:${IMAGE_TAG}" \
  -t "${IMAGE_REF}:latest" \
  "$ROOT"

echo "=== [3/3] Отправка в реестр ==="
docker push "${IMAGE_REF}:${IMAGE_TAG}"
docker push "${IMAGE_REF}:latest"

echo ""
echo "Готово."
echo "  Debian: $DEB_PATH"
echo "  Образ:  ${IMAGE_REF}:${IMAGE_TAG}, ${IMAGE_REF}:latest"
