#!/usr/bin/env bash
# Retained enrollment: real Git, kernel process identity, native tasks-axi,
# durable metadata/inbox; fake read-only Herdr API refuses every mutation.
set -eu
# Every recovery case belongs to this fixture, including the received command.
# Do not inherit another owning home's source or private-directory overrides.
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-enroll-herdr)
PID=
HISTORY_PID=
TASK_TMP_CREATED=0
cleanup() {
  local pid
  for pid in "$PID" "$HISTORY_PID"; do [ -z "$pid" ] || { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }; done
  [ "$TASK_TMP_CREATED" = 0 ] || rm -rf /tmp/fm-retained
  fm_test_cleanup
}
trap cleanup EXIT
OUT="$TMP_ROOT/result"
if env -u FM_HOME "$ROOT/bin/fm-enroll-herdr.sh" retained >"$OUT" 2>&1; then fail 'implicit home accepted'; else rc=$?; fi
[ "$rc" = 2 ] || fail 'wrong explicit-home refusal exit code'
grep -q FM_HOME "$OUT" || fail 'missing explicit-home diagnostic'
pass 'retained enrollment requires an explicit owning home'
command -v tasks-axi >/dev/null || fail 'native tasks-axi is required'
[ "$(uname -s)" = Linux ] || { pass 'retained admission is Linux-only'; exit 0; }
BASE_PATH=$PATH
HOME_FIXTURE="$TMP_ROOT/home"
PEER="$TMP_ROOT/peer"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
mkdir -p "$HOME_FIXTURE"/{state,data/retained,config} "$PEER"/{state,data}
printf 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n' > "$HOME_FIXTURE/.tasks.toml"
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$HOME_FIXTURE/data/backlog.md"
unset TASKS_AXI_BACKEND || true
tasks-axi add retained 'Retained source admission' --kind ship --file "$HOME_FIXTURE/data/backlog.md" >/dev/null
printf "# Task\n## Captain's intent\nPreserve the existing source.\n## Firstmate spec\nVerify enrollment without terminal mutation.\n" > "$HOME_FIXTURE/data/retained/brief.md"
fm_git_init_commit "$TMP_ROOT/project"
git -C "$TMP_ROOT/project" worktree add --quiet -b retained "$TMP_ROOT/worktree"
mkfifo "$TMP_ROOT/input"
bash -c 'cd "$1"; exec 3<>"$2"; printf ready > "$3"; read -r unused <&3' shell "$TMP_ROOT/worktree" "$TMP_ROOT/input" "$TMP_ROOT/ready" &
PID=$!
for _ in {1..100}; do [ ! -f "$TMP_ROOT/ready" ] || break; sleep .01; done
[ -f "$TMP_ROOT/ready" ] || fail 'fixture shell did not start'
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
BIRTH=$(fm_pid_identity "$PID")
HEAD=$(git -C "$TMP_ROOT/worktree" rev-parse HEAD)
export ENROLL_FIXTURE="$TMP_ROOT"
python3 - "$TMP_ROOT" "$PID" "$BIRTH" "$HEAD" <<'PY'
import json, pathlib, socket, sys
root,pid,birth,head=sys.argv[1:]; p=pathlib.Path(root)
def write(name,obj): (p/name).write_text(json.dumps(obj)+'\n')
sock=socket.socket(socket.AF_UNIX); sock.bind(root+'/api.sock'); sock.close()
write('sessions.json',dict(sessions=[dict(name='enroll-test',running=True,socket_path=root+'/api.sock')]))
r=dict(schema='fm-herdr-enrollment.v1',home=root+'/home',task='retained',project=root+'/project',worktree=root+'/worktree',common_git=root+'/project/.git',head=head,branch='retained',session='enroll-test',workspace='w2',tab='w2:t1',pane='w2:p1',terminal='term_retained',shell_pid=int(pid),shell_identity=birth,parent_workspace='w1',model='cliproxyapi/gpt-6-astra',effort='high',mode='direct-PR',yolo='off',pi_session_file=root+'/history.jsonl',pi_session_id='c2679539-b3bb-4e0d-a724-2a0e276777a3',claim_homes=[root+'/home',root+'/peer'])
write('expect.json',r)
write('history.jsonl',dict(type='session',version=3,id='c2679539-b3bb-4e0d-a724-2a0e276777a3',cwd=r['worktree']))
pane=dict(pane_id=r['pane'],tab_id=r['tab'],workspace_id=r['workspace'],terminal_id=r['terminal'],cwd=r['worktree'],foreground_cwd=r['worktree'])
write('pane.json',dict(result=dict(type='pane',pane=pane)))
write('panes.json',dict(result=dict(panes=[pane])))
write('process.json',dict(result=dict(type='pane_process_info',process_info=dict(pane_id=r['pane'],shell_pid=int(pid),foreground_processes=[dict(pid=int(pid),name='bash',argv=['/bin/bash'],cmdline='/bin/bash')]))))
w=[]
for ws,path,linked in [('w1',r['project'],False),('w2',r['worktree'],True)]:
    w.append(dict(workspace_id=ws,pane_count=1,tab_count=1,worktree=dict(checkout_path=path,repo_key=r['common_git'],repo_root=r['project'],is_linked_worktree=linked)))
