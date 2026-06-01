#!/usr/bin/env bash
# PostgreSQL (pg_ctl) + штатный init-скрипт 1С: /etc/init.d/srv1cv83 → ragent -daemon (как в поставке deb).
set -euo pipefail

# Как в install/linux/systemd/srv1cv83@.service.d/10-stability.conf
ulimit -n 65536 2>/dev/null || true

PGDATA="${PGDATA:-/var/lib/pgpro/std-16/data}"
VER="${ONEC_VERSION:-8.3.19.1351}"
LOG_PG=/var/log/1cv8/postgres.log

INIT_1C="/etc/init.d/srv1cv83"
[[ -x "$INIT_1C" ]] || INIT_1C="/opt/1cv8/x86_64/${VER}/srv1cv83"

mkdir -p /var/log/1cv8
touch "$LOG_PG"
chown postgres:postgres "$LOG_PG" 2>/dev/null || true

if [[ ! -f "${PGDATA}/PG_VERSION" ]]; then
  echo "start-stack: нет кластера в PGDATA=$PGDATA. Один раз: INIT_PGDATA=1 docker compose run --rm app" >&2
  exit 1
fi

if ! runuser -u postgres -- /opt/pgpro/std-16/bin/pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then
  echo "start-stack: запуск PostgreSQL (5432)…"
  runuser -u postgres -- /opt/pgpro/std-16/bin/pg_ctl -D "$PGDATA" -l "$LOG_PG" start
fi

if [[ -x /usr/sbin/aksusbd_x86_64 ]] && ! pidof aksusbd_x86_64 >/dev/null 2>&1; then
  echo "start-stack: запуск aksusbd (Sentinel HASP)…"
  /usr/sbin/aksusbd_x86_64 2>/dev/null || true
elif [[ -x /usr/sbin/aksusbd ]] && ! pidof aksusbd >/dev/null 2>&1; then
  echo "start-stack: запуск aksusbd (Sentinel HASP)…"
  /usr/sbin/aksusbd 2>/dev/null || true
fi

if [[ -x /usr/sbin/pcscd ]] && ! pidof pcscd >/dev/null 2>&1; then
  /usr/sbin/pcscd 2>/dev/null || true
fi

if [[ ! -x "$INIT_1C" ]]; then
  echo "start-stack: не найден init-скрипт 1С: $INIT_1C" >&2
  exec tail -f /dev/null
fi

G_VER_MAJOR=$(echo "$VER" | awk -F. '{print $1}')
G_VER_MINOR=$(echo "$VER" | awk -F. '{print $2}')
G_VER_BUILD=$(echo "$VER" | awk -F. '{print $3}')
G_VER_RELEASE=$(echo "$VER" | awk -F. '{print $4}')
PIDFILE="/var/run/srv1cv${G_VER_MAJOR}-${G_VER_MINOR}-${G_VER_BUILD}-${G_VER_RELEASE}.pid"

dump_ragent_diag() {
  echo "start-stack: --- диагностика после остановки ragent ---" >&2
  "$INIT_1C" status 2>&1 | head -40 >&2 || true
  ps -C ragent -o pid=,user=,args= 2>&1 | head -20 >&2 || true
  tail -40 "$LOG_PG" 2>/dev/null >&2 || true
  find /home/usr1cv8/.1cv8 -maxdepth 5 -type f \( -iname '*.log' -o -iname 'crash*' -o -iname '*.dump' \) 2>/dev/null | head -25 >&2 || true
}

cleanup() {
  echo "start-stack: остановка (сигнал)…"
  "$INIT_1C" stop 2>/dev/null || true
  if runuser -u postgres -- /opt/pgpro/std-16/bin/pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then
    runuser -u postgres -- /opt/pgpro/std-16/bin/pg_ctl -D "$PGDATA" stop -m fast || true
  fi
  exit 0
}
trap cleanup SIGTERM SIGINT

echo "start-stack: супервизор 1С (при падении ragent — перезапуск и диагностика в лог контейнера)…"

while true; do
  echo "start-stack: запуск 1С через ${INIT_1C} (ragent -daemon, см. /etc/default/srv1cv83)…"
  "$INIT_1C" stop 2>/dev/null || true
  sleep 1
  rm -f "$PIDFILE" 2>/dev/null || true
  "$INIT_1C" start

  for ((i = 0; i < 150; i++)); do
    [[ -f "$PIDFILE" ]] && break
    sleep 0.2
  done
  if [[ ! -f "$PIDFILE" ]]; then
    echo "start-stack: после start нет pidfile $PIDFILE — повтор через 5с" >&2
    dump_ragent_diag
    sleep 5
    continue
  fi

  RAGENT_PID="$(cat "$PIDFILE" 2>/dev/null | tr -d '[:space:]')"
  if [[ -z "$RAGENT_PID" ]] || ! kill -0 "$RAGENT_PID" 2>/dev/null; then
    echo "start-stack: в pidfile процесс не жив (pid=$RAGENT_PID) — повтор через 5с" >&2
    dump_ragent_diag
    sleep 5
    continue
  fi

  echo "start-stack: ragent pid $RAGENT_PID — ожидание (PID 1 контейнера); PostgreSQL :5432"

  while kill -0 "$RAGENT_PID" 2>/dev/null; do
    sleep 5
  done

  echo "start-stack: ragent завершился — перезапуск через 5с" >&2
  dump_ragent_diag
  sleep 5
done
