#!/usr/bin/env python3
"""Host-only regression: no /tmp leak before publication; preserve failure evidence after publication."""
from pathlib import Path
import test_lean_repair as t

def check_case(label, configure, check):
    f=t.Fixture(process_count=3)
    try:
        configure(f)
        r=f.run('dash', timeout=50)
        scratch=list(f.tmp.glob('mervlan_lean.*'))
        ok=check(r,scratch)
        print(('PASS' if ok else 'FAIL'), label, 'rc=',r.returncode,'scratch=',len(scratch),flush=True)
        if not ok:print(r.stderr[-2000:])
        return ok
    finally:f.close()

ok=True
ok &= check_case('unpublished failed fetch removes private scratch',
    lambda f:f.env.update(MERV_REPAIR_CURL='/bin/false'),
    lambda r,dirs:r.returncode!=0 and len(dirs)==0 and 'unpublished private workspace removed' in r.stderr)
ok &= check_case('successful transaction removes private scratch',
    lambda f:None,
    lambda r,dirs:r.returncode==0 and len(dirs)==0)
ok &= check_case('failed publication preserves transaction evidence',
    lambda f:f.env.update(MERV_REPAIR_TEST_FAIL_AT='13'),
    lambda r,dirs:r.returncode!=0 and len(dirs)==1 and (dirs[0]/'ledger').exists())
raise SystemExit(0 if ok else 1)
