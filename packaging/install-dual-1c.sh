#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEB="${VVZ_DUAL_DEB:-$ROOT/packaging/vvz-1csrv-postgres-8327_1.0.19_all.deb}"
ROLLBACK_DEB="${VVZ_ROLLBACK_DEB:-$ROOT/packaging/vvz-1csrv-postgres-8327_1.0.18_all.deb}"
OLD_VAR="${VVZ_OLD_VAR:-/var/pgsql1c}"
OLD_ETC="${VVZ_OLD_ETC:-/etc/pgsql1c}"
OLD_LOG="${VVZ_OLD_LOG:-/var/log/pgsql1c}"
BACKUP_ROOT="${VVZ_BACKUP_ROOT:-/var/backups}"
STATE="${VVZ_STATE_DIR:-/var/lib/vvz-1csrv-postgres-8327}"
VERIFY_CMD="${VVZ_VERIFY_CMD:-/usr/libexec/vvz-1csrv-postgres-8327/pgsql1c-verify-storage}"
OLD_CLI="${VVZ_OLD_CLI:-/usr/bin/vvz-1csrv-postgres}"
DUAL_CLI="${VVZ_DUAL_CLI:-/usr/bin/vvz-1csrv-postgres-8327}"
OLD_STACK_DEFAULT="${VVZ_OLD_STACK_DEFAULT:-/etc/default/pgsql1c-stack}"
OLD_COMPOSE="${VVZ_OLD_COMPOSE:-/usr/share/vvz-1csrv-postgres/docker-compose.yml}"
OLD_UNIT="${VVZ_OLD_UNIT:-pgsql1c-stack.service}"
DUAL_UNIT="${VVZ_DUAL_UNIT:-pgsql1c-stack-8327.service}"
OLD_CONTAINER="${VVZ_OLD_CONTAINER:-vvz-1csrv-postgres-app-1}"
TARGET_CONTAINER="${VVZ_TARGET_CONTAINER:-vvz-1csrv-postgres-8327-package-app-1}"
MANUAL_CONTAINER="${VVZ_MANUAL_CONTAINER:-vvz-1csrv-postgres-8327-app-1}"
NETWORK="${VVZ_NETWORK:-vvz-1csrv-postgres_pgsql1c_net}"
NETWORK_IP="${VVZ_NETWORK_IP:-172.31.0.2}"
EXPECTED_NETWORK_DRIVER="${VVZ_NETWORK_DRIVER:-bridge}"
EXPECTED_NETWORK_SUBNET="${VVZ_NETWORK_SUBNET:-172.31.0.0/16}"
EXPECTED_NETWORK_GATEWAY="${VVZ_NETWORK_GATEWAY:-172.31.0.1}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TRANSACTION_ID="${STAMP}-$$"
BACKUP="${VVZ_BACKUP_DIR:-$BACKUP_ROOT/vvz-1csrv-postgres-transition-${STAMP}}"
READY_MARKER="$STATE/transition-ready"
IDENTITY_MARKER="$STATE/transition-ready.identity"
COMPLETE_MARKER="$STATE/transition-complete"
MANUAL_MARKER="$STATE/manual-recovery-required"
PACKAGE_NAME=vvz-1csrv-postgres-8327

if [[ "${VVZ_TRANSITION_TEST_MODE:-0}" != 1 && "$(id -u)" -ne 0 ]]; then
  echo "Run with sudo: sudo ./packaging/install-dual-1c.sh" >&2
  exit 1
fi

