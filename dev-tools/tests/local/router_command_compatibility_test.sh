#!/bin/sh
# Source-isolated execution of corrected capability paths with no command
# builtin. The real Sync/Execute cohort fixtures run under the same fault.
set -eu
BASE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
python3 - "$BASE_DIR" <<'PY'
import re,subprocess,sys,tempfile
from pathlib import Path
base=Path(sys.argv[1])
def function(path,name):
 source=(base/path).read_text()
 return re.search(r'^'+name+r'\(\) \{\n.*?^\}',source,re.M|re.S).group()
fault='command() { return 127; }; command -v openssl; [ "$?" = 127 ] || exit 90; type openssl >/dev/null || exit 91;\n'
# SHA256 and OpenSSL-only fallback. Direct failure models the unavailable
# SHA applet independently of PATH (the router has a functional OpenSSL).
with tempfile.TemporaryDirectory(prefix='mervlan-capability.',dir='/tmp') as tmp:
 data=Path(tmp)/'data';data.write_text('MerVLAN target capability\n')
 for fallback in (False,True):
  for path,name in [('settings/lib_ssh.sh','merv_ssh_digest'),('functions/sync_nodes.sh','sync_node_admission_digest'),('functions/mervlan_node_mutate.sh','mnm_early_digest'),('settings/lib_full_uninstall.sh','full_digest')]:
   funcs=function('settings/lib_ssh.sh','merv_ssh_digest')+'\n'+function(path,name)
   code=fault+('sha256sum() { return 127; };\n' if fallback else '')+funcs+'\n'+name+' "$1"'
   result=subprocess.run(['/bin/sh','-c',code,'fixture',str(data)],capture_output=True,text=True)
   import hashlib
   assert result.returncode==0 and result.stdout.strip()==hashlib.sha256(data.read_bytes()).hexdigest(),(name,result.stderr,result.stdout)
   print('PASS no-command '+name+' '+('openssl' if fallback else 'sha256sum'))
 # Standalone cleaner path resolution and boot cron capability share the
 # established merv_has/merv_cmd shim; don't source the destructive cleaner.
 shim=(base/'settings/lib_ssh.sh').read_text().split('# ---- merv: portable',1)[1].split('# ---- end shim ----')[0]
 shim=shim[shim.index('if ! type'):]
 funcs=shim+function('functions/mervlan_full_cleanup.sh','resolve_cru')+'\n'+function('functions/mervlan_full_cleanup.sh','resolve_ebtables')
 bindir=Path(tmp)/'bin';bindir.mkdir()
 for name in ('cru','ebtables'):
  p=bindir/name;p.write_text('#!/bin/sh\nexit 0\n');p.chmod(0o700)
 code=fault+f'PATH="{bindir}:$PATH"\n'+funcs+'\nresolve_cru; resolve_ebtables; [ "$CRU_BIN" = "$1/cru" ] && [ "$EBTABLES_BIN" = "$1/ebtables" ]'
 subprocess.run(['/bin/sh','-c',code,'fixture',str(bindir)],check=True)
 print('PASS cleaner resolves executable paths without command builtin')
 # Reuse real cohort fixture code, including the generated remote Execute
 # program. Inject the fault into its local transport shell as well.
 for name in ('node_admission_bootstrap_test.sh','execute_node_guard_cohort_test.sh'):
  source=(base/'dev-tools/tests/local'/name).read_text()
  source=re.sub(r'^BASE_DIR=.*$', 'BASE_DIR='+str(base),source,flags=re.M)
  source=source.replace('set -eu\n','set -eu\ncommand() { return 127; }\n').replace('set -u\n','set -u\ncommand() { return 127; }\n')
  source=source.replace('sh -c "$3"', 'sh -c \'command() { return 127; }; type openssl >/dev/null || exit 91; eval "$1"\' transport "$3"')
  subprocess.run(['/bin/sh','-c',source],check=True,timeout=120)
  print('PASS no-command real '+name)
 # Router-executed raw probes must not return via any corrected program.
 for path in [*base.glob('functions/*.sh'),*base.glob('settings/*.sh'),base/'install.sh',base/'uninstall.sh']:
  for line in path.read_text().splitlines():
   if not line.lstrip().startswith('#'):assert 'command -v' not in line,(path,line)
 print('PASS exhaustive router shell raw-probe audit')
PY
