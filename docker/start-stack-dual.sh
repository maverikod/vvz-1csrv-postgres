#!/usr/bin/env bash
set -euo pipefail

ulimit -n 65536 2>/dev/null || true

PGDATA="${PGDATA:-/var/lib/pgpro/std-16/data}"
PG_LOG=/var/log/1cv8/postgres.log
CFG_8319="${ONEC_8319_CONFIG:-/etc/vvz-1c/srv1cv83-8319.conf}"
CFG_8327="${ONEC_8327_CONFIG:-/etc/vvz-1c/srv1cv83-8327.conf}"
STOPPING=0
PID_8319=""
PID_8327=""

mkdir -p /var/log/1cv8 /var/cache/1cv8/8319 /var/cache/1cv8/8327
touch "$PG_LOG" /var/log/1cv8/ragent-8319.log /var/log/1cv8/ragent-8327.log
chown postgres:postgres "$PG_LOG" 2>/dev/null || true
chown -R usr1cv8:grp1cv8 /var/cache/1cv8 /home/usr1cv8/.1cv8 2>/dev/null || true

[[ -f "${PGDATA}/PG_VERSION" ]] || {
  echo "start-stack-dual: no PostgreSQL cluster in PGDATA=${PGDATA}" >&2
  exit 1
}

if ! runuser -u postgres -- /opt/pgpro/std-16/bin/pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then
  runuser -u postgres -- /opt/pgpro/std-16/bin/pg_ctl -D "$PGDATA" -l "$PG_LOG" start
fi

if [[ -x /usr/sbin/aksusbd_x86_64 ]] && ! pidof aksusbd_x86_64 >/dev/null 2>&1; then
  /usr/sbin/aksusbd_x86_64 2>/dev/null || true
elif [[ -x /usr/sbin/aksusbd ]] && ! pidof aksusbd >/dev/null 2>&1; then
  /usr/sbin/aksusbd 2>/dev/null || true
fi
if [[ -x /usr/sbin/pcscd ]] && ! pidof pcscd >/dev/null 2>&1; then
  /usr/sbin/pcscd 2>/dev/null || true
fi

validate_config() {
  local cfg="$1" expected_version="$2"
  [[ -r "$cfg" ]] || { echo "start-stack-dual: missing config $cfg" >&2; return 1; }
  (
    set -u
    # shellcheck source=/dev/null
    source "$cfg"
    [[ "$ONEC_VERSION" == "$expected_version" ]]
    [[ -x "/opt/1cv8/x86_64/${ONEC_VERSION}/ragent" ]]
    [[ "$SRV1CV8_DEBUG" == "1" ]]
  ) || { echo "start-stack-dual: invalid config $cfg" >&2; return 1; }
}

validate_config "$CFG_8319" 8.3.19.1351
validate_config "$CFG_8327" 8.3.27.2214

launch_family() {
  local cfg="$1" log="$2" cache="$3"
  (
    set -a
    # shellcheck source=/dev/null
    source "$cfg"
    set +a
    mkdir -p "$SRV1CV8_DATA" "$cache"
    chown -R "$SRV1CV8_USER:$SRV1CV8_GROUP" "$SRV1CV8_DATA" "$cache" 2>/dev/null || true
    args=(
      -d "$SRV1CV8_DATA"
      -port "$SRV1CV8_PORT"
      -regport "$SRV1CV8_REGPORT"
      -range "$SRV1CV8_RANGE"
      -seclev "$SRV1CV8_SECLEV"
      -pingPeriod "$SRV1CV8_PINGPERIOD"
      -pingTimeout "$SRV1CV8_PINGTIMEOUT"
    )
    [[ "$SRV1CV8_DEBUG" == "1" ]] && args+=(-debug)
    export HOME=/home/usr1cv8 TMPDIR="$cache"
    exec setsid setpriv \
      --reuid="$SRV1CV8_USER" --regid="$SRV1CV8_GROUP" --init-groups \
      "/opt/1cv8/x86_64/${ONEC_VERSION}/ragent" "${args[@]}"
  ) >>"$log" 2>&1 &
  LAUNCHED_PID=$!
}

start_8319() {
  launch_family "$CFG_8319" /var/log/1cv8/ragent-8319.log /var/cache/1cv8/8319
  PID_8319=$LAUNCHED_PID
  echo "start-stack-dual: 8.3.19.1351 ragent pid=${PID_8319}"
}

start_8327() {
  launch_family "$CFG_8327" /var/log/1cv8/ragent-8327.log /var/cache/1cv8/8327
  PID_8327=$LAUNCHED_PID
  echo "start-stack-dual: 8.3.27.2214 ragent pid=${PID_8327}"
}

stop_group() {
  local pid="$1"
  [[ -n "$pid" ]] || return 0
  kill -TERM -- "-$pid" 2>/dev/null || true
  for _ in {1..50}; do
    kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null || true; return 0; }
    sleep 0.2
  done
  kill -KILL -- "-$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

shutdown() {
  trap - TERM INT EXIT
  STOPPING=1
  stop_group "$PID_8319"
  stop_group "$PID_8327"
  if runuser -u postgres -- /opt/pgpro/std-16/bin/pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then
    runuser -u postgres -- /opt/pgpro/std-16/bin/pg_ctl -D "$PGDATA" stop -m fast || true
  fi
  exit 0
}
trap shutdown TERM INT

start_8319
start_8327

while (( STOPPING == 0 )); do
  if ! kill -0 "$PID_8319" 2>/dev/null; then
    wait "$PID_8319" 2>/dev/null || true
    echo "start-stack-dual: restarting 8.3.19.1351" >&2
    sleep 5
    start_8319
  fi
  if ! kill -0 "$PID_8327" 2>/dev/null; then
    wait "$PID_8327" 2>/dev/null || true
    echo "start-stack-dual: restarting 8.3.27.2214" >&2
    sleep 5
    start_8327
  fi
  sleep 2
done