unit_enabled_state() { systemctl is-enabled "$1" 2>/dev/null || true; }
unit_active_state() { systemctl is-active "$1" 2>/dev/null || true; }
container_exists() { docker inspect "$1" >/dev/null 2>&1; }
container_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo false)" == true ]]
}
network_exists() { docker network inspect "$NETWORK" >/dev/null 2>&1; }
network_driver() { docker network inspect -f '{{.Driver}}' "$NETWORK" 2>/dev/null; }
network_subnet() { docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "$NETWORK" 2>/dev/null; }
network_gateway() { docker network inspect -f '{{(index .IPAM.Config 0).Gateway}}' "$NETWORK" 2>/dev/null; }
network_label() { docker network inspect -f "{{index .Labels \"$1\"}}" "$NETWORK" 2>/dev/null; }
network_ip_in_use() {
  docker network inspect -f '{{range .Containers}}{{println .IPv4Address}}{{end}}' "$NETWORK" 2>/dev/null \
    | grep -q "^${NETWORK_IP//./\\.}/"
}
package_version() { dpkg-query -W -f='${Version}' "$PACKAGE_NAME" 2>/dev/null || true; }
identity_value() { awk -F= -v key="$1" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$2"; }

cleanup_transaction_markers() {
  rm -f "$READY_MARKER" "$IDENTITY_MARKER"
}

record_manual_recovery() {
  local phase="$1" detail="$2" snapshot="$3"
  mkdir -p "$STATE"
  {
    echo 'schema=vvz-transition-manual-recovery/v1'
    echo "transaction_id=$TRANSACTION_ID"
    echo "phase=$phase"
    echo "snapshot=$snapshot"
    echo "detail=$detail"
  } >"$MANUAL_MARKER"
  echo "FATAL RECOVERY ERROR: $detail" >&2
  echo "Manual recovery evidence: $MANUAL_MARKER" >&2
}

restore_enabled_state() {
  local unit="$1" state="$2"
  case "$state" in
    enabled|enabled-runtime|linked|linked-runtime|alias)
      systemctl unmask "$unit" >/dev/null 2>&1 && systemctl enable "$unit" >/dev/null 2>&1
      ;;
    masked|masked-runtime) systemctl mask "$unit" >/dev/null 2>&1 ;;
    *) systemctl unmask "$unit" >/dev/null 2>&1 && systemctl disable "$unit" >/dev/null 2>&1 ;;
  esac
}

enabled_state_matches() {
  local actual expected
  actual="$(unit_enabled_state "$1")"; expected="$2"
  case "$expected" in
    enabled|enabled-runtime|linked|linked-runtime|alias)
      [[ "$actual" == enabled || "$actual" == enabled-runtime || "$actual" == linked || "$actual" == linked-runtime || "$actual" == alias ]]
      ;;
    masked|masked-runtime) [[ "$actual" == masked || "$actual" == masked-runtime ]] ;;
    *) [[ "$actual" != enabled && "$actual" != enabled-runtime && "$actual" != linked && "$actual" != linked-runtime && "$actual" != alias && "$actual" != masked && "$actual" != masked-runtime ]] ;;
  esac
}

container_state_matches() {
  local container="$1" existed="$2" running="$3"
  if [[ "$existed" == true ]]; then
    container_exists "$container" || return 1
    if [[ "$running" == true ]]; then container_running "$container"; else ! container_running "$container"; fi
  else
    ! container_exists "$container"
  fi
}

network_contract_matches() {
  network_exists || return 1
  [[ "$(network_driver)" == "$NETWORK_DRIVER" ]] || return 1
  [[ "$(network_subnet)" == "$NETWORK_SUBNET" ]] || return 1
  [[ "$(network_gateway)" == "$NETWORK_GATEWAY" ]] || return 1
  [[ "$(network_label com.docker.compose.project)" == "$NETWORK_COMPOSE_PROJECT" ]] || return 1
  [[ "$(network_label com.docker.compose.network)" == "$NETWORK_COMPOSE_NAME" ]] || return 1
  [[ "$(network_label com.docker.compose.config-hash)" == "$NETWORK_COMPOSE_CONFIG_HASH" ]]
}

capture_network_contract() {
  network_exists || { echo "Required old network is missing before transition: $NETWORK" >&2; return 1; }
  NETWORK_DRIVER="$(network_driver)"
  NETWORK_SUBNET="$(network_subnet)"
  NETWORK_GATEWAY="$(network_gateway)"
  NETWORK_COMPOSE_PROJECT="$(network_label com.docker.compose.project)"
  NETWORK_COMPOSE_NAME="$(network_label com.docker.compose.network)"
  NETWORK_COMPOSE_CONFIG_HASH="$(network_label com.docker.compose.config-hash)"
  NETWORK_COMPOSE_VERSION="$(network_label com.docker.compose.version)"
  [[ "$NETWORK_DRIVER" == "$EXPECTED_NETWORK_DRIVER" ]] || { echo "Unexpected network driver: $NETWORK_DRIVER" >&2; return 1; }
  [[ "$NETWORK_SUBNET" == "$EXPECTED_NETWORK_SUBNET" ]] || { echo "Unexpected network subnet: $NETWORK_SUBNET" >&2; return 1; }
  [[ "$NETWORK_GATEWAY" == "$EXPECTED_NETWORK_GATEWAY" ]] || { echo "Unexpected network gateway: $NETWORK_GATEWAY" >&2; return 1; }
  [[ -n "$NETWORK_COMPOSE_PROJECT" && -n "$NETWORK_COMPOSE_NAME" && -n "$NETWORK_COMPOSE_CONFIG_HASH" ]] \
    || { echo "Old network is missing Docker Compose ownership labels" >&2; return 1; }
  NETWORK_INSPECT_JSON="$(docker network inspect "$NETWORK")"
}

