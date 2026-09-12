#!/usr/bin/env bash
# Herdr endpoint relocation for fm-control, sourced after herdr.sh.
# The owning home's metadata lock and the existing per-session presentation
# lock serialize relocation. A herdr_move JSON field is written BEFORE the
# single native request; ordinary endpoint consumers refuse while it exists.
# Reconcile searches only the recorded destination for the recorded terminal,
# never repeats the move, and leaves uncertain outcomes pending. Moving back is
# another explicit move using its newly returned endpoint, not an ID rollback.
# No agent, source checkout, task, or home is created or restarted here.

# Replace only named fields, preserving all other metadata. The caller owns
# the metadata lock; use the existing file's mode and atomic same-dir replace.
fm_backend_herdr_move_meta() { # <meta> <JSON object: key -> string|null>
  python3 - "$1" "$2" <<'PY'
import json, os, stat, sys, tempfile
path, changes = sys.argv[1], json.loads(sys.argv[2])
s = os.lstat(path)
if not stat.S_ISREG(s.st_mode) or s.st_nlink != 1:
    raise SystemExit('refusing non-regular or multiply linked metadata')
with open(path) as f:
    lines = f.read().splitlines()
lines = [line for line in lines if line.split('=', 1)[0] not in changes]
for key, value in changes.items():
    if value is not None:
        if not isinstance(value, str) or any(c in value for c in '\n\r\t'):
            raise SystemExit('invalid metadata value')
        lines.append(key + '=' + value)
fd, tmp = tempfile.mkstemp(prefix='.herdr-move-', dir=os.path.dirname(path))
try:
    os.fchmod(fd, stat.S_IMODE(s.st_mode))
    with os.fdopen(fd, 'w') as f:
        f.write('\n'.join(lines) + '\n')
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
}

fm_backend_herdr_move_identity() { # <session> <pane>
  local pane process pid birth
  if ! declare -F fm_pid_identity >/dev/null 2>&1; then
    # shellcheck source=bin/fm-wake-lib.sh
    . "$FM_BACKEND_HERDR_ROOT/bin/fm-wake-lib.sh"
  fi
  pane=$(fm_backend_herdr_cli "$1" pane get "$2") || return 1
  process=$(fm_backend_herdr_cli "$1" pane process-info --pane "$2") || return 1
  pid=$(printf '%s' "$process" | jq -er '.result.process_info.shell_pid | select(type == "number" and . > 0)') || return 1
  birth=$(fm_pid_identity "$pid") || return 1
  [ -n "$birth" ] || return 1
  printf '%s' "$pane" | jq -ce --arg expected "$2" --argjson pid "$pid" --arg birth "$birth" '
    .result.pane | select(.pane_id == $expected)
    | select((.terminal_id | type == "string" and length > 0)
        and (.cwd | type == "string" and length > 0))
    | {pane: .pane_id, tab: .tab_id, workspace: .workspace_id,
       terminal: .terminal_id, cwd, pid: $pid, birth: $birth}'
}

fm_backend_herdr_move_same_process() { # <recorded identity> <current identity>
  jq -en --argjson before "$1" --argjson after "$2" '
    ($before | {terminal,cwd,pid,birth}) == ($after | {terminal,cwd,pid,birth})' >/dev/null
}

fm_backend_herdr_route_identity() {
  local meta=$1 id=$2 route session identity owner
  route=$(fm_backend_meta_exact_value "$meta" herdr_route) || return 1
  session=$(fm_backend_meta_exact_value "$meta" herdr_session) || return 1
  jq -en --argjson r "$route" --arg task "$id" --arg session "$session" \
    --arg socket "$(fm_backend_herdr_presentation_session_socket_path "$session")" \
    --arg window "$(fm_backend_meta_exact_value "$meta" window)" \
    --arg pane "$(fm_backend_meta_exact_value "$meta" herdr_pane_id)" \
    --arg tab "$(fm_backend_meta_exact_value "$meta" herdr_tab_id)" \
    --arg workspace "$(fm_backend_meta_exact_value "$meta" herdr_workspace_id)" '
    $r.task == $task and $r.session == $session
    and ($socket | length > 0) and $r.socket == $socket
    and $window == ($session + ":" + $r.identity.pane)
    and $r.identity.pane == $pane and $r.identity.tab == $tab and $r.identity.workspace == $workspace
    and ($r.former | type == "array" and length > 0 and all(.[]; type == "string"))' >/dev/null || return 1
  identity=$(printf '%s' "$route" | jq -ce .identity) || return 1
  if [ "${3:-0}" = 0 ]; then
    identity=$(fm_backend_herdr_move_identity "$session" "$(printf '%s' "$route" | jq -r .identity.pane)") || return 1
    jq -en --argjson r "$route" --argjson now "$identity" '$r.identity == $now' >/dev/null || return 1
  fi
  owner=$(fm_backend_meta_for_window "$session:$(printf '%s' "$identity" | jq -r .pane)" "${meta%/*}") || return 1
  [ "$owner" = "$meta" ]
}

