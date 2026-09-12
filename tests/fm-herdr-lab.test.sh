#!/usr/bin/env bash
# Behavior tests for bin/fm-herdr-lab.sh using a stateful fake Herdr client.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-lab)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
FAKE_STATE="$TMP_ROOT/herdr-state"
FAKE_LOG="$TMP_ROOT/herdr.log"
TRIPWIRES="$TMP_ROOT/tripwires"
REAL_SLEEP=$(command -v sleep)
mkdir -p "$FAKE_STATE"
printf '%s\n' '/home/test/.config/herdr/herdr.sock' > "$FAKE_STATE/default-socket"
: > "$FAKE_LOG"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FM_FAKE_HERDR_LOG"
state=$FM_FAKE_HERDR_STATE
last=
for arg in "$@"; do
  previous=$last
  last=$arg
done
[ "${previous:-}" = --session ] || { echo "fake herdr: missing trailing --session" >&2; exit 90; }
session=$last
default_socket=$(cat "$state/default-socket")
lab_state=absent
[ ! -f "$state/$session" ] || lab_state=$(cat "$state/$session")

case "$1 ${2:-}" in
  "session list")
    [ ! -f "$state/list-fails" ] || exit 94
    if [ -f "$state/fleet-override.json" ]; then
      jq --arg name "$session" --arg state "$lab_state" '
        if $state == "absent" or $state == "deleted" then . else
          .sessions += [{default:($state == "default"),name:$name,running:($state == "running"),socket_path:("/tmp/" + $name + ".sock")}]
        end' "$state/fleet-override.json"
      exit
    fi
    if [ "$lab_state" = absent ] || [ "$lab_state" = deleted ]; then
      jq -nc --arg socket "$default_socket" '{sessions:[{default:true,name:"default",running:true,socket_path:$socket}]}'
    else
      running=false
      [ "$lab_state" = running ] && running=true
      jq -nc --arg socket "$default_socket" --arg name "$session" --argjson running "$running" \
        '{sessions:[{default:true,name:"default",running:true,socket_path:$socket},{default:false,name:$name,running:$running,socket_path:("/tmp/" + $name + ".sock")}]}'
    fi
    ;;
  "server --session")
    if [ "${FM_FAKE_HERDR_SERVER_DELAY:-0}" != 0 ]; then
      "$FM_FAKE_HERDR_REAL_SLEEP" "$FM_FAKE_HERDR_SERVER_DELAY"
    fi
    printf '%s\n' running > "$state/$session"
    ;;
  "status --json")
    if [ "$lab_state" = running ]; then
      printf '%s\n' '{"server":{"running":true}}'
    else
      printf '%s\n' '{"server":{"running":false}}'
    fi
    ;;
  "session stop")
    [ "$3" = "$session" ] || exit 91
    printf '%s\n' stopped > "$state/$session"
    if [ -f "$state/after-stop.json" ]; then
      cp "$state/after-stop.json" "$state/fleet-override.json"
    fi
    ;;
  "session delete")
    [ "$3" = "$session" ] || exit 92
    [ "${FM_FAKE_HERDR_DELETE_FAIL:-}" != 1 ] || exit 93
    printf '%s\n' deleted > "$state/$session"
    if [ -f "$state/after-delete.json" ]; then
      cp "$state/after-delete.json" "$state/fleet-override.json"
    fi
    ;;
  *)
    printf '%s\n' '{"ok":true}'
    ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-herdr-lab.sh"

run_with_fake() {
  PATH="$FAKEBIN:$PATH" \
    FM_FAKE_HERDR_STATE="$FAKE_STATE" \
    FM_FAKE_HERDR_LOG="$FAKE_LOG" \
    FM_FAKE_HERDR_REAL_SLEEP="$REAL_SLEEP" \
    FM_FAKE_HERDR_SERVER_DELAY="${FM_FAKE_HERDR_SERVER_DELAY:-0}" \
    FM_FAKE_HERDR_FAST_POLL="${FM_FAKE_HERDR_FAST_POLL:-}" \
    FM_FAKE_HERDR_DELETE_FAIL="${FM_FAKE_HERDR_DELETE_FAIL:-}" \
    FM_HERDR_LAB_STATE_DIR="$TRIPWIRES" \
    "$@"
}

