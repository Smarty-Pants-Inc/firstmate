#!/usr/bin/env bash
# Enroll one retained, agent-free Herdr endpoint without launching, allocating,
# moving, renaming, fetching, or changing its source/history.
# Usage: FM_HOME=/owning/home fm-enroll-herdr.sh <task-id> --expect <receipt.json>
#
# The private receipt supplies expected facts, not task metadata. Required keys:
# schema="fm-herdr-enrollment.v1", home, task, project, worktree, common_git,
# head (full commit), branch, session, workspace, tab, pane, terminal, shell_pid,
# shell_identity (fm_pid_identity), parent_workspace, model, effort, mode, yolo,
# pi_session_file, pi_session_id, and claim_homes (complete same-host custody scope).
# All paths are absolute/physical. The owning home must be in claim_homes.
# The receiving owner supplies every same-host home which can claim this source
# or endpoint; no global filesystem/remote-home discovery is inferred. Each
# supplied home's task-set lock is held through publication. Missing/unsafe
# homes, unreadable metadata and duplicate claims refuse. This bootstrap path
# supports Pi ship tasks with tasks-axi only; it does not change backend policy.
#
# Normal metadata and tasks-axi dispatch use fm-backlog-transition-lib, under
# ordinary spawn/control/meta and shared session locks. The record is published
# first, so native bootstrap can reconcile a crash before tasks-axi start, just
# as for spawn. Failed dispatch removes provisional metadata and empty inbox;
# a committed In-flight row always retains its paired metadata. No endpoint
# cleanup is permitted here. Resume afterwards through fm-control relaunch;
# the recorded exact Pi history is validated and passed by fm-spawn.
set -u
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
case "${1:-}" in -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/, ""); print; next} {exit}' "$0"; exit 0 ;; esac
[ -n "${FM_HOME:-}" ] || { echo 'error: explicit FM_HOME is required' >&2; exit 2; }
[ "$#" = 3 ] && [ "$2" = --expect ] || { echo 'error: expected <task-id> --expect <receipt.json>' >&2; exit 2; }
ID=$1
EXPECT=$3
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
fm_backend_source herdr || exit 1
# shellcheck source=bin/backends/herdr-enroll.sh
. "$SCRIPT_DIR/backends/herdr-enroll.sh"
die() { echo "error: enrollment refused: $*" >&2; exit 1; }
fm_task_id_creation_valid "$ID" || die 'invalid task id'
HOME_REAL=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || die 'owning home unavailable'
export FM_HOME="$HOME_REAL"
STATE="$HOME_REAL/state"
DATA="$HOME_REAL/data"
CONFIG="$HOME_REAL/config"
for directory in "$STATE" "$DATA" "$CONFIG"; do
  fm_backlog_directory_present "$directory" 'owning-home directory' || die "$FM_BACKLOG_TRANSITION_ERROR"
done
for name in FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE; do
  [ -z "${!name:-}" ] || die "$name is unsupported for retained enrollment"