write('workspaces.json',dict(result=dict(workspaces=w)))
write('native.json',dict(result=dict(worktrees=[dict(path=r['worktree'],open_workspace_id='w2',is_linked_worktree=True,is_prunable=False,is_bare=False)])))
PY
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$ENROLL_FIXTURE/api-calls"
case "$1 ${2:-}" in
  '--version ') printf 'herdr 0.9.0\n'; exit 0 ;;
  'status --json') printf '{"server":{"running":true,"compatible":true,"version":"0.9.0"}}\n'; exit 0 ;;
  'session list') file=sessions.json ;;
  'pane get')
    if [ -f "$ENROLL_FIXTURE/pane-get-failed" ]; then cat "$ENROLL_FIXTURE/pane.json"; exit 9; fi
    file=pane.json ;;
  'pane current') printf '{"error":{"code":"pane_not_found"}}\n'; exit 1 ;;
  'tab get') jq '{result:{tab:(.result.pane | {tab_id,workspace_id,label:"fm-retained",pane_count:1})}}' "$ENROLL_FIXTURE/pane.json"; exit 0 ;;
  'pane list') file=panes.json ;;
  'pane process-info')
    if [ -f "$ENROLL_FIXTURE/live-agent" ]; then
      jq '.result.process_info.foreground_processes[0] |= (.name="pi" | .argv=["pi"] | .cmdline="pi")' "$ENROLL_FIXTURE/process.json"
      exit 0
    fi
    file=process.json ;;
  'workspace list') file=workspaces.json ;;
  'worktree list') file=native.json ;;
  'agent get')
    if [ -f "$ENROLL_FIXTURE/live-agent" ]; then printf '{"result":{"agent":{"agent":"pi","agent_status":"idle"}}}\n';
    else printf '{"error":{"code":"agent_not_found"}}\n'; fi
    exit 0 ;;
  'pane run'|'pane send-text'|'pane send-keys'|'pane read')
    [ -f "$ENROLL_FIXTURE/allow-launch" ] || { echo 'mutation before recovery authorization' >&2; exit 91; }
    case "$1 $2" in
      'pane read') printf '╭────╮\n│    │\n╰────╯\n' ;;
      'pane send-text')
        case "${4:-}" in
          *'encode launch-brief'*) printf '%s\n' "$4" > "$ENROLL_FIXTURE/launch"; touch "$ENROLL_FIXTURE/live-agent" ;;
        esac ;;
    esac
    exit 0 ;;
  *) echo "unexpected API mutation: $*" >&2; exit 91 ;;
esac
cat "$ENROLL_FIXTURE/$file"
SH
chmod +x "$FAKEBIN/herdr"
run_enroll() {
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_BACKEND_HERDR_CLIENT_SESSION -u FM_BACKEND_HERDR_BIN \
    FM_HOME="$HOME_FIXTURE" PATH="$FAKEBIN:$BASE_PATH" \
    "$ROOT/bin/fm-enroll-herdr.sh" retained --expect "${1:-$TMP_ROOT/expect.json}" > "$OUT" 2>&1
}
refuse() {
  if run_enroll "${2:-$TMP_ROOT/expect.json}"; then fail "accepted $1"; fi
  [ ! -e "$HOME_FIXTURE/state/retained.meta" ] || { read_result; fail "$1 published metadata"; }
  [ ! -e "$HOME_FIXTURE/state/retained.inbox" ] || fail "$1 left an inbox"
  pass "refuses $1 without enrollment"
}
read_result() { while IFS= read -r line; do printf '%s\n' "$line" >&2; done < "$OUT"; }
mutate() { jq "$1" "$TMP_ROOT/expect.json" > "$TMP_ROOT/bad.json"; }
mutate '.home = "/foreign"'; refuse 'foreign home' "$TMP_ROOT/bad.json"
mutate '.shell_identity = "wrong-incarnation"'; refuse 'reused PID' "$TMP_ROOT/bad.json"
mutate '.terminal = "term_other"'; refuse 'wrong terminal' "$TMP_ROOT/bad.json"
mutate '.tab = "w2:t2"'; refuse 'wrong tab' "$TMP_ROOT/bad.json"
mutate '.parent_workspace = "w9"'; refuse 'foreign Git parent workspace' "$TMP_ROOT/bad.json"
mutate '.common_git = "/wrong/common.git"'; refuse 'wrong common Git' "$TMP_ROOT/bad.json"
mutate '.claim_homes += ["/missing-enrollment-home"]'; refuse 'unavailable claim scope' "$TMP_ROOT/bad.json"
mutate '.pi_session_file += ".missing"'; refuse 'missing exact history' "$TMP_ROOT/bad.json"
mutate '.pi_session_id = "3e6cc5f7-cb6c-4349-9213-48ed7b03f1f2"'; refuse 'wrong expected native UUID' "$TMP_ROOT/bad.json"
cp "$TMP_ROOT/history.jsonl" "$TMP_ROOT/history-before"
printf '{"type":"session","version":3,"id":"ambiguous"}\n' > "$TMP_ROOT/history.jsonl"
refuse 'invalid native history'
cp "$TMP_ROOT/history-before" "$TMP_ROOT/history.jsonl"
ln -s "$TMP_ROOT/history.jsonl" "$TMP_ROOT/history-link"
mutate '.pi_session_file |= sub("history.jsonl$"; "history-link")'; refuse 'symlinked history' "$TMP_ROOT/bad.json"
# A default/--continue Pi may advertise no UUID. Its cwd still prevents a
# second history writer. This is an inert test sleep, never another agent.
(cd "$TMP_ROOT/worktree"; exec -a pi sleep 120) &
HISTORY_PID=$!
for _ in {1..100}; do [ "$(ps -p "$HISTORY_PID" -o comm=)" != sleep ] || break; sleep .01; done
refuse 'live runtime at the retained cwd'
kill "$HISTORY_PID"; wait "$HISTORY_PID" 2>/dev/null || true
HISTORY_PID=
cmp "$TMP_ROOT/history-before" "$TMP_ROOT/history.jsonl" || fail 'history changed during refused admission'
printf 'window=elsewhere:w9:p1\nworktree=%s\nkind=ship\n' "$TMP_ROOT/worktree" > "$PEER/state/other.meta"
refuse 'peer source claim'; rm "$PEER/state/other.meta"
printf 'window=enroll-test:w2:p1\nworktree=/other\nkind=ship\n' > "$PEER/state/other.meta"
refuse 'peer endpoint claim'; rm "$PEER/state/other.meta"
printf 'window=elsewhere:w9:p1\nworktree=/other\nkind=ship\n' > "$PEER/state/retained.meta"
refuse 'peer task claim'; rm "$PEER/state/retained.meta"
for home in "$HOME_FIXTURE" "$PEER"; do
  route_state="$home/state/parent-route"
  mkdir -p "$route_state"
  for claim in task source endpoint; do
    record="$route_state/other.meta"
    window=elsewhere:w9:p1
    worktree="$home"
    case "$claim" in
      task) record="$route_state/retained.meta" ;;
      source) worktree="$TMP_ROOT/worktree" ;;
      endpoint) window=enroll-test:w2:p1 ;;
    esac
    printf 'window=%s\nworktree=%s\nkind=secondmate\nhome=%s\n' "$window" "$worktree" "$home" > "$record"
    cp "$record" "$TMP_ROOT/route-before"
    refuse "parent-route $claim claim"
    grep -q 'already claimed by' "$OUT" || { read_result; fail 'parent-route conflict was not scanned'; }
    cmp "$TMP_ROOT/route-before" "$record" || fail 'enrollment changed a parent-route claim'
    rm "$record"
  done