test_refuses_unsafe_names() {
  local status=0 generated
  fm_herdr_lab_validate_name default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "literal default must be refused"
  status=0
  fm_herdr_lab_validate_name arbitrary-session >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "non-lab prefix must be refused"
  fm_herdr_lab_validate_name fm-lab-safe-123 || fail "valid lab session name was refused"
  generated=$(fm_herdr_lab_name fm-autodetect-smoke-concurrency-h3)
  fm_herdr_lab_validate_name "$generated" || fail "generated lab session name was refused"
  [ "${#generated}" -le 40 ] || fail "generated lab session name is too long for Herdr socket paths: $generated"
  pass "fm-herdr-lab: names fail closed and require the lab prefix"
}

test_provision_run_and_guarded_teardown() {
  local name='' line_count status=0 stop_line delete_line
  name="fm-lab-behavior-$$"
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "provision failed"
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "provision did not start the named lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "provision did not record the fleet-state tripwire"

  run_with_fake fm_herdr_lab_cli "$name" workspace list >/dev/null || fail "safe run command failed"
  run_with_fake fm_herdr_lab_cli "$name" pane close w2:p1 >/dev/null || fail "guarded lab mutation failed"
  run_with_fake fm_herdr_lab_cli "$name" server >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "bare server start outside provision must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" server stop >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "server-global stop must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" session delete "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "direct session delete must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" status --session default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "caller-supplied session flag must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" status --session=default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "caller-supplied equals-form session flag must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" --handoff server stop >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a leading option shifting server stop past the guard must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" --no-session session delete "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a leading option shifting session delete past the guard must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" --remote host workspace list >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a leading option subverting session isolation must be refused"

  run_with_fake fm_herdr_lab_teardown "$name" || fail "guarded teardown failed"
  [ "$(cat "$FAKE_STATE/$name")" = deleted ] || fail "teardown did not delete the lab session"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "successful teardown left its tripwire behind"

  while IFS= read -r line; do
    case "$line" in
      *"--session $name") : ;;
      *) fail "Herdr call lacks a trailing lab session: $line" ;;
    esac
  done < "$FAKE_LOG"
  line_count=$(wc -l < "$FAKE_LOG" | tr -d ' ')
  stop_line=$(grep -n "^session stop $name --json --session $name$" "$FAKE_LOG" | cut -d: -f1)
  delete_line=$(grep -n "^session delete $name --json --session $name$" "$FAKE_LOG" | cut -d: -f1)
  if [ -z "$stop_line" ] || [ -z "$delete_line" ] || [ "$line_count" -le "$delete_line" ]; then
    fail "teardown did not emit explicit stop/delete followed by the after tripwire"
  fi
  sed -n "$((stop_line - 1))p" "$FAKE_LOG" | grep -F "session list --json --session $name" >/dev/null \
    || fail "stop was not immediately preceded by a fresh refuse-default session list"
  sed -n "$((delete_line - 1))p" "$FAKE_LOG" | grep -F "session list --json --session $name" >/dev/null \
    || fail "delete was not immediately preceded by a fresh refuse-default session list"
  pass "fm-herdr-lab: provisioning, scoped calls, guarded teardown, and fleet tripwire are deterministic"
}

test_missing_tripwire_blocks_destruction() {
  local name="fm-lab-no-tripwire-$$" status=0 before after
  printf '%s\n' running > "$FAKE_STATE/$name"
  : > "$FAKE_LOG"
  before=$(wc -l < "$FAKE_LOG")
  run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "missing tripwire must refuse teardown"
  after=$(wc -l < "$FAKE_LOG")
  [ "$before" = "$after" ] || fail "missing tripwire reached Herdr instead of refusing before destructive calls"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" pane close w2:p1 >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "missing tripwire must refuse lab run"
  [ ! -s "$FAKE_LOG" ] || fail "missing tripwire reached lab run mutation"
  pass "fm-herdr-lab: missing tripwire refuses teardown before any Herdr call"
}

test_changed_default_blocks_teardown() {
  local name="fm-lab-tripwire-change-$$" status=0
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "tripwire fixture provision failed"
  printf '%s\n' '/changed/default.sock' > "$FAKE_STATE/default-socket"
  run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "changed default fleet state must fail teardown"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" pane close w2:p1 >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "changed default fleet state must fail lab run"
  if grep -q '^pane close ' "$FAKE_LOG"; then fail "changed default allowed lab run mutation"; fi
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "changed default allowed a destructive call"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "failed tripwire should retain evidence"
  printf '%s\n' '/home/test/.config/herdr/herdr.sock' > "$FAKE_STATE/default-socket"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "restored default did not allow guarded cleanup"
  pass "fm-herdr-lab: changed default fleet state is a hard failure before destruction"
}