done
RECEIPT=$(python3 - "$EXPECT" "$HOME_REAL" "$ID" <<'PY'
import json, os, re, stat, sys
path, home, task = sys.argv[1:]
try:
    s = os.lstat(path)
    if not stat.S_ISREG(s.st_mode) or s.st_nlink != 1 or s.st_uid != os.getuid():
        raise ValueError('expected receipt must be an owned single-link regular file')
    def unique(pairs):
        result = {}
        for k,v in pairs:
            if k in result: raise ValueError('duplicate receipt key '+k)
            result[k] = v
        return result
    with open(path) as f: r = json.load(f, object_pairs_hook=unique)
    fields = 'schema home task project worktree common_git head branch session workspace tab pane terminal shell_identity parent_workspace model effort mode yolo pi_session_file pi_session_id'.split()
    if set(r) != set(fields+['shell_pid','claim_homes']): raise ValueError('receipt keys do not match the documented schema')
    for key in fields:
        if not isinstance(r[key], str) or not r[key] or any(ord(c)<32 or ord(c)==127 for c in r[key]):
            raise ValueError('invalid '+key)
    if r['schema'] != 'fm-herdr-enrollment.v1' or r['home'] != home or r['task'] != task: raise ValueError('foreign receipt')
    if r['mode'] not in ('no-mistakes','direct-PR','local-only') or r['yolo'] not in ('on','off'): raise ValueError('invalid delivery contract')
    if '/' not in r['model'] or r['effort'] not in ('low','medium','high','xhigh','max'): raise ValueError('explicit model/effort required')
    if not re.fullmatch('[0-9a-f]{40}', r['head']): raise ValueError('full source commit required')
    if type(r['shell_pid']) is not int or r['shell_pid'] <= 0: raise ValueError('invalid shell pid')
    for k in ('session','workspace','parent_workspace','terminal'):
        if not re.fullmatch('[A-Za-z0-9._-]+', r[k]): raise ValueError('invalid '+k)
    if not r['pane'].startswith(r['workspace']+':p') or not r['tab'].startswith(r['workspace']+':t'): raise ValueError('inconsistent pane/tab/workspace')
    homes = r['claim_homes']
    if not isinstance(homes,list) or not homes or home not in homes or len(homes)!=len(set(homes)): raise ValueError('explicit unique claim_homes including owner required')
    for h in homes:
        if not isinstance(h,str) or not os.path.isabs(h) or os.path.realpath(h)!=h or any(ord(c)<32 for c in h): raise ValueError('invalid claim home')
        for child in ('state','data'):
            s = os.lstat(os.path.join(h,child))
            if not stat.S_ISDIR(s.st_mode): raise ValueError('unavailable or symlinked claim home')
    print(json.dumps(r,sort_keys=True,separators=(',',':')))
except (OSError,ValueError,TypeError) as e: raise SystemExit('invalid enrollment expectation: '+str(e))
PY
) || die 'invalid expected identity'
field() { printf '%s' "$RECEIPT" | jq -er --arg key "$1" '.[$key]'; }
LOCKS=()
TMP=
PUBLISHED=0
COMMITTED=0
INBOX_CREATED=0
INBOX=$(fm_task_inbox_dir "$STATE" "$ID")
META="$STATE/$ID.meta"
cleanup() {
  local rc=$? i
  if [ "$PUBLISHED" = 1 ] && [ "$COMMITTED" = 0 ]; then
    # An interrupted/failed tasks-axi response may already have committed.
    if fm_backlog_row_probe "$DATA" "$ID"; then
      case "$FM_BACKLOG_ROW_STATE" in
        in_flight\ *)
          echo 'enrollment metadata retained with verified In-flight row; inspect before retry' >&2
          COMMITTED=1 ;;
        *) fm_backlog_atomic_transition rollback "$META" "$SCRIPT_DIR/fm-busy-event.sh" "$STATE" "$ID" '' || rc=1 ;;
      esac
    elif [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
      fm_backlog_atomic_transition rollback "$META" "$SCRIPT_DIR/fm-busy-event.sh" "$STATE" "$ID" '' || rc=1
    else
      echo 'dispatch outcome is unreadable; enrollment metadata and inbox retained for reconciliation' >&2
      COMMITTED=1
    fi
  fi
  if [ "$INBOX_CREATED" = 1 ] && [ "$COMMITTED" = 0 ]; then
    rmdir "$INBOX/handled" "$INBOX" 2>/dev/null || true
  fi
  [ -z "$TMP" ] || rm -f -- "$TMP"
  for ((i=${#LOCKS[@]}-1; i>=0; i--)); do fm_lock_release "${LOCKS[$i]}" || rc=1; done
  return "$rc"
}
trap cleanup EXIT
lock() { fm_lock_try_acquire "$1" || die "busy lifecycle lock: $1"; LOCKS+=("$1"); }
while IFS= read -r home; do lock "$(fm_task_set_lock_path "$home/state")"; done < <(printf '%s' "$RECEIPT" | jq -r '.claim_homes | sort[]')
lock "$STATE/.spawn-$ID.lock"
lock "$STATE/.control-$ID.lock"
lock "$(fm_meta_lock_path "$META")"
SESSION_LOCK=$(fm_backend_herdr_presentation_session_lock_path "$(field session)") || die 'native session/socket identity is unavailable'
lock "$SESSION_LOCK"
while IFS= read -r home; do
  for record in "$home/state/"*.meta; do
    [ -e "$record" ] || [ -L "$record" ] || continue
    [ "$record" != "$META" ] || continue
    lock "$(fm_meta_lock_path "$record")"
  done
done < <(printf '%s' "$RECEIPT" | jq -r '.claim_homes | sort[]')
for path in "$META" "$STATE/$ID.backlog-close" "$STATE/$ID.control-relaunch" "$STATE/$ID.herdr-presentation" "$INBOX"; do
  [ ! -e "$path" ] && [ ! -L "$path" ] || die "existing task artifact: $path"
done
fm_backlog_transition_applies "$CONFIG" "$DATA" ship || die 'retained enrollment requires the native tasks-axi backlog gate'
fm_backlog_row_probe "$DATA" "$ID" || die "task unavailable: $FM_BACKLOG_ROW_ERROR"
fm_backlog_row_dispatchable "$FM_BACKLOG_ROW_STATE" || die "task is not eligible: $FM_BACKLOG_ROW_STATE"
BRIEF="$DATA/$ID/brief.md"
fm_backlog_record_present "$BRIEF" 'task brief' "$DATA" || die "$FM_BACKLOG_TRANSITION_ERROR"
fm_brief_task_content_valid "$BRIEF" || die 'task brief is not complete'
fm_brief_task_placeholders_present "$BRIEF" && die 'task brief still has placeholders'
ROW=$(fm_backlog_row_show "$DATA" "$ID") || die 'task cannot be read'
[ "$(printf '%s\n' "$ROW" | awk '/^  kind:/{print $2}')" = ship ] || die 'only native ship tasks are supported'
fm_backend_herdr_enrollment_source "$RECEIPT" || die 'source identity changed'
SID=$("$SCRIPT_DIR/fm-pi-session-check.sh" "$(field pi_session_file)" "$(field worktree)" "$(field pi_session_id)") || die 'exact Pi history is not stopped and eligible'
# Every supplied home is locked; scan actual native records, not labels.
if ! python3 - "$RECEIPT" <<'PY'
import json, os, pathlib, stat, sys
r=json.loads(sys.argv[1])
try:
    for home in r['claim_homes']:
        for p in pathlib.Path(home,'state').glob('*.meta'):
            s=p.lstat()
            if not stat.S_ISREG(s.st_mode) or s.st_nlink!=1: raise ValueError('unsafe task record '+str(p))
            values={}
            for line in p.read_text().splitlines():
                key,sep,value=line.partition('=')
                if sep:
                    if key in values: raise ValueError('ambiguous task record '+str(p))
                    values[key]=value
            if any(not values.get(k) for k in ('window','worktree','kind')):
                raise ValueError('incomplete task record '+str(p))
            if p.stem==r['task'] or values.get('endpoint_task_id')==r['task']:
                raise ValueError('task already claimed by '+str(p))
            if (values.get('window')==r['session']+':'+r['pane'] or
                (values.get('herdr_session')==r['session'] and values.get('herdr_workspace_id')==r['workspace'])):
                raise ValueError('endpoint already claimed by '+str(p))
            if values.get('herdr_enrollment'):
                prior=json.loads(values['herdr_enrollment'])
                if prior.get('session')==r['session'] and prior.get('terminal')==r['terminal']:
                    raise ValueError('terminal already enrolled by '+str(p))
            for key in ('worktree','home'):
                if values.get(key) and os.path.realpath(values[key])==r['worktree']:
                    raise ValueError('worktree already claimed by '+str(p))
except (OSError,ValueError) as e: raise SystemExit(str(e))
PY
then
  die 'retained task/source/endpoint is claimed or unreadable'
fi
fm_backend_herdr_enrollment_free "$RECEIPT" || die 'native pane/process/cwd/membership is not exact and agent-free'
mkdir -m 700 "$INBOX" || die 'cannot prepare native inbox'
INBOX_CREATED=1
mkdir -m 700 "$INBOX/handled" || die 'cannot prepare inbox acknowledgement directory'
TMP=$(mktemp "$STATE/.$ID.enroll.XXXXXX") || die 'cannot stage metadata'
{
  printf 'window=%s:%s\n' "$(field session)" "$(field pane)"
  printf 'endpoint_task_id=%s\nworktree=%s\nproject=%s\n' "$ID" "$(field worktree)" "$(field project)"
  printf 'harness=pi\nkind=ship\nmode=%s\nyolo=%s\n' "$(field mode)" "$(field yolo)"
  printf 'model=%s\neffort=%s\nbackend=herdr\n' "$(field model)" "$(field effort)"
  printf 'spawn_gen=e%s.%s.%s\n' "$(date +%s)" "$$" "$RANDOM"
  printf 'herdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\n' "$(field session)" "$(field workspace)" "$(field tab)" "$(field pane)"
  printf 'herdr_parent_workspace_id=%s\nherdr_enrollment=%s\n' "$(field parent_workspace)" "$RECEIPT"
  printf 'pi_session_file=%s\npi_session_id=%s\n' "$(field pi_session_file)" "$SID"
} > "$TMP" || die 'cannot write staged metadata'
fm_backend_herdr_enrollment_source "$RECEIPT" || die 'source changed before publication'
fm_backend_herdr_enrollment_free "$RECEIPT" || die 'native identity changed before publication'
fm_backlog_atomic_transition publish "$TMP" "$META" 'task record' "$STATE" || die "$FM_BACKLOG_TRANSITION_ERROR"
TMP=
PUBLISHED=1
fm_backlog_atomic_transition dispatch "$META" "$DATA" "$ID" "$STATE" || die "$FM_BACKLOG_TRANSITION_ERROR"
COMMITTED=1
fm_backlog_row_probe "$DATA" "$ID" && [ "$FM_BACKLOG_ROW_STATE" = 'in_flight no no' ] || die 'committed task did not read back In flight; metadata retained'
printf 'enrolled %s window=%s:%s worktree=%s history=%s; no agent launched\n' "$ID" "$(field session)" "$(field pane)" "$(field worktree)" "$SID"
