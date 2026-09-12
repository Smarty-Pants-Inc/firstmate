import json,os,pathlib,shutil,subprocess
E=pathlib.Path('/home/paul/.no-mistakes/evidence/01M2B3BS0CC96WVG0ASK40V8XZ')
ROOT=pathlib.Path('/home/paul/.no-mistakes/worktrees/c00995dcf2eb/01M2B3BS0CC96WVG0ASK40V8XZ')
req=json.loads((E/'bearings-display-headings-request.json').read_text())
source=pathlib.Path(req['argv'][req['argv'].index('--append-system-prompt')+1]).parents[3]
# Source root is recorded by the exact extension argument as well.
source=pathlib.Path(req['argv'][req['argv'].index('-e')+1]).parents[2]
lab=source.parent
home=lab/'bearings-home'
relay=lab/'relay-home/state/x-outbox/presentation-public-preview.json'
assert source.is_relative_to(ROOT) and home.is_relative_to(ROOT)
shutil.copyfile(relay,E/'relay-public-preview.json')
preview=json.loads(relay.read_text())
assert preview['request_id']=='presentation-public-preview'
assert 'ready for review' in preview['text']
assert 'Cedar' not in preview['text'] and 'Private Canary' not in preview['text']
report=(E/'bearings-generated-report.md').read_text()
headings=[s[3:] for s in report.splitlines() if s.startswith('## ')]
assert headings==["Owner's Call",'Recently Landed','Underway','Charted Next']
assert 'Captain,' not in report and 'Mica,' not in report
# Inspect the real emitted JSON contract under two differing saved presentation inputs.
control=lab/'snapshot-control'
for folder in ('data','state','config','projects'): (control/folder).mkdir(parents=True,exist_ok=True)
results=[]
for name,fm_home in [('preferred-display',home),('no-preferences',control)]:
 env=os.environ.copy()|{'FM_HOME':str(fm_home),'FM_ROOT_OVERRIDE':str(source),'FM_GATE_REFUSE_BYPASS':'1','TMPDIR':str(lab/'tmp'),'FM_BACKEND':'tmux'}
 p=subprocess.run([str(source/'bin/fm-bearings-snapshot.sh'),'--json'],cwd=source,env=env,check=True,text=True,capture_output=True,timeout=60)
 data=json.loads(p.stdout)
 (E/f'{name}-snapshot.json').write_text(json.dumps(data,indent=2))
 results.append(data)
assert set(results[0])==set(results[1])
# Compare typed public fields that carry actionable state, excluding collection metadata/time.
fields=['in_flight','queued','gates','decisions_open','landed','secondmates','recorded_prs']
checked=[]
for key in fields:
 if key in results[0]:
  assert results[0][key]==results[1][key],key
  checked.append(key)
assert 'in_flight' in checked and 'decisions_open' in checked
(E/'product-contract-checks.json').write_text(json.dumps({'public_preview':preview,'report_headings':headings,'snapshot_keys_unchanged':sorted(results[0]),'actionable_fields_identical':checked,'scope':'Empty isolated homes; validates emitted schema and empty-state projection, not task lifecycle mutations.'},indent=2))
print(json.dumps({'report_headings':headings,'public_preview':preview,'identical_actionable_snapshot_fields':checked},indent=2))
