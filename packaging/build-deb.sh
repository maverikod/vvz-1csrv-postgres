#!/usr/bin/env bash
# Сборка .deb из packaging/debian/vvz-1csrv-postgres
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$ROOT/packaging/debian/vvz-1csrv-postgres"
VER="$(grep -m1 '^Version:' "$STAGE/DEBIAN/control" | awk '{print $2}')"
OUT="${1:-$ROOT/packaging/vvz-1csrv-postgres_${VER}_all.deb}"

mkdir -p "$STAGE/usr/share/vvz-1csrv-postgres"
cp -f "$ROOT/packaging/docker-compose.ship.yml" "$STAGE/usr/share/vvz-1csrv-postgres/docker-compose.yml"
cp -f "$STAGE/etc/default/pgsql1c-stack" "$STAGE/usr/share/vvz-1csrv-postgres/pgsql1c-stack.default"
mkdir -p "$STAGE/usr/libexec/vvz-1csrv-postgres" "$STAGE/lib/systemd/system"
cp -f "$ROOT/install/linux/systemd/stack-start.sh" "$STAGE/usr/libexec/vvz-1csrv-postgres/stack-start"
cp -f "$ROOT/install/linux/systemd/stack-stop.sh" "$STAGE/usr/libexec/vvz-1csrv-postgres/stack-stop"
cp -f "$ROOT/install/linux/systemd/stack-status.sh" "$STAGE/usr/libexec/vvz-1csrv-postgres/stack-status"
chmod +x "$STAGE/usr/libexec/vvz-1csrv-postgres/stack-start" "$STAGE/usr/libexec/vvz-1csrv-postgres/stack-stop" "$STAGE/usr/libexec/vvz-1csrv-postgres/stack-status"
cp -f "$ROOT/install/linux/systemd/pgsql1c-stack.service" "$STAGE/lib/systemd/system/pgsql1c-stack.service"

mkdir -p "$STAGE/usr/sbin"
cp -f "$ROOT/scripts/pg1cchkpwd" "$STAGE/usr/sbin/pg1cchkpwd"
chmod 755 "$STAGE/usr/sbin/pg1cchkpwd"
chmod 755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/preinst" "$STAGE/DEBIAN/prerm" 2>/dev/null || true

fakeroot dpkg-deb --build "$STAGE" "$OUT"
echo "Готово: $OUT"
ls -la "$OUT"
