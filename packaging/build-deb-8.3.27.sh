#!/usr/bin/env bash
# Build the co-installable 1C 8.3.27 package without touching either runtime.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$ROOT/packaging/debian/vvz-1csrv-postgres-8327"
VER="$(awk '/^Version:/ {print $2; exit}' "$STAGE/DEBIAN/control")"
OUT="${1:-$ROOT/packaging/vvz-1csrv-postgres-8327_${VER}_all.deb}"

mkdir -p "$STAGE/usr/share/vvz-1csrv-postgres-8327"
cp -f "$ROOT/packaging/docker-compose.8.3.27.ship.yml" \
  "$STAGE/usr/share/vvz-1csrv-postgres-8327/docker-compose.yml"
cp -f "$STAGE/etc/default/pgsql1c-stack-8327" \
  "$STAGE/usr/share/vvz-1csrv-postgres-8327/pgsql1c-stack-8327.default"
cp -f "$ROOT/docker/8.3.27/srv1cv83" \
  "$STAGE/usr/share/vvz-1csrv-postgres-8327/srv1cv83.default"

chmod 0755 \
  "$STAGE/DEBIAN/preinst" "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm" \
  "$STAGE/usr/bin/vvz-1csrv-postgres-8327" \
  "$STAGE/usr/sbin/pg1cchkpwd-8327" \
  "$STAGE/usr/libexec/vvz-1csrv-postgres-8327/"*
chmod 0644 \
  "$STAGE/DEBIAN/control" "$STAGE/DEBIAN/conffiles" \
  "$STAGE/etc/default/"* "$STAGE/etc/cron.d/"* \
  "$STAGE/lib/systemd/system/"* "$STAGE/usr/share/vvz-1csrv-postgres-8327/"*

fakeroot dpkg-deb --build "$STAGE" "$OUT"
printf 'Built: %s\n' "$OUT"
ls -la "$OUT"
