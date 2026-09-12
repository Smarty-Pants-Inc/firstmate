#!/usr/bin/env bash
# Read-only retained Herdr identity checks. No allocator, terminal input, or
# membership mutation. Sourced by fm-enroll-herdr and enrolled-task consumers.
# shellcheck source=bin/fm-wake-lib.sh
. "${FM_BACKEND_LIB_DIR:?}/fm-wake-lib.sh"

fm_backend_herdr_enrollment_identity() { # <receipt JSON>
  local receipt=$1 session pane process snapshot birth pid cwd actual panes workspaces
  session=$(printf '%s' "$receipt" | jq -er .session) || return 1
  pane=$(printf '%s' "$receipt" | jq -er .pane) || return 1
  snapshot=$(fm_backend_herdr_cli "$session" pane get "$pane") || return 1
  process=$(fm_backend_herdr_cli "$session" pane process-info --pane "$pane") || return 1
  pid=$(printf '%s' "$process" | jq -er --arg pane "$pane" '
    .result.process_info | select(.pane_id == $pane) | .shell_pid | select(type == "number" and . > 0)') || return 1
  birth=$(fm_pid_identity "$pid") || return 1
  jq -en --argjson expected "$receipt" --argjson now "$snapshot" --argjson pid "$pid" --arg birth "$birth" '
    $now.result.pane as $p | $p.pane_id == $expected.pane and $p.tab_id == $expected.tab
    and $p.workspace_id == $expected.workspace and $p.terminal_id == $expected.terminal
    and $pid == $expected.shell_pid and $birth == $expected.shell_identity' >/dev/null || return 1
  case "$(uname -s)" in
    Linux) cwd=$(readlink "/proc/$pid/cwd") || return 1 ;;
    *) return 1 ;;
  esac
  actual=$(CDPATH='' cd -- "$cwd" 2>/dev/null && pwd -P) || return 1
  [ "$actual" = "$(printf '%s' "$receipt" | jq -er .worktree)" ] || return 1
  jq -en --argjson expected "$receipt" --argjson now "$snapshot" '
    $now.result.pane | .cwd == $expected.worktree and .foreground_cwd == $expected.worktree' >/dev/null || return 1
  panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$(printf '%s' "$receipt" | jq -r .workspace)") || return 1
  jq -en --argjson expected "$receipt" --argjson panes "$panes" '
    $panes.result.panes | length == 1 and .[0].pane_id == $expected.pane
    and .[0].terminal_id == $expected.terminal' >/dev/null || return 1
  workspaces=$(fm_backend_herdr_cli "$session" workspace list) || return 1
  jq -en --argjson e "$receipt" --argjson list "$workspaces" '
    $list.result.workspaces as $w |
    [$w[] | select(.worktree.checkout_path == $e.worktree)] as $matches |
    ($matches | length) == 1 and $matches[0].workspace_id == $e.workspace
    and $matches[0].pane_count == 1 and $matches[0].tab_count == 1
    and $matches[0].worktree.repo_root == $e.project
    and $matches[0].worktree.repo_key == $e.common_git
    and $matches[0].worktree.is_linked_worktree == true
    and ([$w[] | select(.worktree.checkout_path == $e.project)] as $parents |
      ($parents | length) == 1 and $parents[0].workspace_id == $e.parent_workspace
      and $parents[0].worktree.repo_key == $e.common_git
      and $parents[0].worktree.is_linked_worktree == false)' >/dev/null
}

fm_backend_herdr_enrollment_free() { # <receipt JSON>
  local receipt=$1 session pane state native
  session=$(printf '%s' "$receipt" | jq -er .session) || return 1
  pane=$(printf '%s' "$receipt" | jq -er .pane) || return 1
  state=$(fm_backend_herdr_pane_agent_state "$session" "$pane") || return 1
  case "$state" in no-agent|stale-agent) ;; *) return 1 ;; esac
  [ "$(fm_backend_herdr_pane_process_state "$session" "$pane")" = shell ] || return 1
  native=$(fm_backend_herdr_cli "$session" worktree list --cwd "$(printf '%s' "$receipt" | jq -r .project)") || return 1
  jq -en --argjson e "$receipt" --argjson native "$native" '
    [$native.result.worktrees[] | select(.path == $e.worktree)] as $matches |
    ($matches | length) == 1 and $matches[0].open_workspace_id == $e.workspace
    and $matches[0].is_linked_worktree == true and $matches[0].is_prunable == false
    and $matches[0].is_bare == false' >/dev/null || return 1
  fm_backend_herdr_enrollment_identity "$receipt"
}

fm_backend_herdr_enrollment_source() { # <receipt JSON> [allow-dirty]
  python3 - "$1" "${2:-}" <<'PY'
import json, os, subprocess, sys
r = json.loads(sys.argv[1])
def git(path, *args):
    return subprocess.check_output(['git', '-C', path, *args], stderr=subprocess.DEVNULL).decode().strip()
try:
    for key in ('project', 'worktree', 'common_git'):
        if not os.path.isabs(r[key]) or os.path.realpath(r[key]) != r[key]:
            raise ValueError('noncanonical '+key)
    wt, parent = r['worktree'], r['project']
    if wt == parent or git(wt, 'rev-parse', '--show-toplevel') != wt:
        raise ValueError('not a linked worktree root')
    if os.path.realpath(git(wt, 'rev-parse', '--path-format=absolute', '--git-common-dir')) != r['common_git']:
        raise ValueError('common Git mismatch')
    if os.path.realpath(git(parent, 'rev-parse', '--absolute-git-dir')) != r['common_git']:
        raise ValueError('project is not the canonical Git parent')
    if sys.argv[2] != 'allow-dirty':
        if git(wt, 'rev-parse', 'HEAD') != r['head'] or git(wt, 'symbolic-ref', '--short', 'HEAD') != r['branch']:
            raise ValueError('source head/branch changed')
        if git(wt, 'status', '--porcelain', '--untracked-files=all'):
            raise ValueError('retained source is not clean')
except (KeyError, ValueError, OSError, subprocess.CalledProcessError) as e:
    raise SystemExit('retained source refused: '+str(e))
PY
}
