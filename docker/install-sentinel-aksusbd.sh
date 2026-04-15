#!/usr/bin/env bash
# Установка пакета Sentinel HASP RTE (aksusbd) без падения postinst при docker build (нет USB).
#
#   1) /usr/sbin/policy-rc.d → exit 101 (invoke-rc.d не стартует службы);
#   2) dpkg --unpack;
#   3) заглушки для бинарников, которые postinst вызывает напрямую;
#   4) dpkg --configure;
#   5) восстановление бинарников, снятие policy-rc.d.
#
#   install-sentinel-aksusbd.sh --url https://.../aksusbd_*_amd64.deb
#   install-sentinel-aksusbd.sh --file /path/to/aksusbd_*_amd64.deb
#
# Опционально: STUB_BINARIES="/usr/sbin/foo /usr/sbin/bar" — доп. пути через пробел.
#
set -euo pipefail

DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
export DEBIAN_FRONTEND

POLICY_RC=/usr/sbin/policy-rc.d

if [[ -n "${STUB_BINARIES:-}" ]]; then
  read -r -a STUB_PATHS <<<"$STUB_BINARIES"
else
  STUB_PATHS=(/usr/sbin/aksusbd_x86_64 /usr/sbin/hasplmd_x86_64)
fi

DEB_PATH=""
DEB_URL=""

usage() {
  echo "Использование: $0 --url URL | --file PATH" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)
      [[ -n "${2:-}" ]] || usage
      DEB_URL=$2
      shift 2
      ;;
    --file)
      [[ -n "${2:-}" ]] || usage
      DEB_PATH=$2
      shift 2
      ;;
    -h|--help)
      head -22 "$0" | tail -20
      exit 0
      ;;
    *) usage ;;
  esac
done

policy_rc_enable() {
  printf '%s\n' '#!/bin/sh' 'exit 101' >"$POLICY_RC"
  chmod +x "$POLICY_RC"
}

policy_rc_disable() {
  rm -f "$POLICY_RC"
}

restore_stubs() {
  local f
  for f in "${STUB_PATHS[@]}"; do
    [[ -f "${f}.real" ]] || continue
    mv "${f}.real" "$f"
  done
}

trap 'restore_stubs 2>/dev/null || true; policy_rc_disable 2>/dev/null || true' EXIT

install_stub_for() {
  local f=$1
  [[ -f "$f" ]] || return 0
  [[ -f "${f}.real" ]] && return 0
  mv "$f" "${f}.real"
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$f"
  chmod +x "$f"
}

configure_deb() {
  local deb=$1
  local pkg
  pkg="$(dpkg-deb -f "$deb" Package)"
  dpkg --unpack "$deb"
  local p
  for p in "${STUB_PATHS[@]}"; do
    install_stub_for "$p"
  done
  if ! dpkg --configure "$pkg"; then
    apt-get install -y -f
    dpkg --configure "$pkg"
  fi
}

if [[ -n "$DEB_PATH" ]]; then
  [[ -f "$DEB_PATH" ]] || { echo "Нет файла: $DEB_PATH" >&2; exit 1; }
elif [[ -n "$DEB_URL" ]]; then
  if ! command -v wget >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y --no-install-recommends wget ca-certificates
  fi
  DEB_PATH="/tmp/aksusbd-install.deb"
  wget -nv -O "$DEB_PATH" "$DEB_URL"
else
  usage
fi

policy_rc_enable
configure_deb "$DEB_PATH"
restore_stubs
policy_rc_disable
trap - EXIT
rm -f "$DEB_PATH"
