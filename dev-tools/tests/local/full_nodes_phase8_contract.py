from full_programs import full_program, TOPOLOGY
"""Phase 8 host contracts. Only frozen fixture copies have relocated roots.
No production path, live SSH, installed settings or device action is used.
"""
import ast
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

BASE = Path(__file__).resolve().parents[3]
COUNT = 0
LIBS = 'selftest_context identity owner_lock action_lock full_fence update_state continuation radio mervqt settings_reconcile maintenance_quiesce'.split()


def check(value, message):
    global COUNT
    COUNT += 1
    if not value:
        raise AssertionError(message)
    print('PASS', message, flush=True)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def start(pid):
    return Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1].split()[19]


def write(path, data, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(data)
    path.chmod(mode)


def wait_file(path, process=None):
    for _ in range(1500):
        if path.exists():
            return
        if process and process.poll() is not None:
            break
        time.sleep(.02)
    diagnostics=path.parent/'coordinator.stderr'
    raise AssertionError(f'missing {path}: '+(diagnostics.read_text() if diagnostics.exists() else ''))


class Node:
    def __init__(self, scenario='success', busybox=False, policy='KEEP'):
        self.root = Path(tempfile.mkdtemp(prefix='mervlan-phase8-node.', dir='/tmp'))
        self.root.chmod(0o700)
        self.run = '1.2.3.4'
        self.policy = policy
        self.stage = self.root/'tmp'/f'.mervlan-full-stage.{self.run}'
        self.stage.mkdir(parents=True, mode=0o700)
        self.runtime = self.root/'tmp/mervlan_tmp'
        (self.runtime/'locks').mkdir(parents=True)
        self.m = self.runtime/'locks/mervlan_maintenance.lock'
        self.f = self.root/'tmp/.mervlan-full-uninstall.lock'
        self.clean_dir = self.root/'tmp'/f'.mervlan-full-cleanup.{self.run}.NODE1'
        self.events = self.root/'events'
        (self.root/'jffs/addons/mervlan_state/ssh_trust').mkdir(parents=True)
        (self.root/'jffs/addons/mervlan').mkdir()
        (self.root/'www/user').mkdir(parents=True)
        self.bin = self.root/'bin'
        self.bin.mkdir()
        no_dhcp_hold_rules = f'''printf '%s\\n' "$*" >> {self.root}/ebtables.calls
case "${{3:-}}:${{4:-}}" in
  -L:MERV_DHCP_HOLD) exit 1 ;;
  -L:FORWARD|-L:INPUT) exit 0 ;;
  *) exit 1 ;;
esac'''
        for name, body in {'logger':'exit 0', 'cru':'exit 0', 'ebtables':no_dhcp_hold_rules, 'sync':'exit 0', 'reboot':f'touch {self.root}/reboot'}.items():
            write(self.bin/name, '#!/bin/sh\n'+body+'\n', 0o700)
        def relocate(s):
            return re.sub(r'(?<!\\)/(?:jffs|www|tmp)(?=[/\".*|)])', lambda m: str(self.root)+m.group(), s)
        for lib in LIBS:
            s = relocate((BASE/f'settings/lib_{lib}.sh').read_text())
            write(self.stage/f'lib_{lib}.sh', s)
        s = relocate(full_program('node'))
        s = s.replace('VAR_SETTINGS_LOADED=1',
                      'VAR_SETTINGS_LOADED=1\nMERV_DHCP_HOLD_CHAIN=MERV_DHCP_HOLD', 1)
        s = s.replace('PATH=/usr/sbin:', f'PATH={self.bin}:/usr/sbin:')
        # Deadline shortened only in frozen fixtures, never production.
        s = s.replace(' -lt 30 ]', ' -lt 6 ]')
        s = s.replace('nw_mstart=$MERV_LOCK_START;', f'printf "M\\n" >> {self.events}\nnw_mstart=$MERV_LOCK_START;')
        s = s.replace('nw_fstart=$MERV_FULL_FENCE_START;', f'printf "F\\n" >> {self.events}\nnw_fstart=$MERV_FULL_FENCE_START;')
        s = s.replace('    [ "$nw_q" != IDLE ] || break', f'    printf "Q:%s\\n" "$nw_q" >> {self.events}\n    [ "$nw_q" != IDLE ] || break')
        s = s.replace('nw_entered=yes', f'printf "cleaner\\n" >> {self.events}\nnw_entered=yes')
        s = s.replace('    nw_publish decision || exit 4', f'    printf "decision:%s\\n" "$nw_class" >> {self.events}\n    nw_publish decision || exit 4')
        s = s.replace('then nw_fdis=released', f'then printf "release-F\\n" >> {self.events}; nw_fdis=released')
        after_q = ''
        if scenario == 'm-loss': after_q = f'rm -rf {self.m}\n'
        if scenario in ('m-replace','f-replace'):
            obj = self.m if scenario == 'm-replace' else self.f
            after_q = f"rm -rf {obj}; mkdir -m 700 {obj}; printf 'foreign\\n' > {obj}/owner; chmod 600 {obj}/owner\n"
        if scenario == 'cleaner-drift': after_q = f'printf "# drift\\n" >> {self.stage}/cleaner.sh\n'
        if scenario == 'f-release-obstructed':
            s=s.replace('    nw_publish decision || exit 4', f'    touch {self.f}/foreign-entry\n    nw_publish decision || exit 4')
        if scenario == 'late-idle':
            s=s.replace('    nw_now=$(awk', '    [ \"$nw_q\" != IDLE ] || sleep 7\n    nw_now=$(awk', 1)
        if scenario == 'pause-m':
            s=s.replace('merv_full_fence_claim \"$nw_f\"', f'touch {self.root}/paused; sleep 10\nmerv_full_fence_claim \"$nw_f\"', 1)
        if scenario == 'pause-before-m':
            s=s.replace('merv_owner_lock_acquire \"$nw_m\"', f'touch {self.root}/paused; sleep 10\nmerv_owner_lock_acquire \"$nw_m\"', 1)
        if scenario == 'pause-f':
            s = s.replace('# Monotonic uptime deadline.', f'touch {self.root}/paused\nsleep 10\n# Monotonic uptime deadline.')
        if after_q:
            s = s.replace('nw_m_exact && nw_f_exact || nw_refuse ownership-changed', after_q+'nw_m_exact && nw_f_exact || nw_refuse ownership-changed', 1)
        if busybox: s=s.replace("/bin/sh -s", "busybox sh -s")
        write(self.stage/'node.sh', s)
        s = relocate((BASE/'functions/mervlan_full_cleanup.sh').read_text())
        s = s.replace('PATH="/usr/sbin:', f'PATH="{self.bin}:/usr/sbin:', 1)
        # Avoid host process-name discovery in a destructive source fixture.
        s = re.sub(r'^find_mervlan_processes\(\) \{\n.*?^\}', 'find_mervlan_processes() { printf "\\n"; }', s, flags=re.M|re.S)
        hook = f'    test -d {self.f} || exit 99\n    printf "runtime-removed\\n" >> {self.events}\n'
        if scenario == 'claim-start-tamper':hook+=f"    sed 's/^start=.*/start=1/' {self.clean_dir}/claim/consumer > {self.clean_dir}/claim/changed; chmod 600 {self.clean_dir}/claim/changed; mv {self.clean_dir}/claim/changed {self.clean_dir}/claim/consumer\n"
        if scenario == 'failure': hook += '    SIGNALLED=1\n'
        if scenario == 'ambiguous': hook += '    kill -KILL "$$"\n'
        if scenario == 'pause-cleaner': hook += f'    touch {self.root}/paused\n    sleep 2\n'
        s = s.replace('    remove_glob_list "$MERVLAN_VOLATILE_GLOBS"\n}', '    remove_glob_list "$MERVLAN_VOLATILE_GLOBS"\n'+hook+'}')
        write(self.stage/'cleaner.sh', s)
        write(self.stage/'stage.sh', relocate(full_program('stage')))
        names = ['cleaner.sh','stage.sh','node.sh']+[f'lib_{x}.sh' for x in LIBS]
        write(self.stage/'artifacts.manifest', ''.join(f'{digest(self.stage/n)} main/{n}\n' for n in names))
        self.generation = digest(self.stage/'artifacts.manifest')
        fields = dict(protocol='phase8-node-v1', run=self.run, slot='NODE1', identity='NODE1@192.0.2.1:22', cleaner_sha256=digest(self.stage/'cleaner.sh'), wrapper_sha256=digest(self.stage/'node.sh'), generation=self.generation, ready_sha256='a'*64, backup_policy=policy, reboot='no')
        write(self.stage/'context', ''.join(f'{k}={v}\n' for k,v in fields.items()))
        self.shell = ['busybox','sh'] if busybox else ['/bin/sh']
        self.process = None
        self.files = []

    def owner(self, path, pid=None):
        path.mkdir(mode=0o700)
        pid = pid or os.getpid()
        write(path/'owner', f'pid={pid}\nproc_start_time={start(pid)}\nowner_nonce=fixture\ncreated=1\nheartbeat=1\n')

    def launch(self):
        out = (self.root/'stdout').open('w'); err = (self.root/'stderr').open('w')
        self.files += [out,err]
        self.process = subprocess.Popen(self.shell+[str(self.stage/'node.sh'),'--run',str(self.stage/'context')],stdout=out,stderr=err)
        return self.process

    def finish(self):
        rc = self.process.wait(timeout=20)
        result = self.stage/'result'
        if not result.exists():
            raise AssertionError(f'no result rc={rc} stderr={(self.root/"stderr").read_text()} events={self.events.read_text() if self.events.exists() else ""}')
        fields = dict(line.split('=',1) for line in result.read_text().splitlines())
        check(int(fields['rc']) == rc, 'result/exit agreement '+fields['class'])
        check((self.root/'stdout').read_text() == result.read_text(), 'stdout is exact structured receipt')
        check(fields['backup_policy']==self.policy and fields['ready_sha256']=='a'*64 and fields['generation']==self.generation,'NODE receipt binds correct policy/readiness/generation')
        check(not (self.root/'reboot').exists(), 'NODE never reboots')
        return fields

    def close(self):
        if self.process and self.process.poll() is None: self.process.kill(); self.process.wait()
        for f in self.files: f.close()
        shutil.rmtree(self.root)


def local_contracts():
    for scenario in ('success','failure','ambiguous','claim-start-tamper','f-release-obstructed','m-loss','m-replace','f-replace','cleaner-drift','artifact','wrapper-artifact','helper-artifact','extra-artifact','live-m','existing-f','malformed-f','malformed-m','unknown-q','late-idle'):
        n = Node(scenario)
        try:
            if scenario == 'wrapper-artifact':
                p=n.stage/'node.sh';p.write_text(p.read_text()+'# drift\n')
            if scenario == 'helper-artifact':
                p=n.stage/'lib_owner_lock.sh';p.write_text(p.read_text()+'# drift\n')
            if scenario == 'malformed-f': n.f.mkdir(mode=0o700);write(n.f/'owner','bad\n')
            if scenario == 'extra-artifact':write(n.stage/'.unexpected','extra\n')
            if scenario == 'artifact': (n.stage/'cleaner.sh').write_text('# drift\n')
            if scenario == 'live-m': n.owner(n.m)
            if scenario == 'existing-f': n.f.mkdir(mode=0o700)
            if scenario == 'malformed-m': n.m.mkdir(mode=0o700); write(n.m/'owner','bad\n')
            if scenario == 'unknown-q': write(n.runtime/'locks/unsupported.lock','unknown\n')
            n.launch(); result=n.finish()
            expected = 'SUCCESS' if scenario=='success' else 'FAILED_TERMINAL' if scenario=='failure' else 'UNVERIFIED' if scenario in ('ambiguous','claim-start-tamper','f-release-obstructed','m-loss','m-replace','f-replace') else 'REFUSED'
            check(result['class']==expected, scenario+' classification '+str(result))
            events=n.events.read_text().splitlines()
            if scenario in ('success','failure','ambiguous'):
                check(events[:3]==['M','F','Q:IDLE'], 'exact M F Q order '+scenario)
                check(events.index('runtime-removed')>events.index('cleaner'), 'actual cleaner runtime deletion '+scenario)
                if scenario != 'ambiguous':
                    check(result['maintenance']=='removed-with-runtime' and not n.runtime.exists(), 'legitimate post-cleaner M disappearance')
                    check(events.index('release-F')>events.index('decision:'+expected)>events.index('runtime-removed'), 'F lasts through runtime deletion and fixed terminal decision')
                    check(not n.f.exists(), 'exact owned F released')
                else: check(n.f.exists(), 'missing terminal retains F')
            elif scenario=='claim-start-tamper':
                check(n.f.exists() and result['class']=='UNVERIFIED','independently observed direct-child start rejects claimant inconsistency')
            elif scenario=='f-release-obstructed':
                check(n.f.exists() and result['rc']=='4','F release obstruction retains F and final receipt agrees')
                check((n.stage/'decision').read_text().startswith('protocol=phase8-decision-v1\n'),'decision is distinct from final receipt')
            else:
                check('cleaner' not in events,'no cleaner on refusal/ownership loss '+scenario)
            if scenario in ('m-replace','f-replace'):
                obj=n.m if scenario=='m-replace' else n.f
                check((obj/'owner').read_text()=='foreign\n', 'foreign replacement untouched')
            if scenario == 'unknown-q': check(not n.f.exists() and not n.m.exists(), 'pre-destructive timeout safely releases M/F')
            if scenario=='late-idle':check(result['reason']=='quiescence-timeout' and not n.f.exists(),'late IDLE cannot bypass the finite drain deadline')
            if scenario == 'live-m': check(not n.f.exists(),'live M blocks before F')
            if scenario == 'existing-f': check(n.f.exists() and not n.m.exists(),'existing F preserved own M released')
        finally: n.close()

    # Real R process drains under held M/F. New post-owner admission refuses F.
    n=Node()
    r=subprocess.Popen(['sleep','4'])
    try:
        lock=n.runtime/'locks/mervlan_action.lock'; n.owner(lock,r.pid)
        n.launch()
        wait_file(n.f,n.process)
        check(not n.clean_dir.exists(),'cleaner waits for active R')
        r.wait(); shutil.rmtree(lock)
        result=n.finish(); events=n.events.read_text().splitlines()
        check('Q:BUSY' in events and events.index('Q:IDLE')>events.index('Q:BUSY'), 'real ordinary R busy then idle')
        check(result['class']=='SUCCESS','drained R permits cleaner')
    finally:
        if r.poll() is None: r.kill(); r.wait()
        n.close()

    n=Node('pause-f')
    try:
        n.launch(); wait_file(n.root/'paused',n.process)
        # Actual admission library, source-isolated canonical paths. It must refuse
        # after R owner acquisition while wrapper has M/F.
        admission=(BASE/'settings/lib_mutation_admission.sh').read_text()
        admission=re.sub(r'(?<!\\)/(?:jffs|www|tmp)(?=[/\".*|)])',lambda m:str(n.root)+m.group(),admission)
        write(n.root/'admission.sh',admission)
        action=n.runtime/'locks/mervlan_action.lock'
        cmd=f'. {n.stage}/lib_selftest_context.sh; . {n.stage}/lib_identity.sh; . {n.stage}/lib_owner_lock.sh; . {n.stage}/lib_action_lock.sh; . {n.stage}/lib_continuation.sh; . {n.stage}/lib_full_fence.sh; . {n.stage}/lib_update_state.sh; . {n.root}/admission.sh; merv_owner_lock_acquire {action} 0 0 test || exit 9; merv_mutation_admission_check_fm; admission_rc=$?; [ \"$MERV_MUTATION_ADMISSION_REASON\" = full-fence-live ] || exit 8; exit \"$admission_rc\"'
        p=subprocess.run(['/bin/sh','-c',cmd],capture_output=True,text=True)
        check(p.returncode==1,'new mutation post-owner admission blocked by F '+p.stderr)
        n.process.kill(); n.process.wait()
        check(n.f.exists(),'wrapper killed after F retains F')
        check(not (n.stage/'result').exists(),'killed wrapper cannot fabricate terminal')
        again=subprocess.run(n.shell+[str(n.stage/'node.sh'),'--run',str(n.stage/'context')],capture_output=True)
        check(again.returncode==4,'permanent wrapper claim blocks replay')
    finally:n.close()

    # BusyBox executes real NODE wrapper, not just syntax.
    n=Node(busybox=True)
    try:
        n.launch(); result=n.finish(); check(result['class']=='SUCCESS','BusyBox local wrapper success')
    finally:n.close()

    for scenario in ('pause-before-m','pause-m','pause-cleaner'):
        n=Node(scenario)
        try:
            n.launch();wait_file(n.root/'paused',n.process)
            n.process.kill();n.process.wait()
            if scenario=='pause-before-m':check(not n.m.exists() and not n.f.exists(),'wrapper killed before M owns nothing')
            elif scenario=='pause-m':check(n.m.exists() and not n.f.exists(),'wrapper killed after M before F leaves dead M only')
            else:
                # Direct cleaner already passed admission and remains independent
                # of MAIN/wrapper lifetime. Its exact F can never be released by it.
                wait_file(n.clean_dir/'terminal')
                check(n.f.exists(),'wrapper killed during cleaner retains local F')
                check(not (n.stage/'result').exists(),'wrapper death cannot fabricate result')
        finally:n.close()

    n=Node();r=subprocess.Popen(['sleep','20'])
    try:
        n.owner(n.runtime/'locks/mervlan_action.lock',r.pid)
        n.launch();result=n.finish()
        check(result['class']=='REFUSED' and result['reason']=='quiescence-timeout','finite real BUSY drain timeout')
        check(not n.f.exists() and not n.m.exists(),'BUSY timeout releases exact M/F before destruction')
        check(r.poll() is None,'Q does not kill normal admitted R')
    finally:r.kill();r.wait();n.close()

    n=Node(policy='DELETE')
    try:
        backup=n.root/'jffs/addons/mervlan_backups';backup.mkdir();write(backup/'retained','backup')
        n.launch();result=n.finish()
        check(result['class']=='SUCCESS' and result['backup_policy']=='DELETE','NODE frozen DELETE maps to coordinated cleaner')
        check(not backup.exists(),'NODE actual delete-backups applied')
    finally:n.close()
    print('PHASE8_LOCAL_CHECKS',COUNT,flush=True)



def coordinator_contracts():
    # Coordinator fixtures retain actual Phase-7 artifact/readiness generation and
    # actual Stage-v2 verification. Probe/transport are source-isolated host adapters;
    # each destructive response is emitted by a separate synchronous real process.
    phase7 = ast.parse((BASE/'dev-tools/tests/local/full_bootstrap_phase7_contract.py').read_text())
    selected = []
    for item in phase7.body:
        if isinstance(item,(ast.Import,ast.ImportFrom)):
            selected.append(item)
        elif isinstance(item,ast.Assign) and any(isinstance(t,ast.Name) and t.id in ('CLIENT','SOURCES') for t in item.targets):
            selected.append(item)
        elif isinstance(item,ast.FunctionDef) and item.name in ('key','run_fixture'):
            selected.append(item)
    namespace = {}
    exec(compile(ast.Module(body=selected,type_ignores=[]),'phase7-fixture-adapter','exec'),namespace)
    client=namespace['CLIENT']
    client=client.replace("else next(x for x in ('init','receive','verify')", "else 'invoke' if command.startswith('env -i') else next(x for x in ('init','receive','verify','context')")
    needle="if op == 'proof':\n"
    invoke=r'''if op == 'invoke':
    node=root/'remote'/slot
    stage=next(node.glob('stage.*'))
    fields=dict(l.split('=',1) for l in (stage/'context').read_text().splitlines())
    assert fields['slot']==slot
    run=home.parent
    assert (run/'main/terminal.sh').is_file()
    terminal=(run/'terminal.manifest').read_text().split()
    assert terminal[1]=='main/terminal.sh' and hashlib.sha256((run/'main/terminal.sh').read_bytes()).hexdigest()==terminal[0]
    assert 'support=full-terminal-v1' in (run/'ready').read_text()
    assert hashlib.sha256((run/'terminal.manifest').read_bytes()).hexdigest()+' terminal.manifest' in (run/'ready').read_text()
    active=root/'destructive.active'
    active.mkdir()  # real exclusive overlap detector, not source grep
    with (root/'destruction-order').open('a') as f:f.write(slot+'\n')
    pid=os.getpid()
    start=pathlib.Path('/proc/'+str(pid)+'/stat').read_text().rsplit(') ',1)[1].split()[19]
    status='SUCCESS'; rc=0; cleanup='0'; fence='released'; maintenance='removed-with-runtime'
    if slot=='NODE2' and scenario=='node-refused': status='REFUSED';rc=2;cleanup='none';fence='not-owned';maintenance='not-owned'
    if slot=='NODE2' and scenario=='node-failed': status='FAILED_TERMINAL';rc=3;cleanup='3'
    if slot=='NODE2' and scenario=='node-unverified':status='UNVERIFIED';rc=4;cleanup='none';fence='retained';maintenance='unverified'
    if slot=='NODE2' and scenario=='transport-loss':
        active.rmdir();sys.exit(255) # no receipt, no blind retry
    if scenario=='coordinator-kill':
        (root/'remote-running').write_text(str(pid))
        time.sleep(2)
        (root/'remote-finished').write_text('local terminal')
    result=dict(protocol='phase8-result-v1',run=fields['run'],slot=slot,identity=fields['identity'],wrapper_pid=str(pid),wrapper_start=start,
        cleaner_run=fields['run']+'.'+slot if status!='REFUSED' else 'none',cleaner_pid=str(pid) if status!='REFUSED' else 'none',
        cleaner_start=start if status!='REFUSED' else 'none',cleanup_rc=cleanup,rc=str(rc),**{'class':status},reason='fixture',fence=fence,
        maintenance=maintenance,backup_policy='KEEP',reboot='no',generation=fields['generation'],ready_sha256=fields['ready_sha256'])
    if scenario=='wrong-run' and slot=='NODE2':result['run']='9.9.9.9'
    if scenario=='duplicate-result' and slot=='NODE2':result['reason']='fixture\nrc=0'
    if scenario=='exit-mismatch' and slot=='NODE2':rc=4
    data=''.join(k+'='+v+'\n' for k,v in result.items())
    (stage/'result').write_text(data);(stage/'result').chmod(0o600)
    active.rmdir()
    if slot=='NODE1':
        if scenario=='between-trust':
            trust=root/'state/ssh_trust/known_hosts.v1';trust.write_text(trust.read_text()+'drift\n')
        if scenario=='between-artifact':
            p=next((root/'remote/NODE2').glob('stage.*'))/'node.sh';p.write_text(p.read_text()+'# drift\n')
        if scenario=='between-endpoint':(root/'endpoint-failed').write_text('NODE2')
    print(data,end='');sys.exit(rc)
if (root/'endpoint-failed').exists() and slot=='NODE2' and host=='192.0.2.2':sys.exit(255)
'''
    client=client.replace('import base64, hashlib, json, os, pathlib, subprocess, sys, time', 'import base64, hashlib, json, os, pathlib, subprocess, sys, time')
    client=client.replace(needle,invoke+needle)
    namespace.update(BASE=BASE,check=check,CLIENT=client)
    source=ast.get_source_segment((BASE/'dev-tools/tests/local/full_bootstrap_phase7_contract.py').read_text(),next(x for x in phase7.body if isinstance(x,ast.FunctionDef) and x.name=='run_fixture'))
    source=source.replace('bad_source=None):','bad_source=None):')
    # Speed only the host adapter. The dedicated Phase-7 regression suite keeps
    # canonical real probe/client timing. No production code is patched in place.
    source=source.replace("        (base/'.ssh').mkdir(mode=0o700)", r"""        boot=base/'settings/lib_full_uninstall.sh'
        b=boot.read_text()
        b=re.sub(r'^full_bounded\(\) \{\n.*?^\}', 'full_bounded() { HOME="$FULL_ROOT/$FULL_SLOT" "$FULL_CLIENT" -o BatchMode=yes -o PasswordAuthentication=no -p "$FULL_PORT" -i "$FULL_KEY" "$FULL_USER@$FULL_ENDPOINT" "$1"; }', b, flags=re.M|re.S)
        b=re.sub(r'^full_probe\(\) \{\n.*?^\}', 'full_probe() { cat "'+str(root)+'/probe.event" >> "'+str(root)+'/events"; cat "'+str(root)+'/probe.fixture" > "$FULL_ROOT/probe.result"; }', b, flags=re.M|re.S)
        boot.write_text(b)
        fp='SHA256:'+base64.b64encode(hashlib.sha256(base64.b64decode(key(1))).digest()).decode().rstrip('=')
        (root/'probe.event').write_text(json.dumps(dict(slot='fixture',host='fixture',op='probe',home=''))+'\n')
        (root/'probe.fixture').write_text('ssh-ed25519\t'+key(1)+'\t'+fp+'\n')
        (base/'.ssh').mkdir(mode=0o700)""")
    source=source.replace("        for slot in hosts.values():", """        if scenario=='between-endpoint':
            settings['Nodes']['NODE2_WAN_NATIVE_IP']='198.51.100.2'
            hosts['198.51.100.2']='NODE2'
        for slot in hosts.values():""", 1)
    # Stop using the bootstrap-only postconditions after phase8; retain all earlier
    # readiness staging checks. Then run the real private coordinator entry.
    source=source.replace("        # Staged shell is actually executed in fixtures.", '''        ready_hash=hashlib.sha256((run/'ready').read_bytes()).hexdigest()
        if scenario=='old-ready':
            (run/'ready').write_text((run/'ready').read_text().replace('phase7-v3','phase7-v2').replace('full-terminal-v1','node-cleanup-v1'))
            ready_hash=hashlib.sha256((run/'ready').read_bytes()).hexdigest()
        if scenario=='main-terminal-tamper':
            p=run/'main/terminal.sh';p.write_text(p.read_text()+'# drift\\n')
        if scenario=='coordinator-kill':
            out=(root/'coordinator.stdout').open('w');err=(root/'coordinator.stderr').open('w')
            coordinator=subprocess.Popen(['/bin/sh',str(BASE/'dev-tools/tests/local/full_fixture_entry.sh'),'--nodes',str(run),ready_hash],env=environment,stdout=out,stderr=err)
            wait_file(root/'remote-running',coordinator)
            coordinator.kill();coordinator.wait();wait_file(root/'remote-finished')
            out.close();err.close()
            check((root/'destruction-order').read_text().splitlines()==['NODE1'],'coordinator death cannot launch next NODE')
            check(not (run/'node-phase-complete').exists(),'coordinator death cannot publish handoff')
            check('INVOKING' in (run/'journal').read_text(),'crash journal retains invoking ambiguity')
            return
        result=subprocess.run(['/bin/sh',str(BASE/'dev-tools/tests/local/full_fixture_entry.sh'),'--nodes',str(run),ready_hash],env=environment,capture_output=True,text=True,timeout=60)
        success=scenario=='ok'
        check((result.returncode==0)==success, 'coordinator '+scenario+' '+str(result.returncode)+' '+result.stderr)
        order=(root/'destruction-order').read_text().splitlines() if (root/'destruction-order').exists() else []
        expected_order=['NODE'+str(i) for i in range(1,nodes+1)] if success else [] if scenario in ('old-ready','main-terminal-tamper') else ['NODE1'] if scenario.startswith('between-') else ['NODE1','NODE2']
        check(order==expected_order,'exact sequential order '+scenario+' '+str(order))
        check(not (root/'destructive.active').exists(),'no overlapping destructive NODE workers')
        if scenario=='between-endpoint':
            remote_events=[json.loads(l) for l in (root/'events').read_text().splitlines()]
            check(not any(e['host']=='198.51.100.2' for e in remote_events),'reachable alternate endpoint never used after pinning')
        check((run/'node-phase-complete').exists()==success,'handoff only all SUCCESS '+scenario)
        if success:
            handoff=(run/'node-phase-complete').read_text()
            check('state=NODE_PHASE_COMPLETE' in handoff and 'node_count='+str(nodes) in handoff,'NODE-only handoff')
            check(handoff.count(' SUCCESS ')==nodes,'every SUCCESS digest bound in handoff')
            check((run/'node-phase-complete').stat().st_mode&0o777==0o600,'atomic private handoff')
        if scenario not in ('old-ready','main-terminal-tamper'):
            journal=(run/'journal').read_text()
            check(('NODE1 SUCCESS' in journal)==(nodes!=0),'prior success preserved')
            if not success:check('NODE3 NOT_ATTEMPTED' in journal,'stop leaves later NODE unattempted')
            expected_class='REFUSED' if scenario.startswith('between-') or scenario=='node-refused' else 'FAILED_TERMINAL' if scenario=='node-failed' else 'UNVERIFIED'
            if not success:check('NODE2 '+expected_class in journal,'correct failure/ambiguity class')
        again=subprocess.run(['/bin/sh',str(BASE/'dev-tools/tests/local/full_fixture_entry.sh'),'--nodes',str(run),ready_hash],env=environment,capture_output=True)
        check(again.returncode!=0,'coordinator cannot automatically resume/replay')
        check((root/'destruction-order').read_text().splitlines()==order if order else not (root/'destruction-order').exists(),'retry never invokes another NODE')
        check((base/'functions/mervlan_full_cleanup.sh').exists(),'MAIN remains installed')
        check(not list(root.glob('mervlan_maintenance.lock')) and not list(root.glob('.mervlan-full-uninstall.lock')),'no MAIN M/F')
        print('PASS coordinator fixture',scenario,nodes,flush=True)
        return
        # Staged shell is actually executed in fixtures.''')
    namespace.update(re=re,base64=__import__('base64'),hashlib=hashlib,wait_file=wait_file)
    exec(source,namespace)
    only=next((a.split('=',1)[1] for a in sys.argv if a.startswith('--case=')),None)
    if only is None:
        for n in (0,1,3):namespace['run_fixture'](nodes=n)
    for scenario in ('old-ready','main-terminal-tamper','node-refused','node-failed','node-unverified','transport-loss','wrong-run','duplicate-result','exit-mismatch','between-trust','between-artifact','between-endpoint','coordinator-kill'):
        if only is None or only==scenario:namespace['run_fixture'](scenario=scenario,nodes=3)
    print('PHASE8_TOTAL_CHECKS',COUNT,flush=True)

if __name__ == "__main__":
    if "--coordinator-only" not in sys.argv:local_contracts()
    if "--node-only" not in sys.argv:coordinator_contracts()