done
route_state="$PEER/state/parent-route"
record="$route_state/peer-route.meta"
printf 'window=elsewhere:w9:p1\nworktree=%s\nkind=secondmate\nhome=%s\n' "$PEER" "$PEER" > "$record"
cp "$record" "$TMP_ROOT/route-before"
for lock_path in "$(fm_task_set_lock_path "$route_state")" "$route_state/.control-peer-route.lock" "$(fm_meta_lock_path "$record")"; do
  fm_lock_try_acquire "$lock_path" || fail 'could not hold fixture custody lock'
  refuse 'busy parent-route custody'
  grep -Fq "busy lifecycle lock: $lock_path" "$OUT" || { read_result; fail 'enrollment missed an existing parent-route lock'; }
  fm_lock_release "$lock_path" || fail 'could not release fixture custody lock'
done
printf 'window=ambiguous:w9:p2\n' >> "$record"
refuse 'ambiguous parent-route record'
grep -q 'ambiguous task record' "$OUT" || { read_result; fail 'ambiguous parent-route record was not read'; }
cp "$TMP_ROOT/route-before" "$record"
ln -s "$record" "$route_state/link.meta"
refuse 'symlinked parent-route record'
rm "$route_state/link.meta"
mv "$route_state" "$PEER/route-before"
ln -s "$PEER/route-before" "$route_state"
refuse 'symlinked parent-route directory'
rm "$route_state"
mv "$PEER/route-before" "$route_state"
pass 'custody includes same-host parent routes and their task-set, control and metadata locks'
# Native/API contradictions, including missing registration with a live worker.
for spec in \
  'pane.json|.result.pane.foreground_cwd = "/wrong"' \
  'pane.json|.result.pane.cwd = "/wrong"' \
  'native.json|del(.result.worktrees[0].open_workspace_id)' \
  'native.json|.result.worktrees += .result.worktrees' \
  'native.json|.result.worktrees += [.result.worktrees[0] | .open_workspace_id = "w9"]' \
  'workspaces.json|.result.workspaces += [.result.workspaces[0] | .workspace_id = "w9"]' \
  'workspaces.json|.result.workspaces += [.result.workspaces[1]]' \
  'process.json|.result.process_info.foreground_processes[0].name = "node" | .result.process_info.foreground_processes[0].argv = ["pi"] | .result.process_info.foreground_processes[0].cmdline = "pi"'; do
  file=${spec%%|*}; expression=${spec#*|}
  cp "$TMP_ROOT/$file" "$TMP_ROOT/saved"
  jq "$expression" "$TMP_ROOT/saved" > "$TMP_ROOT/$file"
  refuse "native contradiction: $file $expression"
  mv "$TMP_ROOT/saved" "$TMP_ROOT/$file"
done
printf change > "$TMP_ROOT/worktree/untracked"
refuse 'dirty source'; rm "$TMP_ROOT/worktree/untracked"
# Real native row eligibility and a failed atomic dispatch.
tasks-axi hold retained --reason 'test decision' --file "$HOME_FIXTURE/data/backlog.md" >/dev/null
refuse 'held native task'
tasks-axi unhold retained --file "$HOME_FIXTURE/data/backlog.md" >/dev/null
REAL_TASKS=$(command -v tasks-axi)
cat > "$FAKEBIN/tasks-axi" <<SH
#!/usr/bin/env bash
[ "\${1:-}" != start ] || exit 74
exec "$REAL_TASKS" "\$@"
SH
chmod +x "$FAKEBIN/tasks-axi"
refuse 'failed tasks-axi dispatch'
rm "$FAKEBIN/tasks-axi"
# A failed response is not proof that the remote/native mutation failed. Keep
# the published record if start committed and its read-back is unavailable.
cat > "$FAKEBIN/tasks-axi" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  start)
    "$REAL_TASKS" "\$@" || exit 73
    touch "$TMP_ROOT/unreadable-row"
    exit 74 ;;
  show) [ ! -f "$TMP_ROOT/unreadable-row" ] || exit 75 ;;