test_stopped_owned_lab_can_reprovision() {
  local name="fm-lab-reprovision-$$"
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "initial provision failed"
  run_with_fake fm_herdr_lab_stop "$name" || fail "guarded stop failed"
  [ "$(cat "$FAKE_STATE/$name")" = stopped ] || fail "guarded stop did not stop the lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "stop removed the lab ownership tripwire"
  run_with_fake fm_herdr_lab_provision "$name" || fail "re-provision after guarded stop failed"
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "re-provision did not restart the stopped lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "re-provision removed the lab ownership tripwire"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after re-provision failed"
  pass "fm-herdr-lab: an owned stopped lab can re-provision safely"
}

test_failed_delete_retains_tripwire() {
  local name="fm-lab-delete-failure-$$" status=0
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "delete-failure fixture provision failed"
  FM_FAKE_HERDR_DELETE_FAIL=1 run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "failed delete must fail teardown"
  [ "$(cat "$FAKE_STATE/$name")" = stopped ] || fail "failed delete unexpectedly removed the lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "failed delete removed the ownership tripwire"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "retry after failed delete did not clean up the lab session"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "successful retry left the ownership tripwire behind"
  pass "fm-herdr-lab: failed deletion retains ownership until absence is confirmed"
}

test_timed_out_provision_cancels_late_launch() {
  local name="fm-lab-late-launch-$$" status=0
  cat > "$FAKEBIN/sleep" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FAKE_HERDR_FAST_POLL:-}" = 1 ]; then
  exit 0
fi
exec "$FM_FAKE_HERDR_REAL_SLEEP" "$@"
SH
  chmod +x "$FAKEBIN/sleep"
  : > "$FAKE_LOG"
  FM_FAKE_HERDR_FAST_POLL=1 FM_FAKE_HERDR_SERVER_DELAY=30 \
    run_with_fake fm_herdr_lab_provision "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "timed-out provision must fail"
  assert_present "$TRIPWIRES/$name.fleet-state.json" \
    "timed-out provision must retain its tripwire until teardown"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after timed-out provision failed"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" \
    "teardown after timed-out provision did not remove its tripwire"
  "$REAL_SLEEP" 1.1
  if [ -f "$FAKE_STATE/$name" ] && [ "$(cat "$FAKE_STATE/$name")" = running ]; then
    fail "timed-out provision left a late-starting lab session after teardown"
  fi
  pass "fm-herdr-lab: timed-out provisioning cancels the launch before teardown"
}

test_named_fleet_protection() {
  local name="fm-lab-named-$$" status variant
  export FM_HERDR_LAB_PROTECTED_SESSION=fm-remote
  printf '%s\n' '{"sessions":[{"name":"fm-remote","default":false,"running":true,"socket_path":"/named/fleet.sock"}]}' > "$FAKE_STATE/fleet-override.json"
  run_with_fake fm_herdr_lab_provision "$name" || fail "named fleet provision failed"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "named fleet teardown failed"
  for variant in missing duplicate stopped wrong-default empty-socket; do
    case "$variant" in
      missing) printf '%s\n' '{"sessions":[]}' ;;
      duplicate) printf '%s\n' '{"sessions":[{"name":"fm-remote","default":false,"running":true,"socket_path":"/x"},{"name":"fm-remote","default":false,"running":true,"socket_path":"/y"}]}' ;;
      stopped) printf '%s\n' '{"sessions":[{"name":"fm-remote","default":false,"running":false,"socket_path":"/x"}]}' ;;
      wrong-default) printf '%s\n' '{"sessions":[{"name":"fm-remote","default":true,"running":true,"socket_path":"/x"}]}' ;;
      empty-socket) printf '%s\n' '{"sessions":[{"name":"fm-remote","default":false,"running":true,"socket_path":""}]}' ;;
    esac > "$FAKE_STATE/fleet-override.json"
    : > "$FAKE_LOG"
    status=0
    run_with_fake fm_herdr_lab_provision "$name-$variant" >/dev/null 2>&1 || status=$?
    expect_code 1 "$status" "$variant named fleet must refuse provision"
    if grep -q '^server ' "$FAKE_LOG"; then fail "$variant reached server launch"; fi
  done
  rm -f "$FAKE_STATE/fleet-override.json"
  export FM_HERDR_LAB_PROTECTED_SESSION="$name"
  for variant in prepare provision stop teardown; do
    status=0
    run_with_fake "fm_herdr_lab_$variant" "$name" >/dev/null 2>&1 || status=$?
    expect_code 1 "$status" "protected lab-shaped name must refuse $variant"
  done
  status=0
  run_with_fake fm_herdr_lab_cli "$name" workspace list >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "protected lab-shaped name must refuse run"
  status=0
  run_with_fake fm_herdr_lab_provision default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "explicit named fleet never permits default target"
  unset FM_HERDR_LAB_PROTECTED_SESSION
  pass "fm-herdr-lab: explicit named fleet is protected; missing, ambiguous and invalid identities refuse before launch"
}

