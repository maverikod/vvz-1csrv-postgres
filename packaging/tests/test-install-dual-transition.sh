#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/packaging/install-dual-1c.sh"
DEB="$ROOT/packaging/vvz-1csrv-postgres-8327_1.0.19_all.deb"
ROLLBACK_DEB="$ROOT/packaging/vvz-1csrv-postgres-8327_1.0.18_all.deb"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"; }
assert_file() { [[ -f "$1" ]] || fail "missing file: $1"; }

make_fake_commands() {
  local bin="$1"
  mkdir -p "$bin"
  cat >"$bin/fake-command" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
cmd="$(basename "$0")"
s="${SIM_STATE:?}"
get() { cat "$s/$1"; }
put() { printf '%s\n' "$2" >"$s/$1"; }
event() { printf '%s\n' "$*" >>"$s/events"; }
unit_prefix() {
  case "$1" in
    "$OLD_UNIT") echo old ;;
    "$DUAL_UNIT") echo dual ;;
    *) exit 2 ;;
  esac
}
container_prefix() {
  case "$1" in
    "$OLD_CONTAINER") echo old ;;
    "$TARGET_CONTAINER") echo target ;;
    "$DUAL_ACTIVE_CONTAINER") echo dualactive ;;
    "$MANUAL_CONTAINER") echo manual ;;
    *) exit 2 ;;
  esac
}

