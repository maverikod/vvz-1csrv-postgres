#!/usr/bin/env bash
# Подготовка каталогов под bind-mount: права и (опционально) initdb.
set -euo pipefail

PGDATA="${PGDATA:-/var/lib/pgpro/std-16/data}"
INIT_PGDATA="${INIT_PGDATA:-0}"

mkdir -p \
  /var/log/1cv8 \
  /var/cache/1cv8 \
  /var/cfstorage \
  /home/usr1cv8/.1cv8

install -d -m 0755 -o usr1cv8 -g grp1cv8 /var/log/1cv8 /var/cache/1cv8 /var/cfstorage
chown -R usr1cv8:grp1cv8 /home/usr1cv8

mkdir -p "${PGDATA}"

if [[ "$(id -u postgres 2>/dev/null || echo 0)" -gt 0 ]]; then
  chown -R postgres:postgres "${PGDATA}" 2>/dev/null || true
  chmod 0700 "${PGDATA}" 2>/dev/null || true
fi

# conf.d до initdb мешает «пустому» PGDATA. Если conf.d — том с хоста, rm -rf невозможен (EBUSY).
vvz_conf_d_is_mount() {
  [[ -d "${PGDATA}/conf.d" ]] || return 1
  mountpoint -q "${PGDATA}/conf.d" 2>/dev/null
}

if [[ "${INIT_PGDATA}" == "1" ]] && [[ ! -f "${PGDATA}/PG_VERSION" ]] && [[ -d "${PGDATA}/conf.d" ]]; then
  if vvz_conf_d_is_mount; then
    find "${PGDATA}/conf.d" -mindepth 1 -delete 2>/dev/null || true
  else
    rm -rf "${PGDATA}/conf.d"
  fi
fi

# initdb: UTF-8, локаль ru/uk/ru_UA — интерактивный выбор или INITDB_LOCALE
# Имена как в «locale -a» (обычно *.utf8); допускаются варианты с .UTF-8 в INITDB_LOCALE.
vvz_pick_initdb_locale() {
  local loc="${INITDB_LOCALE:-}"
  if [[ -n "$loc" ]]; then
    echo "$loc"
    return
  fi
  if [[ -t 0 ]] && [[ -t 1 ]]; then
    echo "" >&2
    echo "Выберите локаль кластера PostgreSQL (LC_COLLATE / LC_CTYPE, кодировка UTF-8):" >&2
    echo "  1) Русский — ru_RU.utf8" >&2
    echo "  2) Українська — uk_UA.utf8" >&2
    echo "  3) Русский (Украина) — ru_UA.utf8 (по умолчанию)" >&2
    local choice=""
    read -r -p "Номер [1-3, по умолчанию 3]: " choice || true
    case "${choice:-3}" in
      1) echo "ru_RU.utf8" ;;
      2) echo "uk_UA.utf8" ;;
      *) echo "ru_UA.utf8" ;;
    esac
  else
    echo "docker-entrypoint: неинтерактивный режим и INITDB_LOCALE не задан — ru_UA.utf8 (скрипт: scripts/pgsql1c-init-cluster.sh)" >&2
    echo "ru_UA.utf8"
  fi
}

vvz_validate_locale() {
  local want="$1"
  local candidates=("$want")
  case "$want" in
    ru_RU.UTF-8) candidates+=(ru_RU.utf8) ;;
    ru_RU.utf8) candidates+=(ru_RU.UTF-8) ;;
    uk_UA.UTF-8) candidates+=(uk_UA.utf8) ;;
    uk_UA.utf8) candidates+=(uk_UA.UTF-8) ;;
    ru_UA.UTF-8) candidates+=(ru_UA.utf8) ;;
    ru_UA.utf8) candidates+=(ru_UA.UTF-8) ;;
  esac
  local c
  for c in "${candidates[@]}"; do
    if locale -a 2>/dev/null | grep -qxF "$c"; then
      echo "$c"
      return
    fi
  done
  echo "docker-entrypoint: локаль «$want» не найдена (locale -a), используется ru_RU.utf8" >&2
  echo "ru_RU.utf8"
}

