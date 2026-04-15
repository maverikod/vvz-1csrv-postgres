#!/usr/bin/env bash
# Вызывается из prepare-offline-apt.sh внутри контейнера ubuntu:noble.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
shopt -s nullglob

apt-get update
# Только wget: не ставить dpkg-dev до print-uris — иначе подтянутся зависимости,
# и apt перестанет выводить URI для части пакетов (офлайн-каталог получится неполным).
apt-get install -y --no-install-recommends wget ca-certificates

WORK=/work
mkdir -p "$WORK/1c"
cp /install/deb/*.deb "$WORK/"
gzip -cdf /install/deb64_8_3_19_1351.tar.gz | tar -xC "$WORK/1c"

mapfile -t URI_LINES < <(apt-get install --print-uris -y \
  ca-certificates \
  liblcms2-utils \
  pcscd \
  libpcsclite1 \
  libccid \
  usbutils \
  "$WORK"/postgrespro-std-16-libs_*.deb \
  "$WORK"/postgrespro-std-16-client_*.deb \
  "$WORK"/postgrespro-std-16-server_*.deb \
  "$WORK"/postgrespro-std-16-contrib_*.deb \
  "$WORK"/1c/1c-enterprise-8.3.19.1351-common-nls_8.3.19-1351_amd64.deb \
  "$WORK"/1c/1c-enterprise-8.3.19.1351-common_8.3.19-1351_amd64.deb \
  "$WORK"/1c/1c-enterprise-8.3.19.1351-server-nls_8.3.19-1351_amd64.deb \
  "$WORK"/1c/1c-enterprise-8.3.19.1351-server_8.3.19-1351_amd64.deb \
  "$WORK"/1c/1c-enterprise-8.3.19.1351-ws-nls_8.3.19-1351_amd64.deb \
  "$WORK"/1c/1c-enterprise-8.3.19.1351-ws_8.3.19-1351_amd64.deb \
  2>/dev/null | grep -E "^'https?://")

for line in "${URI_LINES[@]}"; do
  uri=$(echo "$line" | awk -F"'" '{print $2}')
  fn=$(echo "$line" | awk -F"'" '{print $3}' | awk '{print $1}')
  [[ -n "$fn" && -n "$uri" ]] || { echo "Не разобрали строку: $line" >&2; exit 1; }
  wget -nv -O "/out/$fn" "$uri"
done

# Пакеты уже есть в базовом образе — в print-uris нет http-строк; для офлайн-репозитория кладём .deb явно.
(cd /out && apt-get download ca-certificates openssl 2>/dev/null || true)

apt-get install -y dpkg-dev

cp -f "$WORK"/*.deb /out/
cp -f "$WORK"/1c/1c-enterprise-8.3.19.1351-*_amd64.deb /out/

cd /out
rm -f Packages Packages.gz
dpkg-scanpackages . /dev/null 2>/dev/null | gzip -9c > Packages.gz
deb_count=$(find . -maxdepth 1 -name "*.deb" | wc -l)
echo "Готово: $deb_count deb в /out"
