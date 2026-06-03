#!/usr/bin/env bash
# Дампы PostgreSQL: ИмяБазы-НомерДня-HH.MM.bz2 в PGSQL1C_BACKUP на хосте.
# НомерДня: 1=понедельник … 7=воскресенье (date +%u) — 7-дневный цикл перезаписи.
set -euo pipefail

for f in /etc/default/pgsql1c-stack /etc/default/vvz-1csrv-postgres; do
  if [[ -f "$f" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$f"
    set +a
  fi
done

export PGSQL1C_VAR="${PGSQL1C_VAR:-/var/pgsql1c}"
export PGSQL1C_BACKUP="${PGSQL1C_BACKUP:-${PGSQL1C_VAR}/backups}"

COMPOSE_DIR="${COMPOSE_PROJECT_DIR:-/usr/share/vvz-1csrv-postgres}"
if [[ ! -f "${COMPOSE_DIR}/docker-compose.yml" ]] && [[ -f "$(pwd)/docker-compose.yml" ]]; then
  COMPOSE_DIR=$(pwd)
fi

if ! command -v bzip2 >/dev/null 2>&1; then
  echo "pgsql1c-backup: нужен bzip2 на хосте (apt install bzip2)." >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "pgsql1c-backup: демон Docker не отвечает." >&2
  exit 1
fi

cd "$COMPOSE_DIR"

if [[ -z "$(docker compose ps --status running -q app 2>/dev/null || true)" ]]; then
  echo "pgsql1c-backup: контейнер app не запущен." >&2
  exit 1
fi

if ! docker compose exec -T app runuser -u postgres -- \
  /opt/pgpro/std-16/bin/pg_isready -q 2>/dev/null; then
  echo "pgsql1c-backup: PostgreSQL ещё не принимает подключения." >&2
  exit 1
fi

mkdir -p "$PGSQL1C_BACKUP"

LOCK_FILE="/run/pgsql1c-backup.lock"
if [[ ! -w /run ]] 2>/dev/null; then
  LOCK_FILE="${PGSQL1C_BACKUP}/.pgsql1c-backup.lock"
fi
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "pgsql1c-backup: бекап уже выполняется (lock: ${LOCK_FILE})." >&2
  exit 1
fi

DOW="$(date +%u)"
TIME="$(date +%H.%M)"

mapfile -t DBS < <(
  docker compose exec -T app runuser -u postgres -- \
    /opt/pgpro/std-16/bin/psql -Atq -c \
    "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY 1;"
)

if [[ "${#DBS[@]}" -eq 0 ]]; then
  echo "pgsql1c-backup: нет баз для дампа." >&2
  exit 0
fi

for db in "${DBS[@]}"; do
  [[ -n "$db" ]] || continue
  outfile="${PGSQL1C_BACKUP}/${db}-${DOW}-${TIME}.bz2"
  echo "pgsql1c-backup: ${db} -> ${outfile}"
  tmp="${outfile}.tmp"
  docker compose exec -T app runuser -u postgres -- \
    /opt/pgpro/std-16/bin/pg_dump -d "$db" | bzip2 -c > "$tmp"
  mv "$tmp" "$outfile"
done

echo "pgsql1c-backup: готово ($(date -Is))"