ensure_network_contract() {
  if network_exists; then
    network_contract_matches || {
      echo "Refusing conflicting network named $NETWORK: expected $NETWORK_DRIVER $NETWORK_SUBNET gateway $NETWORK_GATEWAY" >&2
      return 1
    }
  else
    docker network create --driver "$NETWORK_DRIVER" --subnet "$NETWORK_SUBNET" --gateway "$NETWORK_GATEWAY" \
      --label "com.docker.compose.project=$NETWORK_COMPOSE_PROJECT" \
      --label "com.docker.compose.network=$NETWORK_COMPOSE_NAME" \
      --label "com.docker.compose.config-hash=$NETWORK_COMPOSE_CONFIG_HASH" \
      --label "com.docker.compose.version=$NETWORK_COMPOSE_VERSION" \
      "$NETWORK" >/dev/null || return 1
    network_contract_matches || return 1
  fi
}

restore_runtime_state() {
  local unit="$1" active="$2" container="$3" existed="$4" running="$5"
  systemctl stop "$unit" >/dev/null 2>&1 || return 1
  systemctl reset-failed "$unit" >/dev/null 2>&1 || return 1
  if [[ "$active" == active ]]; then
    systemctl start "$unit" >/dev/null 2>&1 || return 1
    if [[ "$running" != true ]]; then docker stop "$container" >/dev/null 2>&1 || return 1; fi
  elif [[ "$existed" == true ]]; then
    systemctl start "$unit" >/dev/null 2>&1 || return 1
    docker stop "$container" >/dev/null 2>&1 || return 1
    systemctl stop "$unit" >/dev/null 2>&1 || return 1
    if [[ "$container" == "$OLD_CONTAINER" && -x "$OLD_CLI" ]]; then
      "$OLD_CLI" create --no-build app >/dev/null 2>&1 || return 1
    elif [[ "$container" == "$TARGET_CONTAINER" && -x "$DUAL_CLI" ]]; then
      "$DUAL_CLI" create --no-build app >/dev/null 2>&1 || return 1
    else
      return 1
    fi
  fi
  [[ "$(unit_active_state "$unit")" == "$active" ]] || return 1
  container_state_matches "$container" "$existed" "$running"
}

snapshot_verify() {
  local snapshot="$1" identity
  identity="$snapshot/transition.identity"
  [[ -d "$snapshot" && -f "$snapshot/old-storage.tar" && -f "$snapshot/SHA256SUMS" && -f "$identity" ]] || return 1
  (cd "$snapshot" && sha256sum -c SHA256SUMS >/dev/null) || return 1
  [[ "$(identity_value schema "$identity")" == vvz-transition/v1 ]] || return 1
  [[ "$(identity_value snapshot "$identity")" == "$snapshot" ]] || return 1
  [[ "$(identity_value snapshot_sha256 "$identity")" == "$(sha256sum "$snapshot/old-storage.tar" | awk '{print $1}')" ]] || return 1
  [[ "$(identity_value package_version "$identity")" == 1.0.19 ]] || return 1
  [[ "$(identity_value package_sha256 "$identity")" == "$(sha256sum "$DEB" | awk '{print $1}')" ]] || return 1
}

snapshot_restore() {
  local snapshot="$1"
  snapshot_verify "$snapshot" || return 1
  rm -rf "$OLD_VAR" "$OLD_ETC" "$OLD_LOG" || return 1
  tar --acls --xattrs --numeric-owner -xpf "$snapshot/old-storage.tar" -C / || return 1
  tar --acls --xattrs --numeric-owner --compare -f "$snapshot/old-storage.tar" -C / >/dev/null || return 1
}

capture_original_state() {
  OLD_ENABLED="$(unit_enabled_state "$OLD_UNIT")"
  OLD_ACTIVE="$(unit_active_state "$OLD_UNIT")"
  DUAL_ENABLED="$(unit_enabled_state "$DUAL_UNIT")"
  DUAL_ACTIVE="$(unit_active_state "$DUAL_UNIT")"
  OLD_EXISTS=false; OLD_RUNNING=false; TARGET_EXISTS=false; TARGET_RUNNING=false
  container_exists "$OLD_CONTAINER" && OLD_EXISTS=true
  container_running "$OLD_CONTAINER" && OLD_RUNNING=true
  container_exists "$TARGET_CONTAINER" && TARGET_EXISTS=true
  container_running "$TARGET_CONTAINER" && TARGET_RUNNING=true
  ORIGINAL_PACKAGE_VERSION="$(package_version)"
}

