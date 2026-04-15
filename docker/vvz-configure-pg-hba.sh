#!/usr/bin/env bash
# Генерация pg_hba.conf: доступ по TCP только с localhost и из подсети Docker (хост + другие контейнеры).
# Отключить: PGSQL1C_PGHBA_MODE=skip
set -euo pipefail

PGDATA="${PGDATA:-/var/lib/pgpro/std-16/data}"

[[ -f "${PGDATA}/PG_VERSION" ]] || exit 0
[[ "${PGSQL1C_PGHBA_MODE:-managed}" == "skip" ]] && exit 0

SUBNET="${PGSQL1C_DOCKER_SUBNET:-172.31.0.0/16}"
# md5 — типично для 1С и старых клиентов; scram-sha-256 — см. PGSQL1C_PGHBA_AUTH_METHOD
AUTH="${PGSQL1C_PGHBA_AUTH_METHOD:-md5}"

{
  echo "# vvz-managed — не редактировать вручную; см. PGSQL1C_DOCKER_SUBNET, PGSQL1C_PGHBA_MODE=skip"
  echo "# TYPE  DATABASE        USER            ADDRESS                 METHOD"
  echo "local   all             all                                     peer"
  echo "host    all             all             127.0.0.1/32            ${AUTH}"
  echo "host    all             all             ::1/128                 ${AUTH}"
  echo "host    all             all             ${SUBNET}               ${AUTH}"
} >"${PGDATA}/pg_hba.conf.new"
mv -f "${PGDATA}/pg_hba.conf.new" "${PGDATA}/pg_hba.conf"
chown postgres:postgres "${PGDATA}/pg_hba.conf" 2>/dev/null || true
