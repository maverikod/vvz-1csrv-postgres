#!/usr/bin/env bash
# Первичная инициализация кластера PostgreSQL (initdb, UTF-8).
# По умолчанию локаль: русский для Украины — ru_UA.utf8.
#
# Использование:
#   ./scripts/pgsql1c-init-cluster.sh              # неинтерактивно, ru_UA.utf8
#   ./scripts/pgsql1c-init-cluster.sh -i           # выбор локали в контейнере (меню)
#   INITDB_LOCALE=uk_UA.utf8 ./scripts/pgsql1c-init-cluster.sh
#
# Перед вызовом: каталоги данных (sudo ./scripts/docker-data-init.sh), образ собран.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

INTERACTIVE=0
for a in "$@"; do
  case "$a" in
    -i|--interactive) INTERACTIVE=1 ;;
    -h|--help)
      head -14 "$0" | tail -n +2
      exit 0
      ;;
  esac
done

export INIT_PGDATA=1

if [[ "$INTERACTIVE" -eq 1 ]]; then
  unset INITDB_LOCALE 2>/dev/null || true
  exec docker compose run --rm -it -e INIT_PGDATA=1 app true
fi

export INITDB_LOCALE="${INITDB_LOCALE:-ru_UA.utf8}"
exec docker compose run --rm -e INIT_PGDATA=1 -e "INITDB_LOCALE=${INITDB_LOCALE}" app true
