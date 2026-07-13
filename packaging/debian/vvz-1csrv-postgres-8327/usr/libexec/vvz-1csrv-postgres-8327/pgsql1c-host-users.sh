#!/usr/bin/env bash
# Системные пользователи/группы на хосте с UID/GID, совпадающими с образом контейнера.
# Подключать: source scripts/pgsql1c-host-users.sh (или из postinst / docker-data-init).
set -euo pipefail

: "${PGSQL1C_1C_USER:=pgsql1c-1cv8}"
: "${PGSQL1C_1C_GROUP:=pgsql1c-1cv8}"
: "${PGSQL1C_1C_UID:=60080}"
: "${PGSQL1C_1C_GID:=60080}"
: "${PGSQL1C_PG_USER:=pgsql1c-postgres}"
: "${PGSQL1C_PG_GROUP:=pgsql1c-postgres}"
: "${PGSQL1C_PG_UID:=60081}"
: "${PGSQL1C_PG_GID:=60081}"

pgsql1c_load_host_ids() {
  local f
  for f in /etc/default/pgsql1c-stack-8327 /etc/default/vvz-1csrv-postgres-8327; do
    [[ -f "$f" ]] || continue
    set -a
    # shellcheck source=/dev/null
    source "$f"
    set +a
  done
}

pgsql1c_ensure_system_group() {
  local name="$1" gid="$2"
  if getent group "$name" >/dev/null 2>&1; then
    local existing_gid
    existing_gid="$(getent group "$name" | cut -d: -f3)"
    if [[ "$existing_gid" != "$gid" ]]; then
      echo "pgsql1c-host-users: группа ${name} уже есть с GID ${existing_gid}, нужен ${gid}." >&2
      return 1
    fi
    return 0
  fi
  if getent group "$gid" >/dev/null 2>&1; then
    echo "pgsql1c-host-users: GID ${gid} занят группой «$(getent group "$gid" | cut -d: -f1)», нужна ${name}." >&2
    return 1
  fi
  groupadd --system --gid "$gid" "$name"
}

pgsql1c_ensure_system_user() {
  local name="$1" uid="$2" gid="$3" gname="$4"
  if getent passwd "$name" >/dev/null 2>&1; then
    local existing_uid
    existing_uid="$(getent passwd "$name" | cut -d: -f3)"
    if [[ "$existing_uid" != "$uid" ]]; then
      echo "pgsql1c-host-users: пользователь ${name} уже есть с UID ${existing_uid}, нужен ${uid}." >&2
      return 1
    fi
    return 0
  fi
  if getent passwd "$uid" >/dev/null 2>&1; then
    echo "pgsql1c-host-users: UID ${uid} занят «$(getent passwd "$uid" | cut -d: -f1)», нужен ${name}." >&2
    return 1
  fi
  useradd --system --uid "$uid" --gid "$gname" --no-create-home --home /nonexistent --shell /usr/sbin/nologin "$name"
}

pgsql1c_ensure_host_users() {
  pgsql1c_load_host_ids
  pgsql1c_ensure_system_group "$PGSQL1C_1C_GROUP" "$PGSQL1C_1C_GID"
  pgsql1c_ensure_system_group "$PGSQL1C_PG_GROUP" "$PGSQL1C_PG_GID"
  pgsql1c_ensure_system_user "$PGSQL1C_1C_USER" "$PGSQL1C_1C_UID" "$PGSQL1C_1C_GID" "$PGSQL1C_1C_GROUP"
  pgsql1c_ensure_system_user "$PGSQL1C_PG_USER" "$PGSQL1C_PG_UID" "$PGSQL1C_PG_GID" "$PGSQL1C_PG_GROUP"
}

pgsql1c_chown_host_data() {
  pgsql1c_load_host_ids
  local var="${PGSQL1C_VAR:-/var/pgsql1c-8327}"
  local log="${PGSQL1C_LOG:-/var/log/pgsql1c-8327}"
  local etc="${PGSQL1C_ETC:-/etc/pgsql1c-8327}"
  local backup="${PGSQL1C_BACKUP:-${var}/backups}"

  mkdir -p \
    "$var/postgres" "$var/1cv8" "$var/cache/cfstorage" "$var/cache/app" \
    "$backup" "$log" "$etc/conf.d"

  chown "${PGSQL1C_PG_USER}:${PGSQL1C_PG_GROUP}" "$var/postgres" "$backup"
  chmod 0700 "$var/postgres"
  chmod 0750 "$backup"

  chown -R "${PGSQL1C_1C_USER}:${PGSQL1C_1C_GROUP}" "$var/1cv8" "$var/cache"
  chown -R "${PGSQL1C_PG_USER}:${PGSQL1C_PG_GROUP}" "$log"
  chmod 0750 "$log"

  chown "${PGSQL1C_PG_USER}:${PGSQL1C_PG_GROUP}" "$etc/conf.d"
  chmod 0755 "$etc"
  chmod 0750 "$etc/conf.d"
  find "$etc/conf.d" -type f -exec chown "${PGSQL1C_PG_USER}:${PGSQL1C_PG_GROUP}" {} + 2>/dev/null || true

  if [[ -f "${etc}/srv1cv83" ]]; then
    chown root:root "${etc}/srv1cv83"
    chmod 0644 "${etc}/srv1cv83"
  fi
}

# При обновлении с chown по «голым» 1000/1001 — перенос на именованных пользователей.
pgsql1c_migrate_legacy_ownership() {
  pgsql1c_load_host_ids
  local var="${PGSQL1C_VAR:-/var/pgsql1c-8327}"
  local log="${PGSQL1C_LOG:-/var/log/pgsql1c-8327}"
  local etc="${PGSQL1C_ETC:-/etc/pgsql1c-8327}"
  local backup="${PGSQL1C_BACKUP:-${var}/backups}"
  local path owner

  for path in "$var/postgres" "$backup" "$etc/conf.d"; do
    [[ -e "$path" ]] || continue
    owner="$(stat -c '%u' "$path" 2>/dev/null || echo "")"
    if [[ "$owner" == "1001" ]]; then
      chown -R "${PGSQL1C_PG_USER}:${PGSQL1C_PG_GROUP}" "$path"
    fi
  done

  for path in "$var/1cv8" "$var/cache"; do
    [[ -e "$path" ]] || continue
    owner="$(stat -c '%u' "$path" 2>/dev/null || echo "")"
    if [[ "$owner" == "1000" ]]; then
      chown -R "${PGSQL1C_1C_USER}:${PGSQL1C_1C_GROUP}" "$path"
    fi
  done

  if [[ -d "$log" ]]; then
    owner="$(stat -c '%u' "$log" 2>/dev/null || echo "")"
    if [[ "$owner" == "1000" || "$owner" == "1001" || "$owner" == "$PGSQL1C_1C_UID" ]]; then
      chown -R "${PGSQL1C_PG_USER}:${PGSQL1C_PG_GROUP}" "$log"
    fi
  fi
}