esac
exec "$REAL_TASKS" "\$@"
SH
chmod +x "$FAKEBIN/tasks-axi"
if run_enroll; then fail 'unreadable dispatch claimed success'; fi
[ -f "$HOME_FIXTURE/state/retained.meta" ] || fail 'uncertain dispatch lost the committed record'
[ -d "$HOME_FIXTURE/state/retained.inbox/handled" ] || fail 'uncertain dispatch lost its inbox'
grep -q 'dispatch outcome is unreadable' "$OUT" || { read_result; fail 'uncertain dispatch did not name reconciliation'; }
rm "$FAKEBIN/tasks-axi" "$TMP_ROOT/unreadable-row"
tasks-axi show retained --file "$HOME_FIXTURE/data/backlog.md" | grep -q '^  state: in_flight$' || fail 'lost-response fixture did not commit'
# Reset only this private fixture, not a production enrollment.
rm "$HOME_FIXTURE/state/retained.meta"
rmdir "$HOME_FIXTURE/state/retained.inbox/handled" "$HOME_FIXTURE/state/retained.inbox"
tasks-axi reopen retained --file "$HOME_FIXTURE/data/backlog.md" >/dev/null
pass 'uncertain dispatch preserves metadata/inbox and reports reconciliation rather than success'
run_enroll || { read_result; fail 'valid enrollment failed'; }
cmp "$TMP_ROOT/route-before" "$PEER/state/parent-route/peer-route.meta" || fail 'valid enrollment changed unrelated parent-route ownership'
META="$HOME_FIXTURE/state/retained.meta"
grep -q '^window=enroll-test:w2:p1$' "$META" || fail 'endpoint missing'
grep -q '^model=cliproxyapi/gpt-6-astra$' "$META" || fail 'model pin missing'
grep -q '^effort=high$' "$META" || fail 'effort pin missing'
grep -q '^pi_session_id=c2679539-b3bb-4e0d-a724-2a0e276777a3$' "$META" || fail 'exact history missing'
[ -d "$HOME_FIXTURE/state/retained.inbox/handled" ] || fail 'inbox acknowledgement wiring missing'
tasks-axi show retained --file "$HOME_FIXTURE/data/backlog.md" | grep -q '^  state: in_flight$' || fail 'native task not In flight'
[ "$(git -C "$TMP_ROOT/worktree" rev-parse HEAD)" = "$HEAD" ] || fail 'source changed'
[ "$(fm_pid_identity "$PID")" = "$BIRTH" ] || fail 'retained process changed'
cp "$META" "$TMP_ROOT/meta-before"
if run_enroll; then fail 'duplicate enrollment accepted'; fi
cmp "$TMP_ROOT/meta-before" "$META" || fail 'duplicate enrollment altered metadata'
(
  # shellcheck disable=SC2030 # Keep this identity check's fixture environment isolated.
  export FM_HOME="$HOME_FIXTURE" PATH="$FAKEBIN:$BASE_PATH"
  unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_BACKEND_HERDR_CLIENT_SESSION FM_BACKEND_HERDR_BIN
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source herdr
  . "$ROOT/bin/backends/herdr-enroll.sh"
  receipt=$(cat "$TMP_ROOT/expect.json")
  fm_backend_herdr_enrollment_identity "$receipt" || exit 1
  uname() { printf '%s\n' "$platform"; }
  lsof() { printf 'n%s\n' "$TMP_ROOT/worktree"; }
  for platform in Darwin FreeBSD; do
    if fm_backend_herdr_enrollment_identity "$receipt"; then exit 1; fi
  done
) || fail 'retained identity must support Linux and refuse unsupported platforms'
pass 'retained identity refuses Darwin and other unsupported platforms'
# Native consumer validates the receipt instead of trusting a mutable label.
(
  # shellcheck disable=SC2031 # This check independently sets its own fixture environment.
  export FM_HOME="$HOME_FIXTURE" PATH="$FAKEBIN:$BASE_PATH"
  unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_BACKEND_HERDR_CLIENT_SESSION FM_BACKEND_HERDR_BIN
  # shellcheck source=bin/fm-backend.sh
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_validate_task_endpoint "$META" retained || exit 1
  jq '.result.pane.terminal_id = "term_replacement"' "$TMP_ROOT/pane.json" > "$TMP_ROOT/changed"
  mv "$TMP_ROOT/changed" "$TMP_ROOT/pane.json"
  if fm_backend_validate_task_endpoint "$META" retained >/dev/null 2>&1; then exit 1; fi
) || fail 'retained consumer did not reject changed terminal identity'
pass 'atomic native enrollment preserves source/process/history, rejects duplicates and guards later consumers'
# Exercise the actual existing control -> spawn recovery path, not an extracted
# launch-template assertion. The fake API models transport only; execute its
# received command against a fake Pi to prove argv, native history and home.
jq '.result.pane.terminal_id = "term_retained"' "$TMP_ROOT/pane.json" > "$TMP_ROOT/restored"
mv "$TMP_ROOT/restored" "$TMP_ROOT/pane.json"
cat > "$FAKEBIN/pi" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  --version) printf '0.89.0\n'; exit 0 ;;
  --help) printf 'pi --model MODEL --thinking LEVEL --session FILE\n'; exit 0 ;;
