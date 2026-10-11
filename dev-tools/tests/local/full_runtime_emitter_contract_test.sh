#!/bin/sh
set -eu
BASE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
python3 - "$BASE_DIR" <<'PY'
import hashlib, os, subprocess, sys, tempfile
from pathlib import Path
base=Path(sys.argv[1]);sys.path.insert(0,str(base/'dev-tools/tests/local'))
from full_programs import full_program
with tempfile.TemporaryDirectory(prefix='mervlan-emitter.',dir='/tmp') as tmp:
 root=Path(tmp); (root/'main').mkdir(mode=0o700)
 (root/'bootstrap.sh').write_bytes((base/'settings/lib_full_uninstall.sh').read_bytes());(root/'bootstrap.sh').chmod(0o600)
 for kind,leaf in [('topology','topology.awk'),('stage','main/stage.sh'),('node','main/node.sh'),('main','main/terminal.sh')]:
  dest=root/leaf
  code='. "$1"; FULL_ROOT=$2; FULL_UID=$(id -u); full_emit_frozen "$3" "$4"'
  args=['/bin/sh','-c',code,'emit',str(base/'settings/lib_full_uninstall.sh'),tmp,kind,str(dest)]
  subprocess.run(args,check=True)
  exact=full_program(kind).encode()
  assert dest.read_bytes()==exact and dest.stat().st_mode & 0o777==0o600
  digest=hashlib.sha256(exact).hexdigest()
  # Replays, existing objects and symlinks are refused without replacement.
  assert subprocess.run(args).returncode != 0
  assert hashlib.sha256(dest.read_bytes()).hexdigest()==digest
  dest.unlink();dest.symlink_to(root/'bootstrap.sh')
  assert subprocess.run(args).returncode != 0
  dest.unlink();subprocess.run(args,check=True)
  assert dest.read_bytes()==exact
  if kind!='topology':
   for shell in (['/bin/sh'],['busybox','sh']):subprocess.run(shell+['-n',str(dest)],check=True)
  print('PASS deterministic private literal '+kind+' syntax/source/hash/object/replay')
 # Source injection remains inert text and generation comes from frozen code.
 (root/'bootstrap.sh').write_text((root/'bootstrap.sh').read_text()+'\n# frozen generation\n')
 print('PASS emitted programs require no installed template files')
PY