case "$cmd" in
  systemctl)
    op="${1:-}"; shift || true
    if [[ "$op" == is-active && "${1:-}" == --quiet ]]; then
      shift; p="$(unit_prefix "$1")"; [[ "$(get "${p}_active")" == active ]]; exit
    fi
    p="$(unit_prefix "${1:-}")"
    case "$op" in
      is-enabled) get "${p}_enabled"; [[ "$(get "${p}_enabled")" == enabled ]] ;;
      is-active) get "${p}_active"; [[ "$(get "${p}_active")" == active ]] ;;
      stop)
        event "systemctl stop $1"; put "${p}_active" inactive
        if [[ "$p" == old ]]; then
          put old_exists false; put old_running false
          if [[ "$(get conflict_after_old_stop)" == true ]]; then
            put network_exists true; put network_subnet 10.99.0.0/16
          else
            put network_exists false
          fi
        else
          put target_exists false; put target_running false
          put dualactive_exists false; put dualactive_running false
          put network_owner_mode none
        fi ;;
      start)
        event "systemctl start $1"; put "${p}_active" active
        if [[ "$(get systemctl_restore_fail)" == true ]]; then exit 46; fi
        if [[ "$p" == dual && "$(get docker_restore_fail)" == true ]]; then
          put target_exists true; put target_running false; exit 0
        fi
        if [[ "$p" == old ]]; then put old_exists true; put old_running true
        else put target_exists true; put target_running true; fi ;;
      enable) event "systemctl enable $1"; put "${p}_enabled" enabled ;;
      disable) event "systemctl disable $1"; put "${p}_enabled" disabled ;;
      mask) event "systemctl mask $1"; put "${p}_enabled" masked ;;
      unmask) event "systemctl unmask $1"; [[ "$(get "${p}_enabled")" == masked ]] && put "${p}_enabled" disabled || true ;;
      reset-failed) event "systemctl reset-failed $1" ;;
      *) exit 2 ;;
    esac
    ;;
  docker)
    op="${1:-}"; shift || true
    if [[ "$op" == network ]]; then
      network_op="${1:-}"; shift
      if [[ "$network_op" == inspect && "${1:-}" == -f ]]; then
        template="$2"
        [[ "$(get network_exists)" == true ]] || exit 1
        case "$template" in
          *'.Driver'*) get network_driver ;;
          *'.Subnet'*) get network_subnet ;;
          *'.Gateway'*) get network_gateway ;;
          *'compose.project'*) get network_compose_project ;;
          *'compose.network'*) get network_compose_name ;;
          *'compose.config-hash'*) get network_compose_hash ;;
          *'compose.version'*) get network_compose_version ;;
          *'.Containers'*) [[ "$(get network_conflict)" == true ]] && echo "${NETWORK_IP}/24" || true ;;
          *) exit 2 ;;
        esac
      elif [[ "$network_op" == inspect ]]; then
        [[ "$(get network_exists)" == true ]] || exit 1
        owner_mode="$(get network_owner_mode)"
        [[ "$(get network_conflict)" != true ]] || owner_mode=wrong
        case "$owner_mode" in
          none) containers='{}' ;;
          dual) containers="{\"dual-id\":{\"Name\":\"$DUAL_ACTIVE_CONTAINER\",\"EndpointID\":\"dual-endpoint\",\"IPv4Address\":\"$NETWORK_IP/16\"}}" ;;
          wrong) containers="{\"wrong-id\":{\"Name\":\"wrong-container\",\"EndpointID\":\"wrong-endpoint\",\"IPv4Address\":\"$NETWORK_IP/16\"}}" ;;
          old) containers="{\"old-id\":{\"Name\":\"$OLD_CONTAINER\",\"EndpointID\":\"old-endpoint\",\"IPv4Address\":\"$NETWORK_IP/16\"}}" ;;
          duplicate) containers="{\"dual-id\":{\"Name\":\"$DUAL_ACTIVE_CONTAINER\",\"EndpointID\":\"dual-endpoint\",\"IPv4Address\":\"$NETWORK_IP/16\"},\"other-id\":{\"Name\":\"wrong-container\",\"EndpointID\":\"other-endpoint\",\"IPv4Address\":\"$NETWORK_IP/16\"}}" ;;
          *) exit 2 ;;
        esac
        printf '[{"Name":"%s","Driver":"%s","IPAM":{"Config":[{"Subnet":"%s","Gateway":"%s"}]},"Labels":{"com.docker.compose.project":"%s","com.docker.compose.network":"%s","com.docker.compose.config-hash":"%s","com.docker.compose.version":"%s"},"Containers":%s}]\n' \
          "$NETWORK" "$(get network_driver)" "$(get network_subnet)" "$(get network_gateway)" \
          "$(get network_compose_project)" "$(get network_compose_name)" "$(get network_compose_hash)" "$(get network_compose_version)" "$containers"
      elif [[ "$network_op" == create ]]; then
        event "docker network create $*"
        while (($#)); do
          case "$1" in
            --driver) put network_driver "$2"; shift 2 ;;
            --subnet) put network_subnet "$2"; shift 2 ;;
            --gateway) put network_gateway "$2"; shift 2 ;;
            --label)
              case "$2" in
                com.docker.compose.project=*) put network_compose_project "${2#*=}" ;;
                com.docker.compose.network=*) put network_compose_name "${2#*=}" ;;
                com.docker.compose.config-hash=*) put network_compose_hash "${2#*=}" ;;
                com.docker.compose.version=*) put network_compose_version "${2#*=}" ;;
              esac
              shift 2 ;;
            *) shift ;;
          esac
        done
        put network_exists true
        echo test-network-id
      else
        exit 2
      fi
    elif [[ "$op" == inspect ]]; then
      if [[ "${1:-}" == -f ]]; then
        template="$2"; shift 2; name="$1"; p="$(container_prefix "$name")"
        [[ "$(get "${p}_exists")" == true ]] || exit 1
        if [[ "$template" == *'.Mounts'* ]]; then
          if [[ "$p" == old ]]; then
            printf '%s\n' "$OLD_VAR/postgres" "$OLD_VAR/1cv8" "$OLD_ETC/conf.d" "$OLD_LOG"
          elif [[ "$p" == target ]]; then
            printf '%s\n' "$OLD_VAR-isolated/postgres" "$OLD_VAR-isolated/1cv8"
          fi
        else
          get "${p}_running"
        fi
      else
        name="$1"; p="$(container_prefix "$name")"
        [[ "$(get "${p}_exists")" == true ]] || exit 1
        printf '[{"Name":"%s","State":{"Running":%s}}]\n' "$name" "$(get "${p}_running")"
      fi
    elif [[ "$op" == stop ]]; then
      name="$1"; p="$(container_prefix "$name")"; event "docker stop $name"
      if [[ "$p" == old && "$(get docker_restore_fail)" == true ]]; then exit 49; fi
      put "${p}_running" false
    elif [[ "$op" == ps ]]; then
      [[ "$(get target_running)" == true ]] && echo "$TARGET_CONTAINER"
      [[ "$(get old_running)" == true ]] && echo "$OLD_CONTAINER"
    else
      exit 2
    fi
    ;;
  dpkg)
    [[ "${1:-}" == -i ]] || exit 2
    event "dpkg -i $(basename "$2")"
    if [[ "$2" == "$DEB" ]]; then
      [[ "$(get dpkg_fail)" != true ]] || exit 42
      put package_version 1.0.19
      put target_exists true; put target_running true; put dual_active active
      put dualactive_exists true; put dualactive_running "$(get postinstall_dual_running)"
      put network_owner_mode "$(get postinstall_owner)"
      printf 'changed-by-new-package\n' >"$OLD_VAR/data-marker"
      [[ "$(get postinst_fail)" != true ]] || exit 43
    else
      [[ "$(get rollback_dpkg_fail)" != true ]] || exit 45
      put package_version 1.0.18
      put target_exists true; put target_running true; put dual_active active
      put dualactive_exists false; put dualactive_running false; put network_owner_mode none
    fi
    ;;
  dpkg-query)
    get package_version
    ;;
  tar)
    if [[ " $* " == *" -cpf "* && "$*" == *pre-rollback-storage.tar* && "$(get rescue_tar_fail)" == true ]]; then exit 43; fi
    if [[ " $* " == *" -cpf "* && "$*" == *old-storage.tar* && "$(get tar_fail)" == true ]]; then exit 43; fi
    if [[ " $* " == *" -xpf "* && "$*" == *old-storage.tar* && "$(get restore_fail)" == true ]]; then exit 47; fi
    if [[ " $* " == *" -xpf "* && "$*" == *old-storage.tar* && "$(get primary_restore_fail_once)" == true ]]; then
      put primary_restore_fail_once false; exit 47
    fi
    if [[ " $* " == *" -xpf "* && "$*" == *pre-rollback-storage.tar* && "$(get rescue_restore_fail)" == true ]]; then exit 48; fi
    exec /usr/bin/tar "$@"
    ;;
  sha256sum)
    if [[ "${1:-}" == -c && "$(get checksum_fail)" == true ]]; then exit 44; fi
    exec /usr/bin/sha256sum "$@"
    ;;
  du)
    echo "100 $1"; echo "100 $2"; echo "100 $3"
    ;;
  df)
    echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'
    if [[ "$(get capacity_fail)" == true ]]; then
      echo 'test 1000 950 50 95% /'
    else
      echo 'test 100000 1000 99000 1% /'
    fi
    ;;
  *) exit 2 ;;
