#!/usr/bin/env bash
# Создаёт каталоги на хосте, системных пользователей pgsql1c-* и выставляет владельцев.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/pgsql1c-host-users.sh
source "${ROOT}/scripts/pgsql1c-host-users.sh"

PGSQL1C_VAR="${PGSQL1C_VAR:-/var/pgsql1c}"
PGSQL1C_LOG="${PGSQL1C_LOG:-/var/log/pgsql1c}"
PGSQL1C_ETC="${PGSQL1C_ETC:-/etc/pgsql1c}"

if [[ "$(id -u)" -eq 0 ]]; then
  pgsql1c_ensure_host_users
  pgsql1c_migrate_legacy_ownership
  pgsql1c_chown_host_data
  if [[ ! -f "${PGSQL1C_ETC}/srv1cv83" ]] && [[ -f "${ROOT}/docker/srv1cv83.default" ]]; then
    install -m 0644 -o root -g root "${ROOT}/docker/srv1cv83.default" "${PGSQL1C_ETC}/srv1cv83"
  fi
  echo "Каталоги и владельцы: PGSQL1C_VAR=${PGSQL1C_VAR}, PGSQL1C_LOG=${PGSQL1C_LOG}, PGSQL1C_ETC=${PGSQL1C_ETC}"
else
  mkdir -p \
    "${PGSQL1C_VAR}/postgres" \
    "${PGSQL1C_VAR}/1cv8" \
    "${PGSQL1C_VAR}/cache/cfstorage" \
    "${PGSQL1C_VAR}/cache/app" \
    "${PGSQL1C_BACKUP:-${PGSQL1C_VAR}/backups}" \
    "${PGSQL1C_LOG}" \
    "${PGSQL1C_ETC}/conf.d"
  echo "Запустите от root для пользователей и chown: sudo PGSQL1C_VAR=... $0" >&2
  echo "Каталоги созданы под: ${PGSQL1C_VAR}, ${PGSQL1C_LOG}, ${PGSQL1C_ETC}"
fi
