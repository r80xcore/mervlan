#!/usr/bin/env python3
"""Offline differential scan: actual accepted R1, original lean, corrected lean.
No router access; no installed MerVLAN scripts executed.
"""
import os, pathlib, subprocess, tempfile, shutil, sys
from test_lean_repair import Fixture, attach_live_candidate

HERE=pathlib.Path(__file__).resolve().parent
REF=HERE.parent/'reference'
SOURCES={
    'R1':(REF/'evidence_kit/baseline/update_mervlan_repair.sh').read_text().split('\ntrap repair_exit_handler EXIT')[0],
    'lean_original':(REF/'update_mervlan_repair_lean.sh').read_text().split('\n# A proof of cooperating writer exclusion')[0],
    'lean_corrected':(HERE/'update_mervlan_repair_lean.sh').read_text().split('\n# A proof of cooperating writer exclusion')[0],
}
RESULT=[]

def scan(f,name,shell):
    script=f.root/(name+'.scanner.lib.sh');script.write_text(SOURCES[name])
    func='repair_legacy_process_scan' if name=='R1' else 'scan_processes'
    command=f'. "{script}"; {func}'
    argv=['busybox','ash','-c',command] if shell=='ash' else ['dash','-c',command]
    return subprocess.run(argv,env=f.env,capture_output=True,text=True,timeout=10)

def trial(shell,description,arg=None,cwd='functions',mutation=None,expect='BLOCK'):
    f=Fixture(process_count=2)
    sleeper=None
    try:
        if arg is not None:
            actual=str(f.base/'functions/heal_event.sh') if arg=='ABS' else arg
            where=f.base/'functions' if cwd=='functions' else f.base if cwd=='base' else f.root/'fakebin'
            sleeper,entry=attach_live_candidate(f,actual,where if mutation!='missing_cwd' else None)
            if mutation=='missing_stat':(entry/'stat').unlink()
            if mutation=='unreadable_cmdline':(entry/'cmdline').unlink()
            if mutation=='dead':sleeper.terminate();sleeper.wait();sleeper=None
        elif mutation=='late_pid':
            # At first entry's tr, mutate a later PID cmdline. No shortlist.
            sleeper,entry=attach_live_candidate(f,'normal',f.base/'functions')
            early=f.proc/'1'/'cmdline'; trigger=f.root/'trigger'; later=entry/'cmdline'
            payload=f.root/'payload';payload.write_bytes(b'/bin/sh\0heal_event.sh\0')
            shim=f.fakebin/'tr'
            shim.write_text(f'''#!/bin/sh
fd=$(readlink /proc/self/fd/0)
if [ "$fd" = "{early}" ] && [ ! -e "{trigger}" ]; then
 cp "{payload}" "{later}"; : > "{trigger}"
fi
exec /usr/bin/tr "$@"
''');shim.chmod(0o755)
        responses={}
        for name in SOURCES:
            # Reset late-PID injection per scanner, so every scanner sees the race.
            if mutation=='late_pid':
                (f.proc/'1'/'cmdline').write_bytes(b'/bin/sh\0normal\0')
                (entry/'cmdline').write_bytes(b'/bin/sh\0normal\0')
                (f.root/'trigger').unlink(missing_ok=True)
            r=scan(f,name,shell)
            responses[name]='CLEAR' if r.returncode==0 else 'BLOCK'
            if mutation=='late_pid':assert (f.root/'trigger').exists(),name
        ok=(responses['R1']==expect and responses['lean_corrected']==expect)
        # Original bare filename is the targeted, externally demonstrated gap.
        if description=='bare' and responses['lean_original']!='CLEAR':ok=False
        RESULT.append((shell,description,responses,'PASS' if ok else 'FAIL'))
        print(f'{shell:4} {description:19} {str(responses):92} {"PASS" if ok else "FAIL"}',flush=True)
    finally:
        if sleeper:
            sleeper.terminate();sleeper.wait()
        f.close()

for shell in ('dash','ash'):
    for name,arg,cwd,change,expected in [
        ('bare','heal_event.sh','functions',None,'BLOCK'),
        ('dot','./heal_event.sh','functions',None,'BLOCK'),
        ('nested','functions/heal_event.sh','base',None,'BLOCK'),
        ('nested_dot','./functions/./heal_event.sh','base',None,'BLOCK'),
        ('absolute','ABS','base',None,'BLOCK'),
        ('invalid_parent','../functions/heal_event.sh','base',None,'BLOCK'),
        ('outside_addon','heal_event.sh','outside',None,'CLEAR'),
        ('unreadable_stat','heal_event.sh','functions','missing_stat','BLOCK'),
        ('unreadable_cwd','heal_event.sh','functions','missing_cwd','BLOCK'),
        ('unreadable_cmdline','heal_event.sh','functions','unreadable_cmdline','BLOCK'),
        # R1 explicitly skips a known-dead PID; corrected lean conservatively refuses.
        ('dead_pid','heal_event.sh','functions','dead','CLEAR'),
        ('later_pid_race',None,'functions','late_pid','BLOCK'),
    ]:
        if name=='dead_pid':
            # The lean implementation intentionally BLOCKS stale candidates;
            # verify R1 CLR and corrected BLOCK in the separate check below.
            f=Fixture(process_count=2)
            sl,entry=attach_live_candidate(f,'heal_event.sh',f.base/'functions')
            sl.terminate();sl.wait()
            try:
                results={n:('CLEAR' if scan(f,n,shell).returncode==0 else 'BLOCK') for n in SOURCES}
                ok=results['R1']=='CLEAR' and results['lean_corrected']=='BLOCK'
                RESULT.append((shell,name,results,'PASS' if ok else 'FAIL'))
                print(shell,name,results,'PASS' if ok else 'FAIL',flush=True)
            finally:f.close()
        else:trial(shell,name,arg,cwd,change,expected)
print('RESULT',sum(a[3]=='PASS' for a in RESULT),'/',len(RESULT))
sys.exit(0 if all(a[3]=='PASS' for a in RESULT) else 1)
