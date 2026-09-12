import runpy, subprocess
from pathlib import Path
p=Path('/home/paul/.no-mistakes/evidence/01M2B3BS0CC96WVG0ASK40V8XZ')
ctx=runpy.run_path(str(p/'presentation-surfaces-live.py'),run_name='baseline_helpers')
old=subprocess.run(['git','show','9074f9d20d3dd6b632051623f71797084a7aab36:AGENTS.md'],cwd=ctx['ROOT'],check=True,capture_output=True).stdout
(ctx['source']/'AGENTS.md').write_bytes(old)
ctx['run_case']('before-change-omit-routine',local='# Synthetic test preferences\n- Omit direct address altogether.\n- Omit nautical flavor.\n',prompt='A routine operational update arrived: the requested action completed successfully and needs no intervention. A reply is required.')
