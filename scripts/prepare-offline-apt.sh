#!/usr/bin/env bash
# Запускать на машине с Docker и доступом в интернет.
# Скачивает полное замыкание зависимостей (в т.ч. пакеты, уже есть в базовом образе).
#
# На изолированной машине:
#   docker load -i ubuntu-noble.tar
#   docker build --network=none -f Dockerfile.offline -t vvz-1csrv-postgres:offline .

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Sentinel HASP aksusbd для Dockerfile.offline (копируется из install/sentinel-hasp/deb/)
if [[ -x "$ROOT/scripts/download-sentinel-aksusbd.sh" ]]; then
  "$ROOT/scripts/download-sentinel-aksusbd.sh" || true
fi
INSTALL="$ROOT/install"
OUT="$INSTALL/offline-apt"
INNER="$ROOT/scripts/prepare-offline-apt-inner.sh"

if [[ ! -d "$INSTALL/deb" ]] || ! ls "$INSTALL/deb"/postgrespro-std-16-*.deb &>/dev/null; then
  echo "Нет $INSTALL/deb/postgrespro-std-16-*.deb" >&2
  exit 1
fi
if [[ ! -f "$INSTALL/deb64_8_3_19_1351.tar.gz" ]]; then
  echo "Нет $INSTALL/deb64_8_3_19_1351.tar.gz" >&2
  exit 1
fi

mkdir -p "$OUT"
rm -f "$OUT"/*.deb "$OUT/Packages" "$OUT/Packages.gz" 2>/dev/null || true

docker run --rm \
  -v "$INSTALL:/install:ro" \
  -v "$OUT:/out" \
  -v "$INNER:/inner.sh:ro" \
  ubuntu:noble \
  bash /inner.sh

echo "Локальный репозиторий: $OUT"
ls "$OUT"/*.deb 2>/dev/null | wc -l