esac
python3 - "$@" <<'PY'
import json, os, pathlib, subprocess, sys
args=sys.argv[1:]; root=pathlib.Path(os.environ['ENROLL_FIXTURE'])
expected = dict(HERDR_PANE_ID='w2:p1', HERDR_TAB_ID='w2:t1', HERDR_WORKSPACE_ID='w2')
assert {key: os.environ.get(key) for key in expected} == expected, 'replacement inherited stale pane identity'
# Startup helpers are child processes of the replacement, not of its old shell.
child = subprocess.check_output([sys.executable, '-c',
    'import json,os,sys; print(json.dumps({k:os.environ.get(k) for k in sys.argv[1:]}))', *expected])
assert {key: json.loads(child).get(key) for key in expected} == expected
assert args[args.index('--model')+1] == 'cliproxyapi/gpt-6-astra'
assert args[args.index('--thinking')+1] == 'high'
assert '--continue' not in args and '--session-id' not in args and '--resume' not in args
if '--session' in args:
    assert args[args.index('--session')+1] == str(root/'history.jsonl')
    assert os.environ['FM_HOME'] == str(root/'home')
    assert 'Read the native task in full' in args[-1]
else:
    assert os.environ['FM_HOME'] == str(root/'worktree')
    assert str(root/'worktree/.pi/extensions/fm-primary-turnend-guard.ts') in args
    assert '# retained charter' in args[-1]
# The actual caller resolver must work without a historical public alias.
source = (root/'source-root').read_text().strip()
workspace = subprocess.check_output(['bash', '-c',
    '. "$1/bin/backends/herdr.sh"; fm_backend_herdr_launcher_identity enroll-test || exit; '
    'printf "%s" "$FM_BACKEND_HERDR_LAUNCHER_WORKSPACE_ID"', 'caller', source], text=True)
assert workspace == 'w2', workspace
assert json.loads((root/'history.jsonl').read_text())['id'] == 'c2679539-b3bb-4e0d-a724-2a0e276777a3'
(root/'received-argv.json').write_text(json.dumps(args))
PY
SH
chmod +x "$FAKEBIN/pi"
fm_test_fake_no_mistakes "$FAKEBIN"
fm_test_fake_gh "$FAKEBIN"
fm_test_fake_gh_axi "$FAKEBIN"
[ ! -e /tmp/fm-retained ] || fail 'reserved test task temporary directory already exists'
TASK_TMP_CREATED=1
cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ENROLL_FIXTURE/allocator-calls"
exit 91
SH
chmod +x "$FAKEBIN/treehouse"
cp "$TMP_ROOT/api-calls" "$TMP_ROOT/api-before-replay"
if env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
  -u FM_BACKEND_HERDR_CLIENT_SESSION -u FM_BACKEND_HERDR_BIN \
  FM_HOME="$HOME_FIXTURE" PATH="$FAKEBIN:$BASE_PATH" FM_SPAWN_NO_GUARD=1 \
  HERDR_ENV=1 HERDR_SESSION=enroll-test HERDR_SOCKET_PATH="$TMP_ROOT/api.sock" \
  HERDR_PANE_ID=w1:p1 HERDR_TAB_ID=w1:t1 HERDR_WORKSPACE_ID=w1 \
  "$ROOT/bin/fm-spawn.sh" retained "$TMP_ROOT/project" --backend herdr --harness pi \
  --model cliproxyapi/gpt-6-astra --effort high --mode direct-PR --yolo off > "$OUT" 2>&1; then
  fail 'fresh spawn replay accepted the enrolled task'
fi
grep -q 'use fm-control retained relaunch' "$OUT" || { read_result; fail 'fresh spawn did not reach retained admission'; }
cmp "$TMP_ROOT/meta-before" "$META" || fail 'fresh spawn replay replaced enrolled metadata'
cmp "$TMP_ROOT/history-before" "$TMP_ROOT/history.jsonl" || fail 'fresh spawn replay replaced exact history'
[ "$(fm_pid_identity "$PID")" = "$BIRTH" ] || fail 'fresh spawn replay replaced the retained process'
[ ! -e "$TMP_ROOT/allocator-calls" ] || fail 'fresh spawn replay submitted another allocation'
tail -n +"$(( $(wc -l < "$TMP_ROOT/api-before-replay") + 1 ))" "$TMP_ROOT/api-calls" > "$TMP_ROOT/replay-calls"
if grep -Eq '^(pane (run|send-|close|move)|tab (create|close)|workspace (create|close)|worktree open)' "$TMP_ROOT/replay-calls"; then
  fail 'fresh spawn replay mutated an endpoint'
fi
tasks-axi show retained --file "$HOME_FIXTURE/data/backlog.md" | grep -q '^  state: in_flight$' || fail 'fresh spawn replay replaced the native task'
pass 'locked fresh-spawn admission preserves enrolled task, endpoint and exact history'
touch "$TMP_ROOT/allow-launch"
printf '%s\n' "$ROOT" > "$TMP_ROOT/source-root"
if ! env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
  -u FM_BACKEND_HERDR_CLIENT_SESSION -u FM_BACKEND_HERDR_BIN \
  FM_HOME="$HOME_FIXTURE" PATH="$FAKEBIN:$BASE_PATH" FM_SPAWN_NO_GUARD=1 \
  FM_CONTROL_POLL=.01 FM_CONTROL_LAUNCH_WAIT=.1 \
  "$ROOT/bin/fm-control.sh" retained relaunch --note 'Read the native task in full before source work. Preserve this exact Pi history.' > "$OUT" 2>&1; then
  read_result; fail 'managed exact-history recovery failed'
