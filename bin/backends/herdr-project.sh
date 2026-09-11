#!/usr/bin/env bash
# Native worktree membership for a validated, single-pane projected Work.
# Called by fm-spawn only after Treehouse and Git isolation validation, while
# holding the existing presentation session lock. No worktree allocator here.
# Return 2 when the native capability is absent; other failures stop the spawn
# without cleaning an ambiguous native membership result. There is no safe
# membership-only detach API, and worktree.remove is NEVER a rollback.

fm_backend_herdr_project_paths() { # <linked-worktree>
  python3 - "$1" <<'PY'
import json, os, subprocess, sys
wt = os.path.realpath(sys.argv[1])
def git(path, *args):
    return subprocess.check_output(['git', '-C', path, *args], stderr=subprocess.DEVNULL).decode().rstrip('\n')
try:
    if os.path.realpath(git(wt, 'rev-parse', '--show-toplevel')) != wt:
        raise ValueError('not a worktree root')
    records = git(wt, 'worktree', 'list', '--porcelain', '-z').split('\0\0')
    entries = [r.split('\0') for r in records if r]
    if not entries[0][0].startswith('worktree '):
        raise ValueError('missing primary worktree')
    parent = os.path.realpath(entries[0][0][len('worktree '):])
    matching = [e for e in entries if e[0] == 'worktree '+wt]
    if parent == wt or len(matching) != 1 or any(x == 'bare' or x.startswith('prunable') for x in matching[0]):
        raise ValueError('not one present linked worktree')
    common = os.path.realpath(git(wt, 'rev-parse', '--path-format=absolute', '--git-common-dir'))
    if os.path.realpath(git(parent, 'rev-parse', '--absolute-git-dir')) != common:
        raise ValueError('primary/common Git mismatch')
    print(json.dumps(dict(parent=parent, worktree=wt)))
except (ValueError, OSError, subprocess.CalledProcessError) as e:
    raise SystemExit('cannot establish native worktree parent: '+str(e))
PY
}

fm_backend_herdr_project_adopt() { # <session> <worktree> <workspace> <pane>
  local session=$1 wt=$2 workspace=$3 pane=$4 paths parent list panes native before after out schema
  schema=$(fm_backend_herdr_cli "$session" api schema --json 2>/dev/null) || return 2
  printf '%s' "$schema" | jq -e '
    any(.schemas.request.oneOf[]?; .properties.method.const == "worktree.open")' >/dev/null || return 2
  paths=$(fm_backend_herdr_project_paths "$wt") || return 1
  parent=$(printf '%s' "$paths" | jq -er .parent) || return 1
  wt=$(printf '%s' "$paths" | jq -er .worktree) || return 1
  list=$(fm_backend_herdr_cli "$session" workspace list) || return 1
  printf '%s' "$list" | jq -e --arg workspace "$workspace" --arg wt "$wt" '
    ([.result.workspaces[] | select(.workspace_id == $workspace and .pane_count == 1 and .tab_count == 1)] | length) == 1
    and ([.result.workspaces[] | select(.worktree.checkout_path == $wt and .workspace_id != $workspace)] | length) == 0' >/dev/null || return 1
  panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$workspace") || return 1
  printf '%s' "$panes" | jq -e --arg pane "$pane" --arg wt "$wt" '
    .result.panes | length == 1 and .[0].pane_id == $pane and .[0].cwd == $wt' >/dev/null || return 1
  # Native lookup, not labels or a guessed workspace ID. Require the server to
  # select the existing task workspace before any membership mutation.
  native=$(fm_backend_herdr_cli "$session" worktree list --cwd "$parent") || return 1
  printf '%s' "$native" | jq -e --arg wt "$wt" --arg workspace "$workspace" '
    [.result.worktrees[] | select(.path == $wt and .is_linked_worktree == true
      and .is_prunable == false and .is_bare == false and .open_workspace_id == $workspace)]
    | length == 1' >/dev/null || return 1
  before=$(printf '%s' "$panes" | jq -ce '.result.panes[0] | {pane_id,tab_id,workspace_id,terminal_id,cwd}') || return 1
  # No trust flag, label rewrite, branch selection, new allocator, or retry.
  out=$(fm_backend_herdr_cli "$session" worktree open --cwd "$parent" --path "$wt" --no-focus) || return 1
  printf '%s' "$out" | jq -e --arg workspace "$workspace" --arg pane "$pane" --arg wt "$wt" --arg parent "$parent" '
    .result.already_open == true and .result.workspace.workspace_id == $workspace
    and .result.root_pane.pane_id == $pane and .result.worktree.path == $wt
    and .result.workspace.worktree.checkout_path == $wt
    and .result.workspace.worktree.repo_root == $parent
    and .result.workspace.worktree.is_linked_worktree == true' >/dev/null || return 1
  after=$(fm_backend_herdr_cli "$session" pane get "$pane" | jq -ce '.result.pane | {pane_id,tab_id,workspace_id,terminal_id,cwd}') || return 1
  [ "$before" = "$after" ] || return 1
}
