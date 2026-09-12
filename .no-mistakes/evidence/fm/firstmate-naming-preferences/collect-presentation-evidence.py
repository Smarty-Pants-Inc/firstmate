import html,json,pathlib,shutil
E=pathlib.Path('/home/paul/.no-mistakes/evidence/01M2B3BS0CC96WVG0ASK40V8XZ')
ROOT=pathlib.Path('/home/paul/.no-mistakes/worktrees/c00995dcf2eb/01M2B3BS0CC96WVG0ASK40V8XZ')
cases=[]
for req in sorted(E.glob('*-request.json')):
 name=req.name.removesuffix('-request.json')
 if not (E/f'{name}-result.json').exists(): continue
 request=json.loads(req.read_text())
 eventpath=E/f'{name}-events.jsonl'
 messages=[]; tools={}; digest=''; outputs=[]
 for line in eventpath.read_text().splitlines():
  try: e=json.loads(line)
  except ValueError: continue
  if e.get('type')!='message_end': continue
  m=e.get('message',{}); role=m.get('role')
  if role=='custom' and m.get('customType')=='firstmate-sessionstart-nudge': digest=m.get('content','')
  if role=='assistant':
   for c in m.get('content',[]):
    if c.get('type')=='text': messages.append(c['text'])
    elif c.get('type')=='toolCall':
     tools[c['id']]=c['name']
     if c['name'] in ('bash','write'): outputs.append({'tool':c['name'],'arguments':c.get('arguments')})
  elif role=='toolResult' and tools.get(m.get('toolCallId')) in ('bash','write'):
   outputs.append({'tool_result':tools[m['toolCallId']],'isError':m.get('isError',False),'content':[c.get('text') for c in m.get('content',[]) if c.get('type')=='text']})
 if not messages: raise SystemExit(f'No assistant text captured for {name}')
 (E/f'{name}-startup.txt').write_text(digest)
 normalized={'name':name,'request':request,'result':json.loads((E/f'{name}-result.json').read_text()),'assistant_responses':messages,'product_operations':outputs}
 (E/f'{name}-transcript.json').write_text(json.dumps(normalized,indent=2))
 cases.append(normalized)
 for op in outputs:
  if op.get('tool')=='write':
   f=pathlib.Path(op['arguments']['path'])
   if f.name.startswith('status-report-') and f.is_relative_to(ROOT) and f.is_file(): shutil.copyfile(f,E/'bearings-generated-report.md')
# Show only product text, no provider thinking/signatures or private configuration.
lines=['# Live presentation-preference evidence','','Product: Firstmate target f01bca9c86d664298b01b9bcffcb6d61bfe50175, Pi 0.85.1, configured cliproxyapi/gpt-6-astra.','All preferences and names below are synthetic. Each case used a fresh native Pi process with the real Firstmate startup extensions and a disposable home.','The baseline case used AGENTS.md from 9074f9d20d3dd6b632051623f71797084a7aab36. No deployed home was changed.','']
blocks=[]
for c in cases:
 lines += ['## '+c['name'],'','User input: '+c['request']['prompt'],'','Observed response:','','\n\n'.join(c['assistant_responses']),'']
 blocks.append('<section><h2>'+html.escape(c['name'])+'</h2><p class="prompt">'+html.escape(c['request']['prompt'])+'</p>'+''.join('<pre>'+html.escape(m)+'</pre>' for m in c['assistant_responses'])+'</section>')
(E/'presentation-transcript.md').write_text('\n'.join(lines))
(E/'presentation-transcript.html').write_text('<!doctype html><html lang="en"><meta charset="utf-8"><title>Firstmate live presentation checks</title><style>body{font:16px system-ui;max-width:900px;margin:36px auto;padding:0 20px;background:#f8fafc;color:#172033}section{background:white;border:1px solid #d7dee7;border-radius:8px;padding:20px;margin:20px 0}h2{font-size:20px}.prompt{color:#596579}pre{font:15px/1.6 system-ui;white-space:pre-wrap}</style><h1>Firstmate live presentation checks</h1><p>Rendered native CLI responses, using synthetic preferences in isolated homes. This is a transcript, not a GUI screenshot.</p>'+''.join(blocks)+'</html>')
print('Collected product responses for:',', '.join(c['name'] for c in cases))