test_named_fleet_drift_and_ambiguity() {
  local name="fm-lab-named-drift-$$" variant operation status
  local fleet='{"sessions":[{"name":"fm-remote","default":false,"running":true,"socket_path":"/named/fleet.sock"}]}'
  export FM_HERDR_LAB_PROTECTED_SESSION=fm-remote
  printf '%s\n' "$fleet" > "$FAKE_STATE/fleet-override.json"
  run_with_fake fm_herdr_lab_provision "$name" || fail "named drift fixture provision failed"
  for variant in missing duplicate stopped socket default alias malformed multi-json list-fails; do
    case "$variant" in
      missing) printf '%s\n' '{"sessions":[]}' ;;
      duplicate) printf '%s' "$fleet" | jq '.sessions += .sessions' ;;
      stopped) printf '%s' "$fleet" | jq '.sessions[0].running = false' ;;
      socket) printf '%s' "$fleet" | jq '.sessions[0].socket_path = "/changed/fleet.sock"' ;;
      default) printf '%s' "$fleet" | jq '.sessions[0].default = true' ;;
      alias) printf '%s' "$fleet" | jq '.sessions += [(.sessions[0] | .name = "other")]' ;;
      malformed) printf '%s\n' '{broken' ;;
      multi-json) printf '%s\n%s\n' "$fleet" "$fleet" ;;
      list-fails) touch "$FAKE_STATE/list-fails"; printf '%s\n' "$fleet" ;;
    esac > "$FAKE_STATE/fleet-override.json"
    for operation in stop teardown provision; do
      : > "$FAKE_LOG"
      status=0
      run_with_fake "fm_herdr_lab_$operation" "$name" >/dev/null 2>&1 || status=$?
      expect_code 1 "$status" "$variant must refuse $operation"
      if grep -Eq '^(server |session (stop|delete) )' "$FAKE_LOG"; then
        fail "$variant reached lifecycle mutation during $operation"
      fi
      assert_present "$TRIPWIRES/$name.fleet-state.json" "$variant lost retained tripwire"
    done
    : > "$FAKE_LOG"
    status=0
    run_with_fake fm_herdr_lab_cli "$name" pane close w2:p1 >/dev/null 2>&1 || status=$?
    expect_code 1 "$status" "$variant must refuse lab run mutation"
    if grep -q '^pane close ' "$FAKE_LOG"; then fail "$variant reached lab run mutation"; fi
    rm -f "$FAKE_STATE/list-fails"
  done
  printf '%s\n' "$fleet" > "$FAKE_STATE/fleet-override.json"
  for variant in default duplicate socket; do
    case "$variant" in
      default) printf '%s\n' default > "$FAKE_STATE/$name"; printf '%s\n' "$fleet" ;;
      duplicate) printf '%s' "$fleet" | jq --arg name "$name" '.sessions += [{name:$name,default:false,running:true,socket_path:"/lab.sock"}]' ;;
      socket) printf '%s' "$fleet" | jq --arg name "$name" '.sessions[0].socket_path = ("/tmp/" + $name + ".sock")' ;;
    esac > "$FAKE_STATE/fleet-override.json"
    : > "$FAKE_LOG"
    status=0
    run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
    expect_code 1 "$status" "ambiguous/default lab ($variant) must refuse teardown"
    if grep -Eq '^session (stop|delete) ' "$FAKE_LOG"; then fail "ambiguous lab reached destruction"; fi
    printf '%s\n' running > "$FAKE_STATE/$name"
  done
  printf '%s\n' "$fleet" > "$FAKE_STATE/fleet-override.json"
  run_with_fake fm_herdr_lab_stop "$name" >/dev/null || fail "owned lab stop failed"
  printf '%s' "$fleet" | jq '.sessions[0].socket_path = "/changed.sock"' > "$FAKE_STATE/fleet-override.json"
  : > "$FAKE_LOG"
  status=0
  run_with_fake fm_herdr_lab_provision "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "stopped owned lab must not restart after fleet change"
  if grep -q '^server ' "$FAKE_LOG"; then fail "changed fleet allowed restart"; fi
  printf '%s\n' "$fleet" > "$FAKE_STATE/fleet-override.json"
  printf '%s\n' absent > "$FAKE_STATE/$name"
  : > "$FAKE_LOG"
  status=0
  run_with_fake fm_herdr_lab_stop "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "missing lab target must refuse stop even with a tripwire"
  if grep -q '^session stop ' "$FAKE_LOG"; then fail "missing lab target reached stop"; fi
  run_with_fake fm_herdr_lab_teardown "$name" || fail "named drift fixture cleanup failed"
  rm -f "$FAKE_STATE/fleet-override.json"
  unset FM_HERDR_LAB_PROTECTED_SESSION
  pass "fm-herdr-lab: fleet drift, failed reads and ambiguous lab identities block lifecycle mutations"
}