esac
FAKE
  chmod +x "$bin/fake-command"
  local command
  for command in systemctl docker dpkg dpkg-query tar sha256sum du df; do
    ln -s fake-command "$bin/$command"
  done
}

new_case() {
  local name="$1"
  CASE="$TMP/$name"
  SIM_STATE="$CASE/state"
  mkdir -p "$SIM_STATE" "$CASE/bin" "$CASE/var/postgres" "$CASE/var/1cv8" \
    "$CASE/etc" "$CASE/log" "$CASE/backups" "$CASE/lib/state"
  printf '15\n' >"$CASE/var/postgres/PG_VERSION"
  printf 'original\n' >"$CASE/var/data-marker"
  : >"$SIM_STATE/events"
  local pair
  for pair in \
    'old_enabled enabled' 'old_active inactive' 'old_exists true' 'old_running false' \
    'dual_enabled enabled' 'dual_active active' 'target_exists true' 'target_running true' \
    'dualactive_exists false' 'dualactive_running false' 'postinstall_owner dual' 'postinstall_dual_running true' 'network_owner_mode none' \
    'manual_exists true' 'manual_running false' 'network_exists true' 'network_conflict false' \
    'network_driver bridge' 'network_subnet 10.23.0.0/16' 'network_gateway 10.23.0.1' \
    'network_compose_project vvz-1csrv-postgres' 'network_compose_name pgsql1c_net' \
    'network_compose_hash test-config-hash' 'network_compose_version 2.40.3' \
    'conflict_after_old_stop false' \
    'capacity_fail false' 'tar_fail false' 'checksum_fail false' 'dpkg_fail false' 'postinst_fail false' \
    'rollback_dpkg_fail false' 'restore_fail false' 'primary_restore_fail_once false' \
    'rescue_tar_fail false' 'rescue_restore_fail false' 'systemctl_restore_fail false' \
    'docker_restore_fail false' \
    'package_version 1.0.18'; do
    read -r key value <<<"$pair"; printf '%s\n' "$value" >"$SIM_STATE/$key"
  done
  printf 'stale-snapshot\n' >"$CASE/lib/state/transition-ready"
  printf 'schema=stale\n' >"$CASE/lib/state/transition-ready.identity"
  cat >"$CASE/old-stack-default" <<'DEFAULT'
PGSQL1C_VAR=/var/pgsql1c
PGSQL1C_LOG=/var/log/pgsql1c
PGSQL1C_ETC=/etc/pgsql1c
PGSQL1C_DOCKER_SUBNET=172.31.0.0/16
PGSQL1C_CONTAINER_IP=172.31.0.2
DEFAULT
  cat >"$CASE/old-compose.yml" <<'COMPOSE'
services:
  app:
    ports:
      - "1540:1540"
      - "1560-1591:1560-1591"
COMPOSE
  make_fake_commands "$CASE/bin"
  cat >"$CASE/old-cli" <<'CLI'
#!/usr/bin/env bash
set -euo pipefail
printf 'old-cli %s\n' "$*" >>"$SIM_STATE/events"
printf 'true\n' >"$SIM_STATE/old_exists"
printf 'false\n' >"$SIM_STATE/old_running"
CLI
  cat >"$CASE/dual-cli" <<'CLI'
#!/usr/bin/env bash
set -euo pipefail
printf 'dual-cli %s\n' "$*" >>"$SIM_STATE/events"
printf 'true\n' >"$SIM_STATE/target_exists"
printf 'false\n' >"$SIM_STATE/target_running"
CLI
  cat >"$CASE/verify" <<'VERIFY'
#!/usr/bin/env bash
set -euo pipefail
[[ "$(cat "$SIM_STATE/verify_fail" 2>/dev/null || echo false)" != true ]]
VERIFY
  chmod +x "$CASE/old-cli" "$CASE/dual-cli" "$CASE/verify"
  unset VVZ_TEST_MARKER_FAULT || true
  export SIM_STATE
}