fi
[ -s "$TMP_ROOT/launch" ] || fail 'no actual recovery command captured'
LAUNCH=$(< "$TMP_ROOT/launch")
(cd "$TMP_ROOT/worktree"; HERDR_PANE_ID=w0:p2 HERDR_TAB_ID=w0:t2 HERDR_WORKSPACE_ID=w0 \
  HERDR_SESSION=enroll-test HERDR_SOCKET_PATH="$TMP_ROOT/api.sock" \
  PATH="$FAKEBIN:$BASE_PATH" bash -c "$LAUNCH") || fail 'received native recovery command failed'
[ -s "$TMP_ROOT/received-argv.json" ] || fail 'Pi did not receive the exact history/model/home'
cmp "$TMP_ROOT/history-before" "$TMP_ROOT/history.jsonl" || fail 'managed recovery replaced prior history'
grep -q '^herdr_enrollment=' "$META" || fail 'recovery dropped retained identity protection'
grep -q '^pi_session_file=' "$META" || fail 'recovery dropped exact history binding'
pass 'managed control recovery opens the exact stopped Pi history with original endpoint and explicit model/effort/home'
: > "$TMP_ROOT/api-calls"
if ! env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
  -u FM_BACKEND_HERDR_CLIENT_SESSION -u FM_BACKEND_HERDR_BIN \
  FM_HOME="$HOME_FIXTURE" PATH="$FAKEBIN:$BASE_PATH" \
  "$ROOT/bin/fm-send.sh" retained 'Enrollment inbox proof: preserve source and acknowledge this instruction.' > "$OUT" 2>&1; then
  read_result; fail 'ordinary durable send failed after managed recovery'