test_selection_and_destructive_rechecks() {
  local name="fm-lab-rechecks-$$" selection operation status phase
  local fleet='{"sessions":[{"name":"fm-remote","default":false,"running":true,"socket_path":"/named/fleet.sock"}]}'
  printf '%s\n' "$fleet" > "$FAKE_STATE/fleet-override.json"
  # Ambient Herdr selection must not silently opt out of protecting default.
  status=0
  HERDR_SESSION=fm-remote run_with_fake fm_herdr_lab_prepare "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "ambient HERDR_SESSION must not select the protected fleet"
  export FM_HERDR_LAB_PROTECTED_SESSION=fm-remote
  run_with_fake fm_herdr_lab_provision "$name" || fail "selection fixture provision failed"
  for selection in '' '../fm-remote' other default; do
    for operation in stop teardown provision; do
      : > "$FAKE_LOG"
      status=0
      FM_HERDR_LAB_PROTECTED_SESSION="$selection" run_with_fake "fm_herdr_lab_$operation" "$name" >/dev/null 2>&1 || status=$?
      expect_code 1 "$status" "invalid/changed selection must refuse $operation"
      if grep -Eq '^(server |session (stop|delete) )' "$FAKE_LOG"; then fail "changed selector reached mutation"; fi
    done
  done
  # A different valid running selection is still not the originally recorded fleet.
  printf '%s' "$fleet" | jq '.sessions += [{name:"other",default:false,running:true,socket_path:"/other.sock"}]' > "$FAKE_STATE/fleet-override.json"
  status=0
  FM_HERDR_LAB_PROTECTED_SESSION=other run_with_fake fm_herdr_lab_stop "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "valid changed selector must fail the recorded identity comparison"
  printf '%s\n' "$fleet" > "$FAKE_STATE/fleet-override.json"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "selection fixture cleanup failed"
  for phase in stop delete; do
    name="fm-lab-recheck-$phase-$$"
    printf '%s\n' "$fleet" > "$FAKE_STATE/fleet-override.json"
    run_with_fake fm_herdr_lab_provision "$name" || fail "recheck fixture provision failed"
    printf '%s' "$fleet" | jq '.sessions[0].socket_path = "/changed.sock"' > "$FAKE_STATE/after-$phase.json"
    : > "$FAKE_LOG"
    status=0
    run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
    expect_code 1 "$status" "fleet change after $phase must fail teardown"
    assert_present "$TRIPWIRES/$name.fleet-state.json" "after-$phase drift lost evidence"
    if [ "$phase" = stop ] && grep -q '^session delete ' "$FAKE_LOG"; then fail "delete did not recheck after stop"; fi
    rm -f "$FAKE_STATE/after-$phase.json"
    printf '%s\n' "$fleet" > "$FAKE_STATE/fleet-override.json"
    run_with_fake fm_herdr_lab_teardown "$name" || fail "recheck fixture cleanup failed"
  done
  rm -f "$FAKE_STATE/fleet-override.json"
  unset FM_HERDR_LAB_PROTECTED_SESSION
  printf '%s\n' '{"sessions":[{"name":"default","default":true,"running":true,"socket_path":"/default.sock"},{"name":"impostor","default":true,"running":true,"socket_path":"/other.sock"}]}' > "$FAKE_STATE/fleet-override.json"
  status=0
  run_with_fake fm_herdr_lab_prepare "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "default compatibility must preserve the unique default-bit guard"
  rm -f "$FAKE_STATE/fleet-override.json"
  pass "fm-herdr-lab: explicit selection stays bound; stop/delete and final absence recheck the fleet"
}

test_refuses_unsafe_names
test_named_fleet_protection
test_named_fleet_drift_and_ambiguity
test_selection_and_destructive_rechecks
test_provision_run_and_guarded_teardown
test_missing_tripwire_blocks_destruction
test_changed_default_blocks_teardown
test_stopped_owned_lab_can_reprovision
test_failed_delete_retains_tripwire
test_timed_out_provision_cancels_late_launch