run_helper() {
  env PATH="$CASE/bin:$PATH" SIM_STATE="$SIM_STATE" \
    OLD_UNIT=old.service DUAL_UNIT=dual.service \
    OLD_CONTAINER=old-container TARGET_CONTAINER=target-container MANUAL_CONTAINER=manual-container \
    NETWORK=test-network NETWORK_IP=10.23.0.2 DEB="$DEB" OLD_VAR="$CASE/var" OLD_ETC="$CASE/etc" OLD_LOG="$CASE/log" \
    VVZ_TRANSITION_TEST_MODE=1 VVZ_DUAL_DEB="$DEB" VVZ_ROLLBACK_DEB="$ROLLBACK_DEB" \
    VVZ_OLD_VAR="$CASE/var" VVZ_OLD_ETC="$CASE/etc" VVZ_OLD_LOG="$CASE/log" \
    VVZ_BACKUP_ROOT="$CASE/backups" VVZ_BACKUP_DIR="$CASE/snapshot" VVZ_STATE_DIR="$CASE/lib/state" \
    VVZ_VERIFY_CMD="$CASE/verify" VVZ_OLD_CLI="$CASE/old-cli" VVZ_DUAL_CLI="$CASE/dual-cli" \
    VVZ_OLD_UNIT=old.service VVZ_DUAL_UNIT=dual.service \
    VVZ_OLD_CONTAINER=old-container VVZ_TARGET_CONTAINER=target-container VVZ_MANUAL_CONTAINER=manual-container \
    VVZ_DUAL_ACTIVE_CONTAINER=dual-active-container DUAL_ACTIVE_CONTAINER=dual-active-container \
    VVZ_NETWORK=test-network VVZ_NETWORK_IP=10.23.0.2 \
    VVZ_NETWORK_SUBNET=10.23.0.0/16 VVZ_NETWORK_GATEWAY=10.23.0.1 \
    VVZ_OLD_STACK_DEFAULT="$CASE/old-stack-default" VVZ_OLD_COMPOSE="$CASE/old-compose.yml" \
    "$HELPER" "$@"
}

state_tuple() {
  local f out=''
  for f in old_enabled old_active old_exists old_running dual_enabled dual_active target_exists target_running \
    network_exists network_driver network_subnet network_gateway; do
    out+="$f=$(cat "$SIM_STATE/$f");"
  done
  printf '%s' "$out"
}