fi
MESSAGES=("$HOME_FIXTURE/state/retained.inbox/"*.msg)
[ "${#MESSAGES[@]}" = 1 ] || fail 'ordinary send did not create exactly one durable message'
[ -f "${MESSAGES[0]}" ] || fail 'ordinary send did not create a durable message'
grep -q 'Enrollment inbox proof' "${MESSAGES[0]}" || fail 'durable inbox lost the instruction'
grep -q 'pane send-text.*Firstmate instruction waiting' "$TMP_ROOT/api-calls" || fail 'valid enrolled delivery did not ring its doorbell'
for spec in \
  'pane.json|.result.pane.terminal_id = "replacement"' \
  'pane.json|.result.pane.tab_id = "w2:t9"' \
  'process.json|.result.process_info.shell_pid = 1'; do
  file=${spec%%|*}; expression=${spec#*|}
  cp "$TMP_ROOT/$file" "$TMP_ROOT/saved-delivery"
  jq "$expression" "$TMP_ROOT/saved-delivery" > "$TMP_ROOT/$file"
  : > "$TMP_ROOT/api-calls"
  for selector in retained enroll-test:w2:p1; do
    if env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
      -u FM_BACKEND_HERDR_CLIENT_SESSION -u FM_BACKEND_HERDR_BIN \
      FM_HOME="$HOME_FIXTURE" PATH="$FAKEBIN:$BASE_PATH" \
      "$ROOT/bin/fm-send.sh" "$selector" 'Refuse replacement delivery.' > "$OUT" 2>&1; then
      fail "changed enrolled identity accepted delivery through $selector"
    fi
  done
  # shellcheck disable=SC2016 # The child shell expands its own arguments and retry status.
  if ! env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_BACKEND_HERDR_CLIENT_SESSION -u FM_BACKEND_HERDR_BIN \
    FM_HOME="$HOME_FIXTURE" PATH="$FAKEBIN:$BASE_PATH" bash -c '
      . "$1/bin/fm-task-inbox-lib.sh"
      [ -z "$(fm_backend_target_of_meta "$2")" ] || exit 1
      rc=0
      fm_task_inbox_ring herdr enroll-test:w2:p1 "$3" fm-retained || rc=$?
      [ "$rc" = 3 ]
    ' retry "$ROOT" "$META" "${MESSAGES[0]}" > "$OUT" 2>&1; then
    read_result; fail 'doorbell retry did not refuse the changed enrolled identity'
  fi
  if grep -Eq '^pane (send-text|send-keys|run) ' "$TMP_ROOT/api-calls"; then
    fail 'changed enrolled identity received terminal input'
  fi
  [ ! -f "$HOME_FIXTURE/state/retained.inbox/002.msg" ] || fail 'changed enrolled identity enqueued another instruction'
  [ -f "${MESSAGES[0]}" ] || fail 'refused retry lost its durable instruction'
  mv "$TMP_ROOT/saved-delivery" "$TMP_ROOT/$file"
done
pass 'delivery and doorbell retries refuse reused enrolled terminal, tab and process identities'
mv "${MESSAGES[0]}" "$HOME_FIXTURE/state/retained.inbox/handled/"
printf 'note: enrollment inbox proof acknowledged; no source mutation\n' >> "$HOME_FIXTURE/state/retained.status"
grep -q 'enrollment inbox proof acknowledged' "$HOME_FIXTURE/state/retained.status" || fail 'worker result did not reach ordinary status transport'
pass 'ordinary fm-send, native inbox acknowledgement and result transport work with the enrolled record'

# Reuse this private endpoint fixture as a moved secondmate, with child state
# and an enabled clean launch environment. No production enrollment is changed.
awk -F= '$1 !~ /^(herdr_enrollment|pi_session_file|pi_session_id|kind|mode|home|project)$/' "$META" > "$TMP_ROOT/secondmate.meta"
printf 'kind=secondmate\nmode=secondmate\nhome=%s\nproject=%s\n' \
  "$TMP_ROOT/worktree" "$TMP_ROOT/worktree" >> "$TMP_ROOT/secondmate.meta"
mv "$TMP_ROOT/secondmate.meta" "$META"
mkdir -p "$TMP_ROOT/worktree"/{data,state,bin}
printf 'retained\n' > "$TMP_ROOT/worktree/.fm-secondmate-home"
printf '# Test home\n' > "$TMP_ROOT/worktree/AGENTS.md"
printf '# retained charter\n' > "$TMP_ROOT/worktree/data/charter.md"
printf 'window=child-session:fm-child\n' > "$TMP_ROOT/worktree/state/child.meta"
printf 'ENROLL_FIXTURE\n' > "$HOME_FIXTURE/config/launch-env-allowlist"
cp "$META" "$TMP_ROOT/secondmate-before"
cp "$TMP_ROOT/pane.json" "$TMP_ROOT/pane-before"
for field in pane_id tab_id workspace_id transport; do
  if [ "$field" = transport ]; then
    cp "$TMP_ROOT/pane-before" "$TMP_ROOT/pane.json"
    touch "$TMP_ROOT/pane-get-failed"
  else
    jq --arg field "$field" '.result.pane[$field] = "foreign"' "$TMP_ROOT/pane-before" > "$TMP_ROOT/pane.json"
  fi
  if env FM_HOME="$HOME_FIXTURE" PATH="$FAKEBIN:$BASE_PATH" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-control.sh" retained relaunch --harness pi > "$OUT" 2>&1; then
    fail "accepted contradictory live $field"
  fi
  grep -q 'disagrees with its recorded endpoint' "$OUT" || { read_result; fail "missing $field refusal"; }
  cmp "$META" "$TMP_ROOT/secondmate-before" || fail 'refusal changed metadata'
  [ -f "$TMP_ROOT/live-agent" ] || fail 'refusal stopped the prior agent'
done
rm "$TMP_ROOT/pane-get-failed"
cp "$TMP_ROOT/pane-before" "$TMP_ROOT/pane.json"
# Model an already-exited agent; the real linked source and child records stay.
rm "$TMP_ROOT/live-agent"
if ! env FM_HOME="$HOME_FIXTURE" PATH="$FAKEBIN:$BASE_PATH" FM_SPAWN_NO_GUARD=1 \
  FM_CONTROL_POLL=.01 FM_CONTROL_LAUNCH_WAIT=.1 \
  "$ROOT/bin/fm-control.sh" retained relaunch --harness pi \
  --model cliproxyapi/gpt-6-astra --effort high > "$OUT" 2>&1; then
  read_result; fail 'moved secondmate recovery failed'
fi
LAUNCH=$(< "$TMP_ROOT/launch")
(cd "$TMP_ROOT/worktree"; HERDR_PANE_ID=w0:p2 HERDR_TAB_ID=w0:t2 HERDR_WORKSPACE_ID=w0 \
  HERDR_SESSION=enroll-test HERDR_SOCKET_PATH="$TMP_ROOT/api.sock" \
  PATH="$FAKEBIN:$BASE_PATH" bash -c "$LAUNCH") || fail 'secondmate replacement/startup identity failed'
[ "$(< "$TMP_ROOT/worktree/data/charter.md")" = '# retained charter' ] || fail 'charter changed'
[ "$(< "$TMP_ROOT/worktree/state/child.meta")" = 'window=child-session:fm-child' ] || fail 'child record changed'
grep -qx 'children=1' "$HOME_FIXTURE/state/retained.control-relaunch" || fail 'child checkpoint missing'
pass 'moved secondmate replacement/startup uses current IDs with clean env, preserves children and refuses live identity drift'

REMOTE_HOME="$TMP_ROOT/worktree"
REMOTE_STATE="$REMOTE_HOME/state/parent-route"
mkdir -p "$REMOTE_STATE" "$REMOTE_HOME/config"
cp "$META" "$REMOTE_STATE/retained.meta"
jq '.sessions[0].name = "fm-remote"' "$TMP_ROOT/sessions.json" > "$TMP_ROOT/remote-sessions.json"
mv "$TMP_ROOT/remote-sessions.json" "$TMP_ROOT/sessions.json"
# shellcheck disable=SC2016 # The child shell expands its arguments and computed move identity.
env FM_HOME="$REMOTE_HOME" PATH="$FAKEBIN:$BASE_PATH" bash -c '
  . "$1/bin/fm-backend.sh"
  fm_backend_source herdr
  . "$1/bin/backends/herdr-pane-move.sh"
  identity=$(fm_backend_herdr_move_identity fm-remote w2:p1) || exit 1
  pending=$(jq -cn --argjson identity "$identity" --arg socket "$3/api.sock" \
    "{task:\"retained\",session:\"fm-remote\",socket:\$socket,destination:\"w2\",identity:(\$identity | .pane=\"w1:p7\" | .tab=\"w1:t7\" | .workspace=\"w1\")}") || exit 1
  changes=$(jq -cn --arg pending "$pending" \
    "{herdr_move:\$pending,window:\"fm-remote:w1:p7\",herdr_session:\"fm-remote\",herdr_workspace_id:\"w1\",herdr_tab_id:\"w1:t7\",herdr_pane_id:\"w1:p7\"}") || exit 1
  fm_backend_herdr_move_meta "$2" "$changes"
' fixture "$ROOT" "$REMOTE_STATE/retained.meta" "$TMP_ROOT" || fail 'remote pending-move fixture failed'
env FM_HOME="$REMOTE_HOME" FM_STATE_OVERRIDE="$REMOTE_STATE" PATH="$FAKEBIN:$BASE_PATH" \
  "$ROOT/bin/fm-control.sh" retained reconcile-move > "$OUT" 2>&1 \
  || { read_result; fail 'remote parent-route move reconciliation failed'; }
remote_control() {
  env FM_HOME="$REMOTE_HOME" PATH="$FAKEBIN:$BASE_PATH" FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=.01 FM_CONTROL_LAUNCH_WAIT=.1 \
    "$ROOT/bin/fm-remote-secondmate-control.sh" "$@" > "$OUT" 2>&1
}
remote_control route retained || { read_result; fail 'moved remote route failed'; }
grep -qx 'target=fm-remote:w2:p1' "$OUT" || fail 'remote route lost current selectors'
remote_control send retained 'Retained remote delivery.' || { read_result; fail 'moved remote send failed'; }
[ -f "$REMOTE_STATE/retained.inbox/001.msg" ] || fail 'remote steer did not reach its parent-route inbox'
remote_control key retained Enter || { read_result; fail 'moved remote key failed'; }
rm "$TMP_ROOT/live-agent"
remote_control relaunch retained pi cliproxyapi/gpt-6-astra high \
  || { read_result; fail 'moved remote relaunch rejected its owning parent-route record'; }
remote_control route retained || { read_result; fail 'remote relaunch lost route ownership'; }
grep -qx 'target=fm-remote:w2:p1' "$OUT" || fail 'remote relaunch changed current selectors'
env FM_HOME="$REMOTE_HOME" FM_STATE_OVERRIDE="$REMOTE_STATE" \
  FM_DATA_OVERRIDE="$REMOTE_HOME/data/.parent-route" PATH="$FAKEBIN:$BASE_PATH" \
  "$ROOT/bin/fm-fleet-snapshot.sh" --json > "$OUT" \
  || fail 'moved remote fleet snapshot failed'
jq -e '.tasks[] | select(.id == "retained") | .endpoint |
  .target == "fm-remote:w2:p1" and .exists == true and .agent_alive == "alive"' "$OUT" >/dev/null \
  || { read_result; fail 'snapshot copies lost the moved endpoint or its liveness'; }
pass 'moved remote delivery, control and relaunch share one metadata owner across home contexts'

: > "$TMP_ROOT/api-calls"
rm "$TMP_ROOT/live-agent"
remote_control launch retained pi cliproxyapi/gpt-6-astra high herdr \
  || { read_result; fail 'automatic remote recovery failed for a completed move'; }
[ -f "$TMP_ROOT/live-agent" ] || fail 'remote recovery did not relaunch the agent'
grep -qx 'target=fm-remote:w2:p1' "$OUT" || fail 'remote automatic recovery changed the endpoint'
if grep -Eq '^pane (close|move) ' "$TMP_ROOT/api-calls"; then fail 'remote recovery closed or moved the retained terminal'; fi
kill -0 "$PID" || fail 'remote recovery stopped the retained shell'

fm_fake_exit0 "$FAKEBIN" gh no-mistakes
printf 'pi cliproxyapi/gpt-6-astra high\n' > "$HOME_FIXTURE/config/secondmate-harness"
: > "$TMP_ROOT/api-calls"
rm "$TMP_ROOT/live-agent"
env FM_HOME="$HOME_FIXTURE" FM_STATE_OVERRIDE="$REMOTE_STATE" \
  FM_DATA_OVERRIDE="$REMOTE_HOME/data/.parent-route" FM_CONFIG_OVERRIDE="$HOME_FIXTURE/config" \
  FM_BOOTSTRAP_NETWORK=only FM_SPAWN_NO_GUARD=1 FM_SKIP_SECONDMATE_SYNC=1 FM_SKIP_SECONDMATE_INHERIT=1 \
  FM_CONTROL_POLL=.01 FM_CONTROL_LAUNCH_WAIT=.1 PATH="$FAKEBIN:$BASE_PATH" \
  "$ROOT/bin/fm-bootstrap.sh" > "$OUT" 2>&1 || { read_result; fail 'automatic local recovery failed'; }
[ -f "$TMP_ROOT/live-agent" ] || { read_result; fail 'local recovery did not relaunch the moved agent'; }
if grep -Eq '^pane (close|move) ' "$TMP_ROOT/api-calls"; then fail 'local recovery closed or moved the retained terminal'; fi
kill -0 "$PID" || fail 'local recovery stopped the retained shell'
[ "$(fm_pid_identity "$PID")" = "$BIRTH" ] || fail 'automatic recovery changed shell identity'
grep -qx 'window=fm-remote:w2:p1' "$REMOTE_STATE/retained.meta" || fail 'local automatic recovery changed the endpoint'
cmp "$TMP_ROOT/history-before" "$TMP_ROOT/history.jsonl" || fail 'automatic recovery changed retained history'
[ "$(< "$REMOTE_HOME/state/child.meta")" = 'window=child-session:fm-child' ] || fail 'automatic recovery changed child ownership'
pass 'local and remote automatic recovery relaunch completed moves without closing retained terminals'
