#!/usr/bin/env bash
# Build the co-installable 1C 8.3.27 package without touching either runtime.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$ROOT/packaging/debian/vvz-1csrv-postgres-8327"
VER="$(awk '/^Version:/ {print $2; exit}' "$STAGE/DEBIAN/control")"
OUT="${1:-$ROOT/packaging/vvz-1csrv-postgres-8327_${VER}_all.deb}"

# dpkg-deb embeds archive member mtimes. Use the newest Git commit timestamp
# that owns package inputs, unless the caller supplied Debian's standard
# SOURCE_DATE_EPOCH explicitly. This stays stable for identical source inputs
# and avoids depending on checkout or build time.
if [[ -z "${SOURCE_DATE_EPOCH:-}" ]]; then
  command -v git >/dev/null 2>&1 || {
    echo "build-deb-8.3.27.sh: git is required when SOURCE_DATE_EPOCH is unset" >&2
    exit 1
  }
  SOURCE_DATE_EPOCH="$(
    git -C "$ROOT" log -1 --format=%ct -- \
      packaging/build-deb-8.3.27.sh \
      packaging/docker-compose.8.3.27.ship.yml \
      packaging/srv1cv83.8.3.27.package \
      packaging/debian/vvz-1csrv-postgres-8327
  )"
fi
[[ "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]] || {
  echo "build-deb-8.3.27.sh: SOURCE_DATE_EPOCH must be a Unix timestamp" >&2
  exit 1
}
export SOURCE_DATE_EPOCH

mkdir -p "$STAGE/usr/share/vvz-1csrv-postgres-8327"
cp -f "$ROOT/packaging/docker-compose.8.3.27.ship.yml" \
  "$STAGE/usr/share/vvz-1csrv-postgres-8327/docker-compose.yml"
cp -f "$STAGE/etc/default/pgsql1c-stack-8327" \
  "$STAGE/usr/share/vvz-1csrv-postgres-8327/pgsql1c-stack-8327.default"
cp -f "$ROOT/packaging/srv1cv83.8.3.27.package" \
  "$STAGE/usr/share/vvz-1csrv-postgres-8327/srv1cv83.default"

find "$STAGE" -type d -exec chmod 0755 {} +
chmod 0755 \
  "$STAGE/DEBIAN/preinst" "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm" \
  "$STAGE/usr/bin/vvz-1csrv-postgres-8327" \
  "$STAGE/usr/sbin/pg1cchkpwd-8327" \
  "$STAGE/usr/libexec/vvz-1csrv-postgres-8327/"*
chmod 0644 \
  "$STAGE/DEBIAN/control" "$STAGE/DEBIAN/conffiles" \
  "$STAGE/etc/default/"* "$STAGE/etc/cron.d/"* \
  "$STAGE/lib/systemd/system/"* \
  "$STAGE/usr/share/vvz-1csrv-postgres-8327/docker-compose.yml" \
  "$STAGE/usr/share/vvz-1csrv-postgres-8327/pgsql1c-stack-8327.default" \
  "$STAGE/usr/share/vvz-1csrv-postgres-8327/srv1cv83.default" \
  "$STAGE/usr/share/vvz-1csrv-postgres-8327/debconf/locale.template"

fakeroot dpkg-deb --build "$STAGE" "$OUT"
printf 'Built: %s\n' "$OUT"
ls -la "$OUT"