assert_original_state() {
  assert_eq "$(state_tuple)" \
    'old_enabled=enabled;old_active=inactive;old_exists=true;old_running=false;dual_enabled=enabled;dual_active=active;target_exists=true;target_running=true;network_exists=true;network_driver=bridge;network_subnet=10.23.0.0/16;network_gateway=10.23.0.1;' \
    'original service/container state'
  assert_eq "$(cat "$CASE/var/data-marker")" original 'original data marker'
}

assert_no_ready_marker() {
  [[ ! -e "$CASE/lib/state/transition-ready" ]] || fail 'stale transition-ready marker survived'
  [[ ! -e "$CASE/lib/state/transition-ready.identity" ]] || fail 'stale transition-ready identity survived'
}

expect_preflight_failure() {
  local name="$1" flag="$2"
  new_case "$name"; printf 'true\n' >"$SIM_STATE/$flag"
  if run_helper >"$CASE/out" 2>&1; then fail "$name unexpectedly succeeded"; fi
  assert_original_state
  assert_no_ready_marker
  [[ ! -s "$SIM_STATE/events" ]] || fail "$name mutated services before refusal: $(cat "$SIM_STATE/events")"
  echo "PASS $name"
}

expect_transaction_failure() {
  local name="$1" flag="$2"
  new_case "$name"; printf 'true\n' >"$SIM_STATE/$flag"
  if run_helper >"$CASE/out" 2>&1; then fail "$name unexpectedly succeeded"; fi
  assert_original_state
  assert_no_ready_marker
  grep -q '^systemctl stop old.service$' "$SIM_STATE/events" || fail "$name did not stop old unit; output: $(tr '\n' ';' <"$CASE/out"); events: $(tr '\n' ';' <"$SIM_STATE/events")"
  echo "PASS $name"
}

expect_preflight_failure capacity capacity_fail
expect_preflight_failure network network_conflict
expect_transaction_failure snapshot tar_fail
expect_transaction_failure checksum checksum_fail
expect_transaction_failure dpkg dpkg_fail
expect_transaction_failure postinst postinst_fail

expect_ownership_failure() {
  local name="$1" owner="$2"
  new_case "$name"
  printf '%s\n' "$owner" >"$SIM_STATE/postinstall_owner"
  if run_helper >"$CASE/out" 2>&1; then fail "$name unexpectedly succeeded"; fi
  assert_original_state
  assert_no_ready_marker
  [[ ! -e "$CASE/lib/state/manual-recovery-required" ]] || fail "$name recovery unexpectedly required manual intervention"
  grep -q 'Active endpoint ownership' "$CASE/out" || fail "$name did not report endpoint ownership failure"
  grep -q "dpkg -i $(basename "$ROLLBACK_DEB")" "$SIM_STATE/events" || fail "$name did not restore the rollback package"
  echo "PASS $name"
}

expect_ownership_failure endpoint-owner-missing none
expect_ownership_failure endpoint-owner-wrong wrong
expect_ownership_failure endpoint-owner-duplicate duplicate
expect_ownership_failure endpoint-owner-old old

new_case endpoint-owner-nonrunning
printf 'false\n' >"$SIM_STATE/postinstall_dual_running"
if run_helper >"$CASE/out" 2>&1; then fail 'non-running endpoint owner unexpectedly succeeded'; fi
assert_original_state
assert_no_ready_marker
grep -q 'Active endpoint ownership' "$CASE/out" || fail 'non-running endpoint owner did not report ownership failure'
echo 'PASS endpoint-owner-nonrunning'

new_case network-contract-conflict
printf 'true\n' >"$SIM_STATE/conflict_after_old_stop"
set +e
run_helper >"$CASE/out" 2>&1
rc=$?
set -e
assert_eq "$rc" 125 'network conflict fatal recovery exit'
! grep -q '^dpkg -i ' "$SIM_STATE/events" || fail 'network conflict reached dpkg'
assert_no_ready_marker
assert_file "$CASE/lib/state/manual-recovery-required"
grep -q 'old-network' "$CASE/lib/state/manual-recovery-required" || fail 'network conflict recovery evidence is missing'
echo 'PASS network-contract-conflict'

new_case marker-missing
export VVZ_TEST_MARKER_FAULT=missing
if run_helper >"$CASE/out" 2>&1; then fail 'missing marker identity unexpectedly succeeded'; fi
assert_original_state
assert_no_ready_marker
echo 'PASS marker-missing'

