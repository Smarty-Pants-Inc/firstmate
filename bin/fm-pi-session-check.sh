#!/usr/bin/env bash
# Validate one exact native Pi v3 history and visible writer claims before enrollment or
# relaunch. Prints its UUID only. Never rewrites history or selects recent/fuzzy.
# Usage: fm-pi-session-check.sh <absolute-session-file> <physical-worktree> <UUID>
# Current retained-session admission is Linux-only: /proc checks same-user Pi
# and supported JS-runtime processes for this exact file/UUID. Unreadable
# candidates and other platforms refuse; unrelated system services are not Pi.
set -eu
[ "$#" -eq 3 ] || exit 2
exec python3 - "$@" <<'PY'
import json, os, pathlib, stat, sys, uuid
path, cwd = sys.argv[1:3]
try:
    if not sys.platform.startswith('linux'):
        raise ValueError('retained Pi session admission currently requires Linux /proc')
    s = os.lstat(path)
    if not os.path.isabs(path) or os.path.realpath(path) != path or not stat.S_ISREG(s.st_mode) or s.st_nlink != 1 or s.st_uid != os.getuid():
        raise ValueError('history must be an owned canonical single-link regular file')
    def unique(pairs):
        result = {}
        for key,value in pairs:
            if key in result: raise ValueError('ambiguous history header')
            result[key] = value
        return result
    with open(path) as f:
        header = json.loads(f.readline(), object_pairs_hook=unique)
    sid = header.get('id')
    if header.get('type') != 'session' or header.get('version') != 3 or str(uuid.UUID(sid)) != sid:
        raise ValueError('not one exact native Pi v3 session')
    if header.get('cwd') != cwd or os.path.realpath(cwd) != cwd:
        raise ValueError('history cwd differs from retained source')
    if sid != sys.argv[3]:
        raise ValueError('history UUID changed')
    for proc in pathlib.Path('/proc').iterdir():
        if not proc.name.isdigit():
            continue
        try:
            if proc.stat().st_uid != os.getuid():
                continue
            args = (proc/'cmdline').read_bytes().split(b'\0')
            comm = (proc/'comm').read_text().strip()
            runtimes = {'pi', 'pi-signed', 'node', 'nodejs', 'bun', 'deno'}
            candidate = comm in runtimes or any(
                os.path.basename(a.decode(errors='replace')) in runtimes or b'pi-coding-agent/' in a
                for a in args[:3])
            if not candidate:
                continue
            if os.path.realpath(os.readlink(proc/'cwd')) == cwd:
                # A bare Pi or --continue launch need not expose its selected
                # UUID in argv or initial environment. Refuse every candidate
                # runtime at this cwd rather than infer that it owns no history.
                raise ValueError('another live Pi/runtime process uses the retained cwd')
            env = (proc/'environ').read_bytes().split(b'\0')
        except FileNotFoundError:
            continue
        except ProcessLookupError:
            continue
        except PermissionError:
            raise ValueError('cannot inspect another same-user Pi/runtime process')
        values = dict(item.split(b'=', 1) for item in env if b'=' in item)
        if values.get(b'PI_SESSION_ID') == sid.encode() or values.get(b'PI_SESSION_FILE') == path.encode():
            raise ValueError('native history is still used by a live process')
        # Check explicit CLI selections while launch arguments remain visible.
        for i, arg in enumerate(args[:-1]):
            if arg in (b'--session', b'--session-id') and args[i+1] in (path.encode(), sid.encode()):
                raise ValueError('native history already has a pending launch')
    print(sid)
except (OSError, ValueError, TypeError, AttributeError) as e:
    raise SystemExit('Pi session refused: '+str(e))
PY
