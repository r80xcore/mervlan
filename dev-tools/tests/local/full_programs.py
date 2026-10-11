"""Host-only access to literal Full templates for relocation fixtures."""
from pathlib import Path
import atexit
import tempfile
BASE = Path(__file__).resolve().parents[3]
def full_program(kind):
    source = (BASE/'settings/lib_full_uninstall.sh').read_text()
    delimiter = 'MERVLAN_FULL_'+kind.upper()+'_PROGRAM'
    return source.split("cat <<'"+delimiter+"'\n",1)[1].split('\n'+delimiter+'\n',1)[0]+'\n'
f = tempfile.NamedTemporaryFile(prefix='mervlan-topology.',suffix='.awk',delete=False)
f.write(full_program('topology').encode()); f.close()
TOPOLOGY = Path(f.name)
atexit.register(lambda: TOPOLOGY.unlink(missing_ok=True))