new_case marker-corrupt
export VVZ_TEST_MARKER_FAULT=corrupt
if run_helper >"$CASE/out" 2>&1; then fail 'corrupt marker identity unexpectedly succeeded'; fi
assert_original_state
assert_no_ready_marker
echo 'PASS marker-corrupt'

new_case readiness
printf 'true\n' >"$SIM_STATE/verify_fail"
if run_helper >"$CASE/out" 2>&1; then fail 'readiness unexpectedly succeeded'; fi
assert_original_state
assert_no_ready_marker
grep -q "dpkg -i $(basename "$ROLLBACK_DEB")" "$SIM_STATE/events" || fail "readiness failure did not reinstall rollback package; output: $(tr '\n' ';' <"$CASE/out"); events: $(tr '\n' ';' <"$SIM_STATE/events")"
! grep -q '^systemctl start old.service$' "$SIM_STATE/events" || fail 'stopped old runtime was started during recovery'
grep -q '^systemctl start dual.service$' "$SIM_STATE/events" || fail 'originally running target runtime was not restarted during recovery'
echo 'PASS readiness'

expect_manual_recovery() {
  local name="$1" flag="$2"
  new_case "$name"
  printf 'true\n' >"$SIM_STATE/verify_fail"
  printf 'true\n' >"$SIM_STATE/$flag"
  set +e
  run_helper >"$CASE/out" 2>&1
  rc=$?
  set -e
  assert_eq "$rc" 125 "$name fatal recovery exit"
  assert_no_ready_marker
  assert_file "$CASE/lib/state/manual-recovery-required"
  grep -q '^FATAL RECOVERY ERROR:' "$CASE/out" || fail "$name did not surface fatal recovery error"
  echo "PASS $name"
}

expect_manual_recovery rollback-deb-failure rollback_dpkg_fail
expect_manual_recovery data-restore-failure restore_fail
expect_manual_recovery runtime-restore-failure systemctl_restore_fail
expect_manual_recovery container-restore-failure docker_restore_fail

new_case success
run_helper >"$CASE/out" 2>&1
assert_eq "$(cat "$SIM_STATE/old_enabled")" disabled 'success old enabled state'
assert_eq "$(cat "$SIM_STATE/old_active")" inactive 'success old active state'
assert_eq "$(cat "$SIM_STATE/old_exists")" true 'success old container preservation'
assert_eq "$(cat "$SIM_STATE/old_running")" false 'success old container running state'
assert_eq "$(cat "$SIM_STATE/dual_active")" active 'success dual active state'
assert_eq "$(cat "$SIM_STATE/target_running")" true 'success target running state'
assert_file "$CASE/snapshot/old-storage.tar"
assert_file "$CASE/snapshot/SHA256SUMS"
assert_file "$CASE/lib/state/transition-complete"
assert_no_ready_marker
network_line="$(grep -n '^docker network create ' "$SIM_STATE/events" | head -n1 | cut -d: -f1)"
dpkg_line="$(grep -n '^dpkg -i ' "$SIM_STATE/events" | head -n1 | cut -d: -f1)"
[[ -n "$network_line" && -n "$dpkg_line" && "$network_line" -lt "$dpkg_line" ]] || fail 'verified network recreation did not precede dpkg'
assert_eq "$(cat "$SIM_STATE/network_driver")|$(cat "$SIM_STATE/network_subnet")|$(cat "$SIM_STATE/network_gateway")" \
  'bridge|10.23.0.0/16|10.23.0.1' 'success recreated network contract'
echo 'PASS success'

# Exercise explicit rollback from the exact stale state that previously made
# systemctl start a no-op: old unit active while its container is stopped.
printf 'active\n' >"$SIM_STATE/old_active"
printf 'true\n' >"$SIM_STATE/old_exists"
printf 'false\n' >"$SIM_STATE/old_running"
printf 'dual-data\n' >"$CASE/var/data-marker"
if ! run_helper --rollback "$CASE/snapshot" >"$CASE/rollback-out" 2>&1; then
  fail "explicit rollback failed: $(tr '\n' ';' <"$CASE/rollback-out"); events: $(tr '\n' ';' <"$SIM_STATE/events")"