original_state_matches() {
  [[ "$(unit_active_state "$OLD_UNIT")" == "$OLD_ACTIVE" ]] || return 1
  [[ "$(unit_active_state "$DUAL_UNIT")" == "$DUAL_ACTIVE" ]] || return 1
  enabled_state_matches "$OLD_UNIT" "$OLD_ENABLED" || return 1
  enabled_state_matches "$DUAL_UNIT" "$DUAL_ENABLED" || return 1
  container_state_matches "$OLD_CONTAINER" "$OLD_EXISTS" "$OLD_RUNNING" || return 1
  container_state_matches "$TARGET_CONTAINER" "$TARGET_EXISTS" "$TARGET_RUNNING" || return 1
  network_contract_matches || return 1
  [[ "$(package_version)" == "$ORIGINAL_PACKAGE_VERSION" ]]
}

restore_captured_state() {
  local errors=()
  ensure_network_contract || errors+=(old-network)
  restore_runtime_state "$DUAL_UNIT" "$DUAL_ACTIVE" "$TARGET_CONTAINER" "$TARGET_EXISTS" "$TARGET_RUNNING" || errors+=(dual-runtime)
  restore_runtime_state "$OLD_UNIT" "$OLD_ACTIVE" "$OLD_CONTAINER" "$OLD_EXISTS" "$OLD_RUNNING" || errors+=(old-runtime)
  ensure_network_contract || errors+=(old-network-final)
  restore_enabled_state "$DUAL_UNIT" "$DUAL_ENABLED" || errors+=(dual-enablement)
  restore_enabled_state "$OLD_UNIT" "$OLD_ENABLED" || errors+=(old-enablement)
  original_state_matches || errors+=(state-verification)
  ((${#errors[@]} == 0)) || { printf '%s' "${errors[*]}"; return 1; }
}

create_transition_snapshot() {
  mkdir -p "$BACKUP" "$STATE"
  tar --acls --xattrs --numeric-owner -cpf "$BACKUP/old-storage.tar" "$OLD_VAR" "$OLD_ETC" "$OLD_LOG"
  tar -tf "$BACKUP/old-storage.tar" >/dev/null
  printf '%s\n' "$OLD_INSPECT_JSON" >"$BACKUP/old-container-inspect.json"
  printf '%s\n' "$NETWORK_INSPECT_JSON" >"$BACKUP/old-network-inspect.json"
  sha256sum "$BACKUP/old-storage.tar" >"$BACKUP/SHA256SUMS"
  (cd "$BACKUP" && sha256sum -c SHA256SUMS >/dev/null)
  {
    echo 'schema=vvz-transition/v1'
    echo "transaction_id=$TRANSACTION_ID"
    echo "snapshot=$BACKUP"
    echo "snapshot_sha256=$(sha256sum "$BACKUP/old-storage.tar" | awk '{print $1}')"
    echo "package=$PACKAGE_NAME"
    echo 'package_version=1.0.19'
    echo "package_sha256=$(sha256sum "$DEB" | awk '{print $1}')"
    echo "rollback_version=$(dpkg-deb -f "$ROLLBACK_DEB" Version)"
    echo "rollback_sha256=$(sha256sum "$ROLLBACK_DEB" | awk '{print $1}')"
  } >"$BACKUP/transition.identity"
  snapshot_verify "$BACKUP"
}

write_ready_marker() {
  printf '%s\n' "$BACKUP" >"$READY_MARKER.tmp"
  cp "$BACKUP/transition.identity" "$IDENTITY_MARKER.tmp"
  mv "$READY_MARKER.tmp" "$READY_MARKER"
  mv "$IDENTITY_MARKER.tmp" "$IDENTITY_MARKER"
  if [[ "${VVZ_TRANSITION_TEST_MODE:-0}" == 1 ]]; then
    case "${VVZ_TEST_MARKER_FAULT:-}" in
      missing) rm -f "$IDENTITY_MARKER" ;;
      corrupt) printf 'schema=corrupt\n' >"$IDENTITY_MARKER" ;;
    esac
  fi
  [[ "$(cat "$READY_MARKER")" == "$BACKUP" ]] || return 1
  cmp -s "$IDENTITY_MARKER" "$BACKUP/transition.identity"
}

create_rescue_snapshot() {
  local rescue="$1"
  mkdir -p "$rescue"
  tar --acls --xattrs --numeric-owner -cpf "$rescue/pre-rollback-storage.tar" "$OLD_VAR" "$OLD_ETC" "$OLD_LOG"
  tar -tf "$rescue/pre-rollback-storage.tar" >/dev/null
  sha256sum "$rescue/pre-rollback-storage.tar" >"$rescue/SHA256SUMS"
  (cd "$rescue" && sha256sum -c SHA256SUMS >/dev/null)
}

restore_rescue_snapshot() {
  local rescue="$1"
  (cd "$rescue" && sha256sum -c SHA256SUMS >/dev/null) || return 1
  rm -rf "$OLD_VAR" "$OLD_ETC" "$OLD_LOG" || return 1
  tar --acls --xattrs --numeric-owner -xpf "$rescue/pre-rollback-storage.tar" -C / || return 1
  tar --acls --xattrs --numeric-owner --compare -f "$rescue/pre-rollback-storage.tar" -C / >/dev/null || return 1
}

preflight_tools() {
  local command
  for command in systemctl docker dpkg dpkg-deb dpkg-query tar sha256sum du df awk grep cmp cp mv rm python3; do
    command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; return 1; }
  done
}

