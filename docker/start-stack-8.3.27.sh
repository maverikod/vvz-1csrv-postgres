#!/usr/bin/env bash
# PostgreSQL + 1C 8.3.27 container supervisor (8.3.27 no longer ships srv1cv83).
set -euo pipefail

ulimit -n 65536 2>/dev/null || true

PGDATA="${PGDATA:-/var/lib/pgpro/std-16/data}"
VER="${ONEC_VERSION:-8.3.27.2214}"
LOG_PG=/var/log/1cv8/postgres.log
RAGENT="/opt/1cv8/x86_64/${VER}/ragent"

# shellcheck disable=SC1091
[[ ! -r /etc/default/srv1cv83 ]] || source /etc/default/srv1cv83

: "${SRV1CV8_USER:=usr1cv8}"
: "${SRV1CV8_DATA:=/home/usr1cv8/.1cv8/1C/1cv8/}"
: "${SRV1CV8_PORT:=1640}"
: "${SRV1CV8_REGPORT:=1641}"
: "${SRV1CV8_RANGE:=1660:1691}"
: "${SRV1CV8_SECLEV:=0}"
: "${SRV1CV8_PINGPERIOD:=1000}"
: "${SRV1CV8_PINGTIMEOUT:=5000}"
: "${SRV1CV8_DEBUG:=1}"

mkdir -p /var/log/1cv8 "$SRV1CV8_DATA"
touch "$LOG_PG"
chown postgres:postgres "$LOG_PG" 2>/dev/null || true
chown -R usr1cv8:grp1cv8 /home/usr1cv8/.1cv8 2>/dev/null || true

if [[ ! -f "${PGDATA}/PG_VERSION" ]]; then
  echo "start-stack-8.3.27: нет кластера в PGDATA=$PGDATA" >&2
  exit 1
fi

if ! runuser -u postgres -- /opt/pgpro/std-16/bin/pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then
  echo "start-stack-8.3.27: запуск PostgreSQL (5432)…"
  runuser -u postgres -- /opt/pgpro/std-16/bin/pg_ctl -D "$PGDATA" -l "$LOG_PG" start
fi

if [[ -x /usr/sbin/aksusbd_x86_64 ]] && ! pidof aksusbd_x86_64 >/dev/null 2>&1; then
  echo "start-stack-8.3.27: запуск aksusbd (Sentinel HASP)…"
  /usr/sbin/aksusbd_x86_64 2>/dev/null || true
elif [[ -x /usr/sbin/aksusbd ]] && ! pidof aksusbd >/dev/null 2>&1; then
  echo "start-stack-8.3.27: запуск aksusbd (Sentinel HASP)…"
  /usr/sbin/aksusbd 2>/dev/null || true
fi

if [[ -x /usr/sbin/pcscd ]] && ! pidof pcscd >/dev/null 2>&1; then
  /usr/sbin/pcscd 2>/dev/null || true
fi

[[ -x "$RAGENT" ]] || { echo "start-stack-8.3.27: не найден $RAGENT" >&2; exit 1; }

RAGENT_ARGS=(
  -d "$SRV1CV8_DATA"
  -port "$SRV1CV8_PORT"
  -regport "$SRV1CV8_REGPORT"
  -range "$SRV1CV8_RANGE"
  -seclev "$SRV1CV8_SECLEV"
  -pingPeriod "$SRV1CV8_PINGPERIOD"
  -pingTimeout "$SRV1CV8_PINGTIMEOUT"
)
[[ "$SRV1CV8_DEBUG" == "1" ]] && RAGENT_ARGS+=(-debug)

RAGENT_PID=""
cleanup() {
  echo "start-stack-8.3.27: остановка (сигнал)…"
  [[ -z "$RAGENT_PID" ]] || kill "$RAGENT_PID" 2>/dev/null || true
  wait "$RAGENT_PID" 2>/dev/null || true
  if runuser -u postgres -- /opt/pgpro/std-16/bin/pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then
    runuser -u postgres -- /opt/pgpro/std-16/bin/pg_ctl -D "$PGDATA" stop -m fast || true
  fi
  exit 0
}
trap cleanup SIGTERM SIGINT

echo "start-stack-8.3.27: запуск ragent ${VER}, port=${SRV1CV8_PORT}, regport=${SRV1CV8_REGPORT}, range=${SRV1CV8_RANGE}, debug=${SRV1CV8_DEBUG}"
runuser -u "$SRV1CV8_USER" -- "$RAGENT" "${RAGENT_ARGS[@]}" &
RAGENT_PID=$!
wait "$RAGENT_PID"
