#!/usr/bin/env bash
# Скачивает aksusbd_*_amd64.deb (Sentinel HASP RTE) для офлайн-сборки и кэша в install/.
# Публичное зеркало: пакет из комплекта FEFLOW (тот же aksusbd от Thales/Sentinel).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/install/sentinel-hasp/deb"
URL_DEFAULT='https://download.feflow.com/download/FEFLOW/linux/dongle-7.80/aksusbd_7.80-1_amd64.deb'
URL="${SENTINEL_AKSUSBD_DEB_URL:-$URL_DEFAULT}"
DEB_NAME="$(basename "$URL")"

mkdir -p "$OUT"
if [[ -f "$OUT/$DEB_NAME" ]]; then
  echo "Уже есть: $OUT/$DEB_NAME"
  exit 0
fi

echo "Загрузка: $URL"
wget -nv -O "$OUT/$DEB_NAME" "$URL"
ls -la "$OUT/$DEB_NAME"
