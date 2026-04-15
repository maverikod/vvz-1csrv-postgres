#!/usr/bin/env bash
# Смена пароля роли postgres внутри контейнера app (локальное подключение peer, пароль не нужен).
# Использование:
#   ./scripts/pgsql1c-set-postgres-password.sh 'новый_пароль'
#   PGSQL1C_POSTGRES_PASSWORD='...' ./scripts/pgsql1c-set-postgres-password.sh
#   ./scripts/pgsql1c-set-postgres-password.sh < secret.txt
# COMPOSE_PROJECT_DIR: сначала явная переменная окружения, иначе /etc/default/pgsql1c-stack,
# иначе текущий каталог при наличии docker-compose.yml, иначе /usr/share/vvz-1csrv-postgres (пакет).
set -euo pipefail

vvz_compose_dir() {
  if [[ -n "${COMPOSE_PROJECT_DIR:-}" ]]; then
    printf '%s' "$COMPOSE_PROJECT_DIR"
    return
  fi
  local f
  for f in /etc/default/pgsql1c-stack /etc/default/vvz-1csrv-postgres; do
    if [[ -f "$f" ]]; then
      set -a
      # shellcheck source=/dev/null
      source "$f"
      set +a
    fi
  done
  if [[ -n "${COMPOSE_PROJECT_DIR:-}" ]]; then
    printf '%s' "$COMPOSE_PROJECT_DIR"
    return
  fi
  if [[ -f "$(pwd)/docker-compose.yml" ]]; then
    pwd
    return
  fi
  printf '%s' '/usr/share/vvz-1csrv-postgres'
}

escape_sq() {
  printf '%s' "$1" | sed "s/'/''/g"
}

if [[ -n "${PGSQL1C_POSTGRES_PASSWORD:-}" ]]; then
  PW="$PGSQL1C_POSTGRES_PASSWORD"
elif [[ -n "${1:-}" ]]; then
  PW="$1"
elif [[ ! -t 0 ]]; then
  read -r PW
else
  read -r -s -p "Новый пароль для пользователя postgres: " PW
  echo
fi

if [[ -z "${PW}" ]]; then
  echo "Пароль пустой." >&2
  exit 1
fi

PWSQL=$(escape_sq "$PW")

cd "$(vvz_compose_dir)"

exec docker compose exec -T app runuser -u postgres -- \
  /opt/pgpro/std-16/bin/psql -v ON_ERROR_STOP=1 -c "ALTER USER postgres WITH PASSWORD '${PWSQL}';"