# pg-setup / initdb: при смонтированном conf.d PGDATA не «пустой» — initdb во временный каталог, затем перенос
if [[ "${INIT_PGDATA}" == "1" ]] && [[ ! -f "${PGDATA}/PG_VERSION" ]] && [[ -x /opt/pgpro/std-16/bin/initdb ]]; then
  LOCALE="$(vvz_pick_initdb_locale)"
  LOCALE="$(vvz_validate_locale "$LOCALE")"
  echo "docker-entrypoint: initdb — UTF8, locale=${LOCALE} (параметры 1С — см. conf.d)"
  if vvz_conf_d_is_mount; then
    TMP_INIT="$(mktemp -d /tmp/pg-init.XXXXXX)"
    chmod 700 "$TMP_INIT"
    chown postgres:postgres "$TMP_INIT" 2>/dev/null || true
    runuser -u postgres -- /opt/pgpro/std-16/bin/initdb -D "$TMP_INIT" --encoding=UTF8 --locale="$LOCALE"
    shopt -s dotglob nullglob
    for item in "$TMP_INIT"/*; do
      [[ -e "$item" ]] || continue
      base=$(basename "$item")
      [[ "$base" == "conf.d" ]] && continue
      rm -rf "${PGDATA}/${base}" 2>/dev/null || true
      mv "$item" "$PGDATA/"
    done
    shopt -u dotglob nullglob
    rm -rf "$TMP_INIT"
  else
    runuser -u postgres -- /opt/pgpro/std-16/bin/initdb -D "$PGDATA" --encoding=UTF8 --locale="$LOCALE"
  fi
  chown -R postgres:postgres "${PGDATA}"
  chmod 0700 "${PGDATA}" 2>/dev/null || true
fi

mkdir -p "${PGDATA}/conf.d"
if [[ "$(id -u postgres 2>/dev/null || echo 0)" -gt 0 ]]; then
  chown postgres:postgres "${PGDATA}/conf.d" 2>/dev/null || true
fi

# Дефолтные параметры для 1С, если в томе conf.d ещё нет файла
if [[ -f /usr/local/share/vvz-pg-1c/99-1c-enterprise.conf ]] && [[ ! -f "${PGDATA}/conf.d/99-1c-enterprise.conf" ]]; then
  cp /usr/local/share/vvz-pg-1c/99-1c-enterprise.conf "${PGDATA}/conf.d/"
  chown postgres:postgres "${PGDATA}/conf.d/99-1c-enterprise.conf" 2>/dev/null || true
fi
if [[ -f /usr/local/share/vvz-pg-1c/zz-1c-password-md5.conf ]] && [[ ! -f "${PGDATA}/conf.d/zz-1c-password-md5.conf" ]]; then
  cp /usr/local/share/vvz-pg-1c/zz-1c-password-md5.conf "${PGDATA}/conf.d/"
  chown postgres:postgres "${PGDATA}/conf.d/zz-1c-password-md5.conf" 2>/dev/null || true
fi

# include_dir для conf.d (слушать * и порты из conf.d)
if [[ -f "${PGDATA}/postgresql.conf" ]] && ! grep -qE '^[[:space:]]*include_dir[[:space:]]*=' "${PGDATA}/postgresql.conf" 2>/dev/null; then
  printf '\n# docker-entrypoint\ninclude_dir = '\''conf.d'\''\n' >> "${PGDATA}/postgresql.conf"
  chown postgres:postgres "${PGDATA}/postgresql.conf" 2>/dev/null || true
fi

if [[ -x /usr/local/bin/vvz-configure-pg-hba.sh ]]; then
  /usr/local/bin/vvz-configure-pg-hba.sh
fi

exec "$@"