load_snapshot_network_contract() {
  local snapshot="$1" values
  values="$(python3 - "$snapshot/old-network-inspect.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as stream:
    network = json.load(stream)[0]
config = network.get('IPAM', {}).get('Config', [])
if len(config) != 1:
    raise SystemExit(1)
item = config[0]
print(network.get('Name', ''))
print(network.get('Driver', ''))
print(item.get('Subnet', ''))
print(item.get('Gateway', ''))
labels = network.get('Labels') or {}
print(labels.get('com.docker.compose.project', ''))
print(labels.get('com.docker.compose.network', ''))
print(labels.get('com.docker.compose.config-hash', ''))
print(labels.get('com.docker.compose.version', ''))
PY
)" || return 1
  mapfile -t fields <<<"$values"
  [[ "${fields[0]:-}" == "$NETWORK" ]] || return 1
  NETWORK_DRIVER="${fields[1]:-}"
  NETWORK_SUBNET="${fields[2]:-}"
  NETWORK_GATEWAY="${fields[3]:-}"
  NETWORK_COMPOSE_PROJECT="${fields[4]:-}"
  NETWORK_COMPOSE_NAME="${fields[5]:-}"
  NETWORK_COMPOSE_CONFIG_HASH="${fields[6]:-}"
  NETWORK_COMPOSE_VERSION="${fields[7]:-}"
  [[ "$NETWORK_DRIVER" == "$EXPECTED_NETWORK_DRIVER" ]] || return 1
  [[ "$NETWORK_SUBNET" == "$EXPECTED_NETWORK_SUBNET" ]] || return 1
  [[ "$NETWORK_GATEWAY" == "$EXPECTED_NETWORK_GATEWAY" ]] || return 1
  [[ -n "$NETWORK_COMPOSE_PROJECT" && -n "$NETWORK_COMPOSE_NAME" && -n "$NETWORK_COMPOSE_CONFIG_HASH" ]]
}

validate_manual_recovery() {
  local snapshot="$1" identity
  identity="$snapshot/transition.identity"
  [[ -f "$MANUAL_MARKER" ]] || { echo "Manual recovery marker is missing" >&2; return 1; }
  [[ "$(identity_value schema "$MANUAL_MARKER")" == vvz-transition-manual-recovery/v1 ]] || return 1
  [[ "$(identity_value phase "$MANUAL_MARKER")" == automatic-install ]] || return 1
  [[ "$(identity_value snapshot "$MANUAL_MARKER")" == "$snapshot" ]] || return 1
  [[ "$(identity_value transaction_id "$MANUAL_MARKER")" == "$(identity_value transaction_id "$identity")" ]] || return 1
  identity_value detail "$MANUAL_MARKER" | grep -Eq 'old-runtime|state-verification' || return 1
}