fi
assert_eq "$(cat "$SIM_STATE/old_enabled")" enabled 'rollback old enabled state'
assert_eq "$(cat "$SIM_STATE/old_active")" active 'rollback old active state'
assert_eq "$(cat "$SIM_STATE/old_running")" true 'rollback old running state'
assert_eq "$(cat "$CASE/var/data-marker")" original 'rollback restored data'
grep -q '^systemctl reset-failed old.service$' "$SIM_STATE/events" || fail 'rollback did not reset stale old unit'
assert_no_ready_marker
[[ ! -e "$CASE/lib/state/transition-complete" ]] || fail 'successful rollback left stale completion marker'
echo 'PASS explicit-rollback'

new_case rollback-rescue-tar
run_helper >"$CASE/out" 2>&1
printf 'active\n' >"$SIM_STATE/old_active"
printf 'true\n' >"$SIM_STATE/old_exists"
printf 'false\n' >"$SIM_STATE/old_running"
printf 'pre-rollback-data\n' >"$CASE/var/data-marker"
before="$(state_tuple)"
printf 'true\n' >"$SIM_STATE/rescue_tar_fail"
if run_helper --rollback "$CASE/snapshot" >"$CASE/rollback-out" 2>&1; then fail 'rescue tar failure unexpectedly succeeded'; fi
assert_eq "$(state_tuple)" "$before" 'rescue tar failure state preservation'
assert_eq "$(cat "$CASE/var/data-marker")" pre-rollback-data 'rescue tar failure data preservation'
assert_no_ready_marker
[[ ! -e "$CASE/lib/state/manual-recovery-required" ]] || fail 'rescue tar refusal incorrectly requested manual recovery'
echo 'PASS rollback-rescue-tar'

new_case rollback-primary-restore
run_helper >"$CASE/out" 2>&1
printf 'active\n' >"$SIM_STATE/old_active"
printf 'true\n' >"$SIM_STATE/old_exists"
printf 'false\n' >"$SIM_STATE/old_running"
printf 'pre-rollback-data\n' >"$CASE/var/data-marker"
before="$(state_tuple)"
printf 'true\n' >"$SIM_STATE/primary_restore_fail_once"
if run_helper --rollback "$CASE/snapshot" >"$CASE/rollback-out" 2>&1; then fail 'primary rollback restore failure unexpectedly succeeded'; fi
normalized_before="${before/old_active=active/old_active=inactive}"
assert_eq "$(state_tuple)" "$normalized_before" 'failed rollback safe stopped-runtime restoration'
assert_eq "$(cat "$CASE/var/data-marker")" pre-rollback-data 'failed rollback rescue data restoration'
assert_no_ready_marker
[[ ! -e "$CASE/lib/state/manual-recovery-required" ]] || fail "successful rollback rescue incorrectly requested manual recovery: $(tr '\n' ';' <"$CASE/lib/state/manual-recovery-required"); output: $(tr '\n' ';' <"$CASE/rollback-out")"
echo 'PASS rollback-primary-restore-rescued'

new_case current-manual-recovery
printf 'true\n' >"$SIM_STATE/verify_fail"
printf 'true\n' >"$SIM_STATE/systemctl_restore_fail"
set +e
run_helper >"$CASE/out" 2>&1
rc=$?
set -e
assert_eq "$rc" 125 'manual recovery setup exit'
assert_file "$CASE/lib/state/manual-recovery-required"
printf 'false\n' >"$SIM_STATE/systemctl_restore_fail"
if ! run_helper --recover-runtime "$CASE/snapshot" >"$CASE/recover-out" 2>&1; then
  fail "manual runtime recovery failed: $(tr '\n' ';' <"$CASE/recover-out"); events: $(tr '\n' ';' <"$SIM_STATE/events")"
fi
assert_no_ready_marker
[[ ! -e "$CASE/lib/state/manual-recovery-required" ]] || fail 'manual runtime recovery did not clear verified marker'
assert_eq "$(cat "$SIM_STATE/old_exists")" true 'manual recovery old container existence'
assert_eq "$(cat "$SIM_STATE/old_running")" false 'manual recovery old container stopped state'
assert_eq "$(cat "$SIM_STATE/network_exists")" true 'manual recovery network existence'
assert_eq "$(cat "$SIM_STATE/network_subnet")" 10.23.0.0/16 'manual recovery network subnet'
echo 'PASS current-manual-recovery'

echo 'All transition helper tests passed'