fm_backend_herdr_route_selector() {
  local meta=$1 target=$2 id route previous session
  id=${meta##*/}
  fm_backend_validate_task_endpoint "$meta" "${id%.meta}" || return 1
  route=$(fm_backend_meta_exact_value "$meta" herdr_route) || return 1
  session=$(printf '%s' "$route" | jq -er .session) || return 1
  [ "${target%%:*}" = "$session" ] || return 1
  previous=$(fm_backend_herdr_cli "$session" pane get "${target#*:}" 2>&1) || true
  printf '%s' "$previous" | jq -e --argjson r "$route" '
    .error.code == "pane_not_found" or
    (.result.pane | .pane_id == $r.identity.pane and .tab_id == $r.identity.tab
      and .workspace_id == $r.identity.workspace and .terminal_id == $r.identity.terminal)' >/dev/null
}

fm_backend_herdr_move_finish() { # <meta> <task> <pending> <returned-pane>
  local meta=$1 id=$2 pending=$3 pane=$4 session identity before tab current route former='[]' owner rc
  session=$(printf '%s' "$pending" | jq -er .session) || return 1
  before=$(printf '%s' "$pending" | jq -ce .identity) || return 1
  identity=$(fm_backend_herdr_move_identity "$session" "$pane") || return 1
  fm_backend_herdr_move_same_process "$before" "$identity" || return 1
  jq -en --argjson pending "$pending" --argjson now "$identity" '
    $now.workspace == $pending.destination' >/dev/null || return 1
  tab=$(printf '%s' "$identity" | jq -er .tab) || return 1
  current=$(fm_backend_herdr_cli "$session" tab get "$tab") || return 1
  printf '%s' "$current" | jq -e --arg tab "$tab" --arg label "fm-$id" \
    --arg workspace "$(printf '%s' "$identity" | jq -r .workspace)" '
    .result.tab.tab_id == $tab and .result.tab.workspace_id == $workspace
    and .result.tab.label == $label and .result.tab.pane_count == 1' >/dev/null || return 1
  if grep -q '^herdr_route=' "$meta"; then
    route=$(fm_backend_meta_exact_value "$meta" herdr_route) || return 1
    former=$(jq -cen --argjson r "$route" --argjson pending "$pending" '
      $r | select(.task == $pending.task and .session == $pending.session
        and .socket == $pending.socket and .identity == $pending.identity) | .former') || return 1
  fi
  rc=0
  owner=$(fm_backend_meta_for_window "$session:$pane" "${meta%/*}") || rc=$?
  [ "$rc" -ne 2 ] && { [ -z "$owner" ] || [ "$owner" = "$meta" ]; } || return 1
  route=$(jq -cn --argjson pending "$pending" --argjson identity "$identity" \
    --argjson former "$former" '
    $pending | {task,session,socket,identity:$identity,
      former:($former + [(.session + ":" + .identity.pane)] | unique)}') || return 1
  # Keep the old projection journal as evidence, not as a new endpoint owner.
  # Its exact binding no longer matches and therefore cannot authorize reuse.
  fm_backend_herdr_move_meta "$meta" "$(jq -cn --argjson identity "$identity" --arg session "$session" --arg route "$route" '
    {window: ($session + ":" + $identity.pane), herdr_session: $session,
     herdr_workspace_id: $identity.workspace, herdr_tab_id: $identity.tab,
     herdr_pane_id: $identity.pane, herdr_route: $route, herdr_move: null}')" || return 1
  printf '%s:%s\n' "$session" "$pane"
}

fm_backend_herdr_move_reconcile() { # <meta> <task> <pending>
  local pending=$3 session destination terminal panes matches pane
  session=$(printf '%s' "$pending" | jq -er .session) || return 1
  destination=$(printf '%s' "$pending" | jq -er .destination) || return 1
  terminal=$(printf '%s' "$pending" | jq -er .identity.terminal) || return 1
  panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$destination") || return 1
  matches=$(printf '%s' "$panes" | jq -c --arg terminal "$terminal" '
    [.result.panes[] | select(.terminal_id == $terminal)]') || return 1
  pane=$(printf '%s' "$matches" | jq -er 'select(length == 1) | .[0].pane_id') || {
    echo 'error: move outcome is not uniquely present at its destination; retained pending record; no move replayed' >&2
    return 1
  }
  fm_backend_herdr_move_finish "$1" "$2" "$pending" "$pane"
}

fm_backend_herdr_move_task_locked() { # <meta> <task> <destination> <expected-target> <move|reconcile-move>
  local meta=$1 id=$2 destination=$3 expected=$4 verb=$5 pending session pane identity tabs out returned before label socket
  pending=
  if grep -q '^herdr_move=' "$meta"; then
    pending=$(fm_backend_meta_exact_value "$meta" herdr_move) || return 1
  fi
  session=$(fm_backend_meta_exact_value "$meta" herdr_session) || return 1
  socket=$(fm_backend_herdr_presentation_session_socket_path "$session") || return 1
  if [ -n "$pending" ]; then
    [ "$verb" = reconcile-move ] || {
      echo 'error: endpoint has an unresolved move; use reconcile-move, never repeat the move' >&2; return 1;
    }
    printf '%s' "$pending" | jq -e --arg id "$id" --arg socket "$socket" --arg session "$session" \
      --arg binding "$(fm_backend_meta_exact_value "$meta" endpoint_task_id)" \
      --arg window "$(fm_backend_meta_exact_value "$meta" window)" \
      --arg tab "$(fm_backend_meta_exact_value "$meta" herdr_tab_id)" \
      --arg workspace "$(fm_backend_meta_exact_value "$meta" herdr_workspace_id)" '
      .task == $id and $binding == $id and .session == $session and .socket == $socket
      and $window == ($session + ":" + .identity.pane)
      and $tab == .identity.tab and $workspace == .identity.workspace' >/dev/null || return 1
    fm_backend_herdr_move_reconcile "$meta" "$id" "$pending"
    return
  fi
  [ "$verb" = move ] || { echo 'error: no pending move to reconcile' >&2; return 1; }
  fm_backend_validate_task_endpoint "$meta" "$id" || return 1
  [ "$FM_BACKEND_VALIDATED_BACKEND" = herdr ] && [ "$FM_BACKEND_VALIDATED_TARGET" = "$expected" ] || {
    echo 'error: expected Herdr endpoint changed; no move attempted' >&2; return 1;
  }
  [ "$(fm_backend_meta_for_window "$expected" "${meta%/*}")" = "$meta" ] || return 1
  if [ "$(fm_meta_get "$meta" kind)" = secondmate ]; then
    local home
    home=$(fm_backend_meta_exact_value "$meta" home) || return 1
    if [ -e "$home/state/.afk" ]; then
      echo 'error: secondmate has an away daemon with a cached supervisor target; preserve its endpoint until that daemon is retired by its owner' >&2
      return 1
    fi
  fi
  pane=$(fm_backend_meta_exact_value "$meta" herdr_pane_id) || return 1
  identity=$(fm_backend_herdr_move_identity "$session" "$pane") || return 1
  printf '%s' "$identity" | jq -e \
    --arg tab "$(fm_backend_meta_exact_value "$meta" herdr_tab_id)" \
    --arg workspace "$(fm_backend_meta_exact_value "$meta" herdr_workspace_id)" \
    '.tab == $tab and .workspace == $workspace' >/dev/null || return 1
  before=$(printf '%s' "$identity" | jq -er .workspace) || return 1
  [ "$before" != "$destination" ] || { echo 'error: endpoint already occupies destination; no move attempted' >&2; return 1; }
  out=$(fm_backend_herdr_cli "$session" workspace list) || return 1
  printf '%s' "$out" | jq -e --arg destination "$destination" '
    [.result.workspaces[] | select(.workspace_id == $destination)] | length == 1' >/dev/null || return 1
  label=$(fm_backend_herdr_cli "$session" tab get "$(printf '%s' "$identity" | jq -r .tab)") || return 1
  printf '%s' "$label" | jq -e --arg label "fm-$id" --arg workspace "$before" \
    --arg tab "$(printf '%s' "$identity" | jq -r .tab)" '
    .result.tab.label == $label and .result.tab.tab_id == $tab
    and .result.tab.workspace_id == $workspace and .result.tab.pane_count == 1' >/dev/null || return 1
  tabs=$(fm_backend_herdr_cli "$session" pane list --workspace "$before") || return 1
  # Native pane.move closes an emptied source workspace. Require an existing
  # remaining terminal, not a fabricated shell or an unreviewed inverse.
  printf '%s' "$tabs" | jq -e '.result.panes | length > 1' >/dev/null || {
    echo 'error: moving the only source terminal would remove its workspace; retain a source terminal before moving' >&2; return 1;
  }
  pending=$(jq -cn --arg task "$id" --arg session "$session" --arg socket "$socket" \
    --arg destination "$destination" --argjson identity "$identity" \
    '{task:$task,session:$session,socket:$socket,destination:$destination,identity:$identity}') || return 1
  fm_backend_herdr_move_meta "$meta" "$(jq -cn --arg pending "$pending" '{herdr_move:$pending}')" || return 1
  # A lost response or verification failure deliberately leaves the pending
  # field. No automatic move-back, retry, or source-container cleanup is safe.
  out=$(fm_backend_herdr_cli "$session" pane move "$pane" --new-tab --workspace "$destination" --label "fm-$id" --no-focus) || return 1
  returned=$(printf '%s' "$out" | jq -er --arg previous "$pane" '
    .result.move_result | select(.previous_pane_id == $previous) | .pane.pane_id') || return 1
  fm_backend_herdr_move_finish "$meta" "$id" "$pending" "$returned"
}

fm_backend_herdr_move_task() { # <meta> <task> <destination> <expected-target> <verb>
  local lock session result=0
  session=$(fm_backend_meta_exact_value "$1" herdr_session) || return 1
  lock=$(fm_backend_herdr_presentation_session_lock_path "$session") || return 1
  fm_lock_try_acquire "$lock" || { echo 'error: Herdr session layout is busy' >&2; return 1; }
  fm_backend_herdr_move_task_locked "$@" || result=$?
  fm_lock_release "$lock" || return 1
  return "$result"
}
