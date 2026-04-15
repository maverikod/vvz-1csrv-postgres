#!/usr/bin/env bash
# Создаёт каталоги по умолчанию на хосте и выставляет владельцев:
#   postgres:1001 — кластер PostgreSQL
#   usr1cv8:1000 — логи, 1cv8, cache
# Настройки: /etc/pgsql1c/conf.d (root:root или root:postgres — чтение postmaster)
set -euo pipefail

PGSQL1C_VAR="${PGSQL1C_VAR:-/var/pgsql1c}"
PGSQL1C_LOG="${PGSQL1C_LOG:-/var/log/pgsql1c}"
PGSQL1C_ETC="${PGSQL1C_ETC:-/etc/pgsql1c}"

mkdir -p \
  "$PGSQL1C_VAR/postgres" \
  "$PGSQL1C_VAR/1cv8" \
  "$PGSQL1C_VAR/cache/cfstorage" \
  "$PGSQL1C_VAR/cache/app" \
  "$PGSQL1C_LOG" \
  "$PGSQL1C_ETC/conf.d"

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R 1001:1001 "$PGSQL1C_VAR/postgres"
  chmod 0700 "$PGSQL1C_VAR/postgres"
  chown -R 1000:1000 "$PGSQL1C_LOG" "$PGSQL1C_VAR/1cv8" "$PGSQL1C_VAR/cache"
  chown root:root "$PGSQL1C_ETC" "$PGSQL1C_ETC/conf.d" 2>/dev/null || true
else
  echo "Запустите от root для chown: sudo PGSQL1C_VAR=... $0" >&2
  echo "Каталоги созданы под: $PGSQL1C_VAR, $PGSQL1C_LOG, $PGSQL1C_ETC"
fi