no_old_storage_writer() {
  local container source
  while IFS= read -r container; do
    [[ -n "$container" ]] || continue
    while IFS= read -r source; do
      case "$source" in
        "$OLD_VAR"|"$OLD_VAR"/*|"$OLD_ETC"|"$OLD_ETC"/*|"$OLD_LOG"|"$OLD_LOG"/*) return 1 ;;
      esac
    done < <(docker inspect -f '{{range .Mounts}}{{println .Source}}{{end}}' "$container")
  done < <(docker ps -q)
}

recover_stopped_old_runtime() {
  ensure_network_contract
  if ! container_exists "$OLD_CONTAINER"; then "$OLD_CLI" create --no-build app >/dev/null; fi
  container_exists "$OLD_CONTAINER" || return 1
  ! container_running "$OLD_CONTAINER" || return 1
  # Docker does not expose stopped endpoints in .Containers. The static IP is
  # retained in container metadata but remains free for the active dual stack.
  ! network_ip_in_use
}

old_compose_contract_matches() {
  [[ -x "$OLD_CLI" ]] || return 1
  grep -qx 'PGSQL1C_VAR=/var/pgsql1c' "$OLD_STACK_DEFAULT" || return 1
  grep -qx 'PGSQL1C_LOG=/var/log/pgsql1c' "$OLD_STACK_DEFAULT" || return 1
  grep -qx 'PGSQL1C_ETC=/etc/pgsql1c' "$OLD_STACK_DEFAULT" || return 1
  grep -qx 'PGSQL1C_DOCKER_SUBNET=172.31.0.0/16' "$OLD_STACK_DEFAULT" || return 1
  grep -qx 'PGSQL1C_CONTAINER_IP=172.31.0.2' "$OLD_STACK_DEFAULT" || return 1
  grep -q '1540:1540' "$OLD_COMPOSE" || return 1
  grep -q '1560-1591:1560-1591' "$OLD_COMPOSE"
}

old_container_contract_matches() {
  local sources
  container_exists "$OLD_CONTAINER" || return 1
  ! container_running "$OLD_CONTAINER" || return 1
  sources="$(docker inspect -f '{{range .Mounts}}{{println .Source}}{{end}}' "$OLD_CONTAINER")"
  grep -qx "$OLD_VAR/postgres" <<<"$sources" || return 1
  grep -qx "$OLD_VAR/1cv8" <<<"$sources" || return 1
  grep -qx "$OLD_ETC/conf.d" <<<"$sources" || return 1
  grep -qx "$OLD_LOG" <<<"$sources"
}

preflight_storage() {
  [[ -f "$OLD_VAR/postgres/PG_VERSION" ]] || { echo "Old PGDATA is missing" >&2; return 1; }
  [[ -d "$OLD_VAR/1cv8" ]] || { echo "Old 1C data is missing" >&2; return 1; }
  [[ -d "$OLD_ETC" ]] || { echo "Old config is missing" >&2; return 1; }
  [[ -d "$OLD_LOG" ]] || { echo "Old log directory is missing" >&2; return 1; }
  [[ -d "$BACKUP_ROOT" && -w "$BACKUP_ROOT" ]] || { echo "Backup root is not writable: $BACKUP_ROOT" >&2; return 1; }
  [[ -d "$(dirname "$STATE")" && -w "$(dirname "$STATE")" ]] || { echo "State parent is not writable" >&2; return 1; }
}

check_capacity() {
  local needed_kb free_kb
  needed_kb="$(du -sk "$OLD_VAR" "$OLD_ETC" "$OLD_LOG" | awk '{s += $1} END {print s}')"
  free_kb="$(df -Pk "$BACKUP_ROOT" | awk 'NR==2 {print $4}')"
  (( free_kb > needed_kb + needed_kb / 5 )) || {
    echo "Insufficient backup space: need at least $((needed_kb + needed_kb / 5)) KiB, have ${free_kb} KiB" >&2
    return 1
  }
}

if [[ "${1:-}" == --recover-runtime ]]; then
  SNAPSHOT="${2:-}"
  preflight_tools
  preflight_storage
  snapshot_verify "$SNAPSHOT" || { echo "Recovery snapshot identity or checksum is invalid" >&2; exit 1; }
  validate_manual_recovery "$SNAPSHOT" || { echo "Manual recovery marker does not match the snapshot transaction" >&2; exit 1; }
  load_snapshot_network_contract "$SNAPSHOT" || { echo "Saved network contract is invalid" >&2; exit 1; }
  [[ "$(package_version)" == 1.0.18 ]] || { echo "Recovery requires installed package baseline 1.0.18" >&2; exit 1; }
  [[ ! -e "$READY_MARKER" && ! -e "$IDENTITY_MARKER" ]] || { echo "A live transition authorization marker exists" >&2; exit 1; }
  no_old_storage_writer || { echo "A running container writes old storage; refusing recovery" >&2; exit 1; }
  tar --acls --xattrs --numeric-owner --compare -f "$SNAPSHOT/old-storage.tar" -C / >/dev/null \
    || { echo "Restored old storage differs from the verified snapshot" >&2; exit 1; }
  old_compose_contract_matches || { echo "Installed old compose metadata does not match the snapshot contract" >&2; exit 1; }
  recover_stopped_old_runtime || { echo "Could not recreate the old stopped Docker runtime" >&2; exit 1; }
  old_container_contract_matches || { echo "Recreated old container contract verification failed" >&2; exit 1; }
  network_contract_matches || { echo "Recreated old network contract verification failed" >&2; exit 1; }
  ! network_ip_in_use || { echo "Stopped rollback artifact unexpectedly reserves $NETWORK_IP" >&2; exit 1; }
  rm -f "$MANUAL_MARKER"
  echo "Manual runtime recovery complete; old container is preserved and stopped"
  exit 0
fi

if [[ "${1:-}" == --rollback ]]; then
  SNAPSHOT="${2:-}"
  preflight_tools
  cleanup_transaction_markers
  preflight_storage
  snapshot_verify "$SNAPSHOT" || { echo "Rollback snapshot identity or checksum is invalid" >&2; exit 1; }
  load_snapshot_network_contract "$SNAPSHOT" || { echo "Saved network contract is invalid" >&2; exit 1; }
  check_capacity
  capture_original_state
  RESCUE="$BACKUP_ROOT/vvz-1csrv-postgres-rollback-rescue-${STAMP}"
  [[ ! -e "$RESCUE" ]] || { echo "Rollback rescue destination already exists: $RESCUE" >&2; exit 1; }
  create_rescue_snapshot "$RESCUE"

  ROLLBACK_MUTATION_STARTED=0
  ROLLBACK_DATA_MUTATED=0
  ROLLBACK_COMMITTED=0
  rollback_rescue() {
    local rc="$1" details=()
    trap - EXIT INT TERM
    set +e
    cleanup_transaction_markers || details+=(marker-cleanup)
    if (( ROLLBACK_DATA_MUTATED == 1 )); then
      restore_rescue_snapshot "$RESCUE" || details+=(rescue-data-restore)
    fi
    if (( ROLLBACK_MUTATION_STARTED == 1 )); then
      restored="$(restore_captured_state)" || details+=("runtime:${restored:-unknown}")
    fi
    [[ "$(package_version)" == "$ORIGINAL_PACKAGE_VERSION" ]] || details+=(package-version)
    if ((${#details[@]})); then
      record_manual_recovery explicit-rollback "${details[*]}" "$RESCUE"
      exit 125
    fi
    exit "$rc"
  }
  on_rollback_exit() {
    local rc=$?
    if (( ROLLBACK_COMMITTED == 0 )); then rollback_rescue "$rc"; fi
    return "$rc"
  }
  trap on_rollback_exit EXIT
  trap 'exit 130' INT TERM

  ROLLBACK_MUTATION_STARTED=1
  systemctl stop "$DUAL_UNIT"
  systemctl disable "$DUAL_UNIT"
  systemctl stop "$OLD_UNIT"
  systemctl reset-failed "$OLD_UNIT"
  ROLLBACK_DATA_MUTATED=1
  snapshot_restore "$SNAPSHOT"
  ensure_network_contract
  systemctl enable "$OLD_UNIT"
  systemctl reset-failed "$OLD_UNIT"
  systemctl start "$OLD_UNIT"
  container_running "$OLD_CONTAINER" || { echo "Rollback failed to start $OLD_CONTAINER" >&2; exit 1; }
  tar --acls --xattrs --numeric-owner --compare -f "$SNAPSHOT/old-storage.tar" -C / >/dev/null
  [[ "$(package_version)" == "$ORIGINAL_PACKAGE_VERSION" ]] || { echo "Rollback changed package version" >&2; exit 1; }
  network_contract_matches || { echo "Rollback changed network contract" >&2; exit 1; }
  cleanup_transaction_markers
  rm -f "$COMPLETE_MARKER"
  rm -f "$MANUAL_MARKER"
  ROLLBACK_COMMITTED=1
  trap - EXIT INT TERM
  rm -rf "$RESCUE"
  echo "Rollback complete"
  exit 0
fi

# Stale authorization markers are invalidated first; all remaining refusal
# checks are read-only and precede every service, container and data mutation.
preflight_tools
cleanup_transaction_markers
[[ ! -e "$MANUAL_MARKER" ]] || { echo "Manual recovery is still required: $MANUAL_MARKER" >&2; exit 1; }
[[ -f "$DEB" ]] || { echo "Missing package: $DEB" >&2; exit 1; }
[[ "$(dpkg-deb -f "$DEB" Package)" == "$PACKAGE_NAME" ]] || { echo "Wrong package artifact" >&2; exit 1; }
[[ "$(dpkg-deb -f "$DEB" Version)" == 1.0.19 ]] || { echo "Wrong package version" >&2; exit 1; }
[[ -f "$ROLLBACK_DEB" && "$(dpkg-deb -f "$ROLLBACK_DEB" Version)" == 1.0.18 ]] || { echo "Wrong rollback package artifact" >&2; exit 1; }
preflight_storage
[[ ! -e "$BACKUP" ]] || { echo "Snapshot destination already exists: $BACKUP" >&2; exit 1; }
container_exists "$OLD_CONTAINER" || { echo "Preserved old container is missing" >&2; exit 1; }
container_running "$OLD_CONTAINER" && { echo "Preserved old container must be stopped" >&2; exit 1; }
container_running "$MANUAL_CONTAINER" && { echo "Manual 8.3.27 container must be stopped" >&2; exit 1; }
docker network inspect "$NETWORK" >/dev/null
capture_network_contract
if network_ip_in_use; then
  echo "IP $NETWORK_IP is attached to an active endpoint" >&2
  exit 1
fi
check_capacity
capture_original_state
[[ "$ORIGINAL_PACKAGE_VERSION" == 1.0.18 ]] || { echo "Installed rollback baseline is not 1.0.18" >&2; exit 1; }
OLD_INSPECT_JSON="$(docker inspect "$OLD_CONTAINER")"

cleanup_transaction_markers
MUTATION_STARTED=0
SNAPSHOT_COMPLETE=0
PACKAGE_MUTATION_STARTED=0
COMMITTED=0

restore_install_failure() {
  local rc="$1" details=()
  trap - EXIT INT TERM
  set +e
  cleanup_transaction_markers || details+=(marker-cleanup)
  systemctl stop "$DUAL_UNIT" >/dev/null 2>&1 || details+=(dual-stop)
  if (( PACKAGE_MUTATION_STARTED == 1 )); then
    if (( SNAPSHOT_COMPLETE == 1 )); then snapshot_restore "$BACKUP" || details+=(snapshot-data-restore); else details+=(snapshot-not-complete); fi
    dpkg -i "$ROLLBACK_DEB" >/dev/null 2>&1 || details+=(rollback-package-install)
    [[ "$(package_version)" == "$ORIGINAL_PACKAGE_VERSION" ]] || details+=(rollback-package-version)
  fi
  if (( MUTATION_STARTED == 1 )); then
    restored="$(restore_captured_state)" || details+=("runtime:${restored:-unknown}")
  fi
  if ((${#details[@]})); then
    record_manual_recovery automatic-install "${details[*]}" "$BACKUP"
    exit 125
  fi
  rm -f "$MANUAL_MARKER"
  exit "$rc"
}
on_install_exit() {
  local rc=$?
  if (( COMMITTED == 0 )); then restore_install_failure "$rc"; fi
  return "$rc"
}
trap on_install_exit EXIT
trap 'exit 130' INT TERM

MUTATION_STARTED=1
systemctl stop "$DUAL_UNIT"
systemctl stop "$OLD_UNIT"
[[ "$(unit_active_state "$OLD_UNIT")" != active ]] || { echo "Old unit remained active" >&2; exit 1; }
container_running "$OLD_CONTAINER" && { echo "Old container remained running" >&2; exit 1; }
systemctl disable "$OLD_UNIT"
enabled_state_matches "$OLD_UNIT" disabled || { echo "Old unit remained enabled" >&2; exit 1; }
ensure_network_contract

create_transition_snapshot
SNAPSHOT_COMPLETE=1
write_ready_marker
PACKAGE_MUTATION_STARTED=1
dpkg -i "$DEB"
systemctl is-active --quiet "$DUAL_UNIT"
"$VERIFY_CMD"

restore_enabled_state "$OLD_UNIT" disabled
if [[ "$OLD_EXISTS" == true ]] && ! container_exists "$OLD_CONTAINER"; then "$OLD_CLI" create --no-build app >/dev/null; fi
container_exists "$OLD_CONTAINER" || { echo "Preserved old stopped container was not recreated" >&2; exit 1; }
container_running "$OLD_CONTAINER" && { echo "Preserved old container unexpectedly running" >&2; exit 1; }
network_ip_in_use && { echo "Preserved stopped container unexpectedly reserves $NETWORK_IP" >&2; exit 1; }
[[ "$(package_version)" == 1.0.19 ]] || { echo "Installed package version is not 1.0.19" >&2; exit 1; }
snapshot_verify "$BACKUP" || { echo "Transition snapshot verification failed after install" >&2; exit 1; }
cleanup_transaction_markers
{
  echo 'schema=vvz-transition-complete/v1'
  echo "transaction_id=$TRANSACTION_ID"
  echo "snapshot=$BACKUP"
  echo 'package_version=1.0.19'
} >"$COMPLETE_MARKER"
rm -f "$MANUAL_MARKER"
COMMITTED=1
trap - EXIT INT TERM
echo "Dual stack installed. Cold rollback snapshot: $BACKUP"
