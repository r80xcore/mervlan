from full_programs import full_program, TOPOLOGY
"""Phase 9 private source fixtures. No real router paths or transport.
Actual frozen wrapper + exclusion helpers + Phase-6 cleaner, real child exit,
root deletion, signal and publication failure injection. Fixtures alone relocate
canonical /tmp,/jffs,/www strings; production has no fault-injection options.
"""
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
from full_nodes_phase8_contract import Node, BASE, LIBS, digest, write, wait_file

COUNT = 0

def check(v, message):
    global COUNT
    COUNT += 1
    if not v: raise AssertionError(message)
    print('PASS', message, flush=True)

class Main(Node):
    def __init__(self, scenario='success', nodes=3, policy='KEEP', busybox=False,
                 finalization=None, outcome=None, release_fault=None, terminal_source=None):
        # Borrow the proven source-isolated device substrate (real Phase-6
        # cleaner and real helpers), never NODE wrapper execution/authority.
        super().__init__(scenario if scenario in ('success','failure','ambiguous','claim-start-tamper','pause-cleaner') else 'success', busybox)
        if scenario == 'dhcp-rules-present':
            ebtables = f'''#!/bin/sh
printf '%s\\n' "$*" >> {self.root}/ebtables.calls
case "${{3:-}}:${{4:-}}" in
  -L:MERV_DHCP_HOLD) exit 1 ;;
  -L:FORWARD) printf '%s\\n' '-A FORWARD -j MERV_DHCP_HOLD'; exit 0 ;;
  -L:INPUT) exit 0 ;;
  *) exit 1 ;;
esac
'''
            write(self.bin/'ebtables', ebtables, 0o700)
        old=self.stage
        self.stage=self.root/'tmp'/('.mervlan-full.'+self.run)
        self.stage.mkdir(mode=0o700)
        (self.stage/'main').mkdir(mode=0o700)
        for f in old.iterdir():
            if f.name in ['cleaner.sh','stage.sh','node.sh']+[f'lib_{x}.sh' for x in LIBS]:
                shutil.copyfile(f,self.stage/'main'/f.name);(self.stage/'main'/f.name).chmod(0o600)
        self.clean_dir=self.root/'tmp'/('.mervlan-full-cleanup.'+self.run+'.MAIN')
        cleaner=self.stage/'main/cleaner.sh'
        cleaner.write_text(cleaner.read_text().replace(self.run+'.NODE1',self.run+'.MAIN'))
        def relocate(s):
            return re.sub(r'(?<!\\)/(?:jffs|www|tmp)(?=[/\".*|)])', lambda m: str(self.root)+m.group(),s)
        s=relocate(terminal_source if terminal_source is not None else full_program('main'))
        s=s.replace('VAR_SETTINGS_LOADED=1',
                    'VAR_SETTINGS_LOADED=1\nMERV_DHCP_HOLD_CHAIN=MERV_DHCP_HOLD',1)
        s=s.replace('PATH=/usr/sbin:',f'PATH={self.bin}:/usr/sbin:')
        s=s.replace(' -lt 30 ]',' -lt 6 ]')
        s=s.replace('mw_mstart=$MERV_LOCK_START;',f'printf "M\\n" >> {self.events}\nmw_mstart=$MERV_LOCK_START;')
        s=s.replace('mw_fstart=$MERV_FULL_FENCE_START;',f'printf "F\\n" >> {self.events}\nmw_fstart=$MERV_FULL_FENCE_START;')
        s=s.replace('    [ "$mw_q" != IDLE ] || break',f'    printf "Q:%s\\n" "$mw_q" >> {self.events}\n    [ "$mw_q" != IDLE ] || break')
        s=s.replace('mw_entered=yes',f'printf "cleaner\\n" >> {self.events}\nmw_entered=yes')
        s=s.replace('    if ! mw_publish; then',f'    printf "decision:%s\\n" "$mw_class" >> {self.events}\n    if ! mw_publish; then')
        s=s.replace('then mw_fdis=released',f'then printf "release-F\\n" >> {self.events}; mw_fdis=released')
        if scenario in ('publish-create','predestruct-publish-create'):
            code=f'mkdir {self.stage}/phase9.claim/decision'+'.tmp'+'\n'
            s=s.replace('    if ! mw_publish; then', '    '+code+'    if ! mw_publish; then',1)
            # mv onto directory would succeed with a nested file: final expected
            # decision must be a regular exact record, not just successful mv.
        if scenario in ('publish-rename','predestruct-publish-rename'):
            write(self.bin/'mv', '#!/bin/sh\ncase "$*" in *phase9.claim/decision*) exit 1 ;; esac\nexec /bin/mv "$@"\n',0o700)
        if scenario=='owner-rename':
            write(self.bin/'mv', '#!/bin/sh\ncase "$*" in *phase9.claim/owner*) exit 1 ;; esac\nexec /bin/mv "$@"\n',0o700)
        if scenario.startswith('terminal-'):
            field=scenario.removeprefix('terminal-')
            code=f'printf "other:1:0\\n" > {self.clean_dir}/terminal\n'
            if field=='run':code=f'sed -i "s/{self.run}/9.9.9.9/" {self.clean_dir}/terminal\n'
            if field=='pid':code=f'sed -i "s/:[0-9]*:/\\:1:/" {self.clean_dir}/terminal\n'
            if field=='rc':code=f'sed -i "s/:0$/:3/" {self.clean_dir}/terminal\n'
            s=s.replace("trap 'exit 4' HUP INT TERM\ntrap '' PIPE",code+"trap 'exit 4' HUP INT TERM\ntrap '' PIPE",1)
        if scenario=='f-release-obstructed':
            s=s.replace('    if ! mw_publish; then',f'    touch {self.f}/foreign-entry\n    if ! mw_publish; then',1)
        if scenario=='f-terminal-replace':
            s=s.replace('    if ! mw_publish; then',f'    rm -rf {self.f}; mkdir -m 700 {self.f}; printf "foreign\\n" > {self.f}/owner; chmod 600 {self.f}/owner\n    if ! mw_publish; then',1)
        if scenario in ('m-replace','f-replace','cleaner-drift'):
            obj=self.m if scenario=='m-replace' else self.f
            code=f'rm -rf {obj}; mkdir -m 700 {obj}; printf "foreign\\n" > {obj}/owner; chmod 600 {obj}/owner\n'
            if scenario=='cleaner-drift':code=f'printf "# drift\\n" >> {cleaner}\n'
            s=s.replace('mw_m_exact && mw_f_exact || mw_refuse ownership-changed',code+'mw_m_exact && mw_f_exact || mw_refuse ownership-changed',1)
        pauses={'pause-before-m':'merv_owner_lock_acquire "$mw_m"','pause-m':'merv_full_fence_claim "$mw_f"','pause-f':'# Monotonic uptime deadline.','pause-after-q':'mw_m_exact && mw_f_exact || mw_refuse ownership-changed','pause-terminal':'    if ! mw_publish; then','pause-release':'    if [ "$mw_fdis" = owned ]; then','pause-released':'        mw_state=FULL_UNINSTALL_COMPLETE'}
        if scenario in pauses:
            marker=pauses[scenario]
            if scenario=='pause-release':
                before,after=s.rsplit(marker,1)
                s=before+f'touch {self.root}/paused; sleep 3\n'+marker+after
            else:s=s.replace(marker,f'touch {self.root}/paused; sleep 3\n'+marker,1)
        if outcome == 'REFUSED':
            # A definitive fixture-only refusal after M/F/Q, without a cleaner.
            s=s.replace('mw_cleaner_run="$mw_run.MAIN"', 'mw_refuse signal-fixture\nmw_cleaner_run="$mw_run.MAIN"',1)
        if finalization:
            os.mkfifo(self.root/'resume',0o600)
            barrier=f'printf "%s\n" "{finalization}" > {self.root}/paused; IFS= read -r mw_fixture_resume < {self.root}/resume\n'
            if finalization == 'before-commit':
                marker='    # Finalization commit follows'
                if scenario.startswith('predestruct-publish-'):
                    marker='                # Known no-entry refusal:'
                assert marker in s
                s=s.replace(marker,barrier+marker,1)
            elif finalization == 'committed':
                if outcome == 'UNVERIFIED':
                    # Ambiguity skips the release branch and has no commit.
                    marker='    if [ "$mw_fdis" = owned ]; then\n        if mw_f_exact'
                    assert marker in s
                    s=s.replace(marker,barrier+marker,1)
                else:
                    marker='if mw_f_exact && merv_full_fence_release'
                    assert marker in s
                    s=s.replace(marker,barrier+marker)
            elif finalization == 'post-release':
                marker='    if [ "$mw_class" = SUCCESS ] && [ "$mw_fdis" = released ]; then'
                # Publication-failure refusal uses its own receipt branch.
                if scenario.startswith('predestruct-publish-'):
                    marker="            trap '' HUP INT TERM PIPE\n            mw_record"
                assert marker in s
                s=s.replace(marker,barrier+marker,1)
            elif finalization != 'during-release':
                raise AssertionError(finalization)
        if finalization == 'during-release' or release_fault:
            helper=self.stage/'main/lib_full_fence.sh'
            hs=helper.read_text()
            assert hs.count('merv_full_fence_release() {') == 1
            helper.write_text(hs.replace('merv_full_fence_release() {','mw_fixture_real_release() {',1))
            pause=barrier if finalization == 'during-release' else ''
            fault=''
            if release_fault == 'fail':fault='return 1\n'
            if release_fault == 'foreign':
                fault=f'rm -rf {self.f}; mkdir -m 700 {self.f}; printf "foreign\n" > {self.f}/owner; chmod 600 {self.f}/owner\n'
            wrapper='merv_full_fence_release() {\n'+pause+fault+'mw_fixture_real_release "$@"\n}\n'
            s=s.replace('for mw_interface in',wrapper+'for mw_interface in',1)
        if busybox:s=s.replace('/bin/sh -s','busybox sh -s')
        write(self.stage/'main/terminal.sh',s)
        names=['cleaner.sh','stage.sh','node.sh']+[f'lib_{x}.sh' for x in LIBS]
        write(self.stage/'artifacts.manifest',''.join(f'{digest(self.stage/"main"/n)} main/{n}\n' for n in names))
        write(self.stage/'terminal.manifest',f'{digest(self.stage/"main/terminal.sh")} main/terminal.sh\n')
        self.generation=digest(self.stage/'artifacts.manifest')
        write(self.stage/'settings.snapshot.json','{}\n')
        write(self.stage/'topology.map',f'SSH admin 22\nMAIN none\nCOUNT {nodes}\n'+''.join(f'NODE{i} 192.0.2.{i} none standalone none none none\n' for i in range(1,nodes+1)))
        write(self.stage/'ssh.freeze','fixture\n')
        write(self.stage/'endpoint.map',''.join(f'NODE{i} 192.0.2.{i} 192.0.2.{i}\n' for i in range(1,nodes+1)))
        write(self.stage/'trust.identity.map',''.join(f'NODE{i} 192.0.2.{i} 22 NODE{i}@192.0.2.{i}:22 none alg fp key\n' for i in range(1,nodes+1)))
        for leaf in ('authority.manifest','config.manifest','maps.manifest'):write(self.stage/leaf,'fixture\n')
        ready=f'format=phase7-v3\nrun={self.run}\nstate=READY_FOR_NODE_CLEANUP\nnode_count={nodes}\nbackup_policy={policy}\nnode_reboot=no\nsupport=full-terminal-v1\n'
        ready+=''.join(f'{digest(self.stage/n)} {n}\n' for n in ('settings.snapshot.json','topology.map','ssh.freeze','endpoint.map','trust.identity.map','artifacts.manifest','terminal.manifest','authority.manifest'))
        ready+=f'config_manifest_sha256={digest(self.stage/"config.manifest")}\nmaps_manifest_sha256={digest(self.stage/"maps.manifest")}\n'
        write(self.stage/'ready',ready);self.ready=digest(self.stage/'ready')
        (self.stage/'phase8.claim').mkdir(mode=0o700)
        rows=''
        for i in range(1,nodes+1):
            fields=dict(protocol='phase8-result-v1',run=self.run,slot=f'NODE{i}',identity=f'NODE{i}@192.0.2.{i}:22',wrapper_pid='1',wrapper_start='1',cleaner_run=f'{self.run}.NODE{i}',cleaner_pid='1',cleaner_start='1',cleanup_rc='0',rc='0',**{'class':'SUCCESS'},reason='fixture',fence='released',maintenance='removed-with-runtime',backup_policy=policy,reboot='no',generation=self.generation,ready_sha256=self.ready)
            result=self.stage/f'phase8.claim/NODE{i}.result'
            write(result,''.join(f'{k}={v}\n' for k,v in fields.items()))
            row=f'NODE{i} SUCCESS {digest(result)}\n';rows+=row;write(self.stage/f'phase8.claim/NODE{i}.state',row)
        write(self.stage/'journal',f'protocol=phase8-journal-v1\nrun={self.run}\nstate=PHASE8_NODE_CLEANUP\ncurrent_slot={"NODE"+str(nodes) if nodes else "none"}\nready_sha256={self.ready}\ngeneration={self.generation}\n'+rows)
        write(self.stage/'node-phase-complete',f'protocol=phase8-handoff-v2\nrun={self.run}\nstate=NODE_PHASE_COMPLETE\nnode_count={nodes}\nbackup_policy={policy}\nreboot=no\nready_sha256={self.ready}\ngeneration={self.generation}\ntopology_sha256={digest(self.stage/"topology.map")}\njournal_sha256={digest(self.stage/"journal")}\nsupport=full-terminal-v1\nterminal_manifest_sha256={digest(self.stage/"terminal.manifest")}\n'+rows)
        self.handoff=digest(self.stage/'node-phase-complete')
        self.scenario=scenario

    def rebind_results(self):
        rows=''
        for p in sorted((self.stage/'phase8.claim').glob('*.result')):
            slot=p.name.split('.')[0];row=f'{slot} SUCCESS {digest(p)}\n'
            write(self.stage/f'phase8.claim/{slot}.state',row);rows+=row
        for name in ('journal','node-phase-complete'):
            p=self.stage/name;p.write_text(re.sub(r'^NODE.*\n','',p.read_text(),flags=re.M)+rows)
        p=self.stage/'node-phase-complete'
        p.write_text(re.sub(r'journal_sha256=[0-9a-f]{64}','journal_sha256='+digest(self.stage/'journal'),p.read_text()))
        self.handoff=digest(p)

    def launch(self):
        out=(self.root/'stdout').open('w');err=(self.root/'stderr').open('w');self.files += [out,err]
        self.process=subprocess.Popen(self.shell+[str(self.stage/'main/terminal.sh'),'--run',str(self.stage),self.ready,self.handoff],stdout=out,stderr=err)
        return self.process

    def finish(self):
        rc=self.process.wait(timeout=25)
        raw=(self.root/'stdout').read_text()
        fields=dict(l.split('=',1) for l in raw.splitlines() if '=' in l)
        if fields:
            check(fields['protocol']=='phase9-result-v1','strict MAIN receipt protocol')
            check(int(fields['rc'])==rc,'MAIN result/exit consistent '+self.scenario)
        return rc,fields

    def events_read(self):return self.events.read_text().splitlines() if self.events.exists() else []


def local_contracts():
    # Retained Execute publication topology from the saved 2026-09-23 MAIN
    # node_jobs/1790089829-23820 capture; identities/logs are synthetic.
    # This traverses the actual frozen Q in the MAIN M/F/Q/cleaner cohort.
    for busybox in (False, True):
        n=Main(busybox=busybox)
        try:
            check(not (n.runtime/'locks/dhcp_hold').exists(),
                  f'absent DHCP bookkeeping root in safe MAIN fixture busybox={busybox}')
            run=n.runtime/'node_jobs/1790089829-23820'
            for leaf in ('ready','launched'):
                write(run/leaf,'1 192.0.2.1\n')
            for phase in ('prepare','launch','status'):
                pool=run/phase; job=pool/'node_1'
                write(pool/'.nodes.23820','1 192.0.2.1\n')
                write(job/'result',f'format_version=2\nstate=ok\nnode_id=1\nphase={phase}\nstarted_epoch=100\ncompleted_epoch=101\nreason=worker-ok\nowner_pid=2147483647\nowner_start=1\nowner_nonce=fixture.2147483647.1\n')
                for leaf,value in (('wrapper.pid','2147483647'),('wrapper.proc_start_time','1'),('child.pid','2147483647'),('child.proc_start_time','1')):
                    write(job/leaf,value+'\n')
                for leaf in ('stdout.log','cli.log','vlan.log'):
                    write(job/leaf,'')
                (job/'ssh').mkdir(mode=0o700)
                forensic_dir=job/'ssh_forensics'
                forensic_dir.mkdir(mode=0o700)
                forensic_record='\n'.join((
                    'format=1',f'phase=execute-{phase}','status=failure','return_code=255','node=1',
                    'canonical_endpoint=fixture-endpoint','selected_endpoint=fixture-endpoint','ssh_user=fixture','ssh_port=22',
                    'ssh_settings_path=/tmp/mervlan-fixture/settings.json',
                    'ssh_key_path=/tmp/mervlan-fixture/id_ed25519','ssh_key_type=unknown','ssh_key_mode=unknown',
                    'ssh_key_uid=unknown','ssh_key_size=unknown','ssh_key_fingerprint=fixture',
                    'trust_path=/tmp/mervlan-fixture/ssh_trust','trust_record_fingerprint=fixture',
                    'dbclient_binary=dbclient','dbclient_options=BatchMode=yes,PasswordAuthentication=no',
                    'maintenance_sync=0','maintenance_delegation=none','action_lock_mode=none','tmpdir=/tmp/mervlan_tmp',
                    'ssh_tmpdir=/tmp/mervlan_tmp/node_jobs/fixture/node_1/ssh',
                    'worker_dir=/tmp/mervlan_tmp/node_jobs/fixture/node_1','working_directory=/tmp/mervlan-fixture',
                    'umask=77','classification=publickey-rejected',
                    'sanitized_stderr=synthetic deterministic diagnostic'))+'\n'
                forensic_path=forensic_dir/'attempt.2147483647.1.log'
                write(forensic_path,forensic_record)
                check(forensic_dir.is_dir() and not forensic_dir.is_symlink() and forensic_path.is_file() and
                      not forensic_path.is_symlink() and forensic_path.stat().st_size>0,
                      f'producer-compatible ssh_forensics fixture exists in {phase} before MAIN Q')
                if phase=='prepare':write(job/'settings.expected','')
            n.launch();rc,fields=n.finish();ev=n.events_read()
            tag=f'completed recursive Execute tree busybox={busybox}'
            check(rc==0 and fields['class']=='SUCCESS',tag+' MAIN success')
            check(ev[:3]==['M','F','Q:IDLE'],tag+' frozen Q idle under M/F')
            calls=(n.root/'ebtables.calls').read_text()
            check('-L FORWARD' in calls and '-L INPUT' in calls,
                  tag+' frozen Q checked external DHCP rule state')
            check('runtime-removed' in ev and not n.runtime.exists(),tag+' cleaner terminal')
            check(fields['state']=='FULL_UNINSTALL_COMPLETE' and not n.f.exists(),tag+' exact final release')
        finally:n.close()
    for busybox in (False, True):
        n=Main('dhcp-rules-present',busybox=busybox)
        try:
            check(not (n.runtime/'locks/dhcp_hold').exists(),
                  f'absent DHCP bookkeeping root in unresolved MAIN fixture busybox={busybox}')
            n.launch();rc,fields=n.finish();ev=n.events_read()
            check(rc==2 and fields['class']=='REFUSED',
                  f'lingering DHCP Hold rules refuse frozen MAIN busybox={busybox}')
            check(any(x=='Q:BLOCKING' for x in ev) and 'cleaner' not in ev,
                  f'Q blocks before cleaner when DHCP rules outlive bookkeeping busybox={busybox}')
            check(n.runtime.exists() and (n.root/'jffs/addons/mervlan').exists(),
                  f'DHCP rule refusal leaves runtime and addon untouched busybox={busybox}')
            calls=(n.root/'ebtables.calls').read_text()
            check('-L FORWARD' in calls and '-L INPUT' in calls,
                  f'frozen Q reached external DHCP rule classifier busybox={busybox}')
        finally:n.close()
    n=Main('owner-rename')
    try:
        n.launch();rc,_=n.finish()
        check(rc==4 and not n.m.exists() and not n.f.exists() and not n.events_read(),
              'owner publication failure precedes MAIN ownership/destruction')
        check(not (n.stage/'phase9.claim/owner').exists() and
              (n.stage/'phase9.claim/owner.tmp').is_file(),
              'failed owner rename preserves private evidence without a partial final record')
    finally:n.close()
    for scenario in ('success','failure','ambiguous','claim-start-tamper','live-m','existing-f','malformed-m','malformed-f','file-f','symlink-f','unknown-q','m-replace','f-replace','cleaner-drift','f-release-obstructed','f-terminal-replace','publish-create','publish-rename','predestruct-publish-create','predestruct-publish-rename','terminal-run','terminal-pid','terminal-rc','terminal-record'):
        n=Main(scenario)
        try:
            if scenario=='live-m':n.owner(n.m)
            if scenario=='existing-f':n.f.mkdir(mode=0o700)
            if scenario=='malformed-m':n.m.mkdir(mode=0o700);write(n.m/'owner','bad\n')
            if scenario=='malformed-f':n.f.mkdir(mode=0o700);write(n.f/'owner','bad\n')
            if scenario=='file-f':write(n.f,'obstruction\n')
            if scenario=='symlink-f':n.f.symlink_to(n.root/'foreign')
            if scenario.startswith('predestruct-publish-') or scenario=='unknown-q':write(n.runtime/'locks/unsupported.lock','unknown\n')
            n.launch();rc,fields=n.finish();ev=n.events_read()
            expected='SUCCESS' if scenario=='success' else 'FAILED_TERMINAL' if scenario=='failure' else 'REFUSED' if scenario in ('live-m','existing-f','malformed-m','malformed-f','file-f','symlink-f','unknown-q','cleaner-drift','predestruct-publish-create','predestruct-publish-rename') else 'UNVERIFIED'
            check(rc=={'SUCCESS':0,'FAILED_TERMINAL':3,'REFUSED':2,'UNVERIFIED':4}[expected],scenario+' exit '+str(rc)+' '+(n.root/'stderr').read_text())
            if fields:check(fields['class']==expected,scenario+' class')
            if scenario in ('success','failure','ambiguous','claim-start-tamper','f-release-obstructed','f-terminal-replace','publish-create','publish-rename','terminal-run','terminal-pid','terminal-rc','terminal-record'):
                check(ev[:3]==['M','F','Q:IDLE'],'MAIN M F Q order '+scenario)
                check('runtime-removed' in ev and not n.runtime.exists(),'real runtime deletion '+scenario)
                check(not (n.root/'jffs/addons/mervlan').exists(),'real addon deletion '+scenario)
                if expected in ('SUCCESS','FAILED_TERMINAL'):
                    check(ev.index('release-F')>ev.index('decision:'+expected)>ev.index('runtime-removed'),'decision before exact last F release '+scenario)
                    check(not n.f.exists(),'F released '+scenario)
                else:check(n.f.exists(),'ambiguous MAIN retains F '+scenario)
            else:check('cleaner' not in ev,'refusal keeps MAIN intact '+scenario)
            if scenario in ('unknown-q','cleaner-drift','predestruct-publish-create','predestruct-publish-rename'):check(not n.f.exists() and not n.m.exists(),'controlled predestructive refusal releases exact M/F')
            if scenario=='success':
                owner=(n.stage/'phase9.claim/owner').read_text()
                check(owner==f'{n.run}:{fields["wrapper_pid"]}:{fields["wrapper_start"]}\n' and
                      not (n.stage/'phase9.claim/owner.tmp').exists(),
                      'owner record atomically published with exact terminal wrapper identity')
                d=(n.stage/'phase9.claim/decision').read_text()
                check('protocol=phase9-decision-v1' in d and 'class=CLEANER_SUCCESS' in d and 'state=MAIN_CLEANER_TERMINAL_SUCCESS_F_HELD' in d and 'FULL_UNINSTALL_COMPLETE' not in d,'persistent decision cannot lie about release')
                check(fields['state']=='FULL_UNINSTALL_COMPLETE' and fields['fence']=='released','completion receipt only after F release')
            if scenario=='f-terminal-replace':check((n.f/'owner').read_text()=='foreign\n','foreign final F untouched')
        finally:n.close()

    for scenario in ('handoff-tamper','handoff-duplicate','old-ready','node-missing','node-refused','node-failed','node-unverified','node-digest','node-run','node-extra','node-outside-range','node-extra-context','node-result-link','policy-mismatch','generation-mismatch','wrapper-tamper','helper-tamper'):
        n=Main()
        try:
            p=n.stage/'node-phase-complete'
            if scenario.startswith('handoff-'):p.write_text(p.read_text()+('run='+n.run+'\n' if scenario.endswith('duplicate') else 'drift\n'))
            if scenario=='old-ready':
                p=n.stage/'ready';p.write_text(p.read_text().replace('phase7-v3','phase7-v2').replace('full-terminal-v1','node-cleanup-v1'));n.ready=digest(p)
            if scenario=='node-missing':(n.stage/'phase8.claim/NODE2.result').unlink()
            if scenario in ('node-refused','node-failed','node-unverified','node-run','node-digest'):
                p=n.stage/'phase8.claim/NODE2.result';s=p.read_text()
                s=s.replace('class=SUCCESS','class='+{'node-refused':'REFUSED','node-failed':'FAILED_TERMINAL','node-unverified':'UNVERIFIED'}.get(scenario,'SUCCESS'))
                if scenario=='node-run':s=s.replace('run='+n.run,'run=9.9.9.9')
                if scenario=='node-digest':s+='reason=other\n'
                p.write_text(s)
                n.rebind_results()
            if scenario=='node-extra':write(n.stage/'phase8.claim/NODE4.result','unexpected\n')
            if scenario=='node-outside-range':write(n.stage/'phase8.claim/NODE11.result','unexpected\n')
            if scenario=='node-extra-context':write(n.stage/'phase8.claim/NODE4.context','unexpected\n')
            if scenario=='node-result-link':
                p=n.stage/'phase8.claim/NODE2.result';p.rename(n.root/'result');p.symlink_to(n.root/'result')
            if scenario in ('policy-mismatch','generation-mismatch'):
                p.write_text(p.read_text().replace('backup_policy=KEEP','backup_policy=DELETE') if scenario=='policy-mismatch' else p.read_text().replace('generation='+n.generation,'generation='+'b'*64));n.handoff=digest(p)
            if scenario=='wrapper-tamper':p=n.stage/'main/terminal.sh';p.write_text(p.read_text()+'# drift\n')
            if scenario=='helper-tamper':p=n.stage/'main/lib_owner_lock.sh';p.write_text(p.read_text()+'# drift\n')
            n.launch();rc,_=n.finish()
            check(rc==2 and not n.m.exists() and not n.f.exists() and not n.events_read(),'strict gate blocks ownership '+scenario)
        finally:n.close()

    for nodes,policy,bb in ((0,'KEEP',False),(3,'DELETE',False),(3,'KEEP',True)):
        n=Main(nodes=nodes,policy=policy,busybox=bb)
        try:
            backup=n.root/'jffs/addons/mervlan_backups';backup.mkdir();write(backup/'retained','backup')
            n.launch();rc,f=n.finish();check(rc==0,'zero/DELETE/BusyBox MAIN success '+str((nodes,policy,bb)))
            check(f['backup_policy']==policy,'frozen MAIN policy')
            check(backup.exists()==(policy=='KEEP'),'actual backup KEEP/DELETE mapping')
            check(not (n.root/'reboot').exists(),'no MAIN internal reboot')
        finally:n.close()

    n=Main();r=subprocess.Popen(['sleep','3'])
    try:
        lock=n.runtime/'locks/mervlan_action.lock';n.owner(lock,r.pid)
        n.launch();wait_file(n.f,n.process)
        check(not n.clean_dir.exists(),'Q waits for real R under M/F')
        r.wait();shutil.rmtree(lock)
        rc,_=n.finish();ev=n.events_read()
        check(rc==0 and 'Q:BUSY' in ev and ev.index('cleaner')>ev.index('Q:IDLE'),'real R drains before cleaner')
    finally:
        if r.poll() is None:r.kill();r.wait()
        n.close()

    n=Main();r=subprocess.Popen(['sleep','15'])
    try:
        n.owner(n.runtime/'locks/mervlan_action.lock',r.pid)
        n.launch();rc,f=n.finish()
        check(rc==2 and f['reason']=='quiescence-timeout','real R bounded Q timeout')
        check(not n.f.exists() and not n.m.exists() and r.poll() is None,'real R timeout releases own M/F without killing R')
    finally:
        r.kill();r.wait();n.close()

    n=Main('pause-f')
    try:
        n.launch();wait_file(n.root/'paused',n.process)
        admission=(BASE/'settings/lib_mutation_admission.sh').read_text()
        admission=re.sub(r'(?<!\\)/(?:jffs|www|tmp)(?=[/\".*|)])',lambda m:str(n.root)+m.group(),admission)
        write(n.root/'admission.sh',admission)
        action=n.runtime/'locks/mervlan_action.lock'
        prefix='; '.join('. '+str(n.stage/'main'/('lib_'+x+'.sh')) for x in ('selftest_context','identity','owner_lock','action_lock','continuation','full_fence','update_state'))
        cmd=f'{prefix}; . {n.root}/admission.sh; merv_owner_lock_acquire {action} 0 0 test || exit 9; merv_mutation_admission_check_fm; rc=$?; [ "$MERV_MUTATION_ADMISSION_REASON" = full-fence-live ] || exit 8; exit "$rc"'
        result=subprocess.run(['/bin/sh','-c',cmd],capture_output=True,text=True)
        check(result.returncode==1,'MAIN F rejects new mutation after R ownership')
        n.process.kill();n.process.wait()
        again=subprocess.run(n.shell+[str(n.stage/'main/terminal.sh'),'--run',str(n.stage),n.ready,n.handoff],capture_output=True)
        check(again.returncode==4 and n.f.exists(),'ambiguous MAIN one-shot claim prevents automated replay')
    finally:n.close()

    for scenario in ('pause-before-m','pause-m','pause-f','pause-after-q','pause-cleaner','pause-terminal','pause-release','pause-released'):
        n=Main(scenario)
        try:
            n.launch();wait_file(n.root/'paused',n.process);n.process.kill();n.process.wait()
            if scenario=='pause-before-m':check(not n.f.exists() and not n.m.exists(),'SIGKILL before M owns nothing')
            elif scenario=='pause-m':check(not n.f.exists() and n.m.exists(),'SIGKILL M-only leaves dead owner')
            elif scenario=='pause-released':check(not n.f.exists(),'SIGKILL after release never recreates F')
            else:check(n.f.exists(),'SIGKILL retains F '+scenario)
            check('FULL_UNINSTALL_COMPLETE' not in (n.root/'stdout').read_text(),'no premature completion '+scenario)
            if scenario=='pause-cleaner':wait_file(n.clean_dir/'terminal')
        finally:n.close()
    n=Main()
    try:
        n.process=subprocess.Popen(n.shell+[str(n.stage/'main/terminal.sh'),'--run',str(n.stage),n.ready,n.handoff],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
        n.process.stdout.close()
        rc=n.process.wait(timeout=25)
        check(rc==0 and not n.f.exists(),'postrelease broken reporting pipe cannot change successful exit')
    finally:n.close()
    import signal
    for scenario in ('pause-before-m','pause-m','pause-f','pause-after-q','pause-cleaner','pause-terminal'):
        n=Main(scenario)
        try:
            n.launch();wait_file(n.root/'paused',n.process);n.process.send_signal(signal.SIGTERM);n.process.wait(timeout=10)
            if scenario in ('pause-before-m','pause-m'):check(not n.f.exists(),'TERM before F leaves F absent '+scenario)
            else:check(n.f.exists(),'TERM before exact release retains F '+scenario)
            if scenario=='pause-cleaner':wait_file(n.clean_dir/'terminal')
        finally:n.close()
    print('PHASE9_LOCAL_CHECKS',COUNT,flush=True)

def finalization_signal_contracts():
    import signal
    begin=COUNT
    signals=(signal.SIGTERM,signal.SIGHUP,signal.SIGINT)
    # Each barrier is a FIFO handshake in the actual shell process. No timing
    # guess: receipt stays blocked until the signal is sent and FIFO released.
    def run(outcome,boundary,sig,fault=None,busybox=False,publish_failure=False,kill=False):
        scenario='failure' if outcome=='FAILED_TERMINAL' else 'ambiguous' if outcome=='UNVERIFIED' else 'success'
        if publish_failure:scenario='predestruct-publish-create'
        n=Main(scenario,finalization=boundary,outcome=outcome,release_fault=fault,busybox=busybox)
        tag=f'{outcome}/{boundary}/{sig.name}/{fault or "normal"}/busybox={busybox}/publish_failure={publish_failure}'
        try:
            n.launch();wait_file(n.root/'paused',n.process)
            decision=n.stage/'phase9.claim/decision'
            if not publish_failure:
                check(decision.is_file(),'verified pre-release decision '+tag)
                data=dict(l.split('=',1) for l in decision.read_text().splitlines())
                check(data['class']==('CLEANER_SUCCESS' if outcome=='SUCCESS' else outcome),'decision classification '+tag)
                check(data['fence']==('retained' if outcome=='UNVERIFIED' else 'owned'),'decision records held authority '+tag)
            check(n.f.exists() == (boundary!='post-release'),'exact boundary F state '+tag)
            check('protocol=phase9-result-v1' not in (n.root/'stdout').read_text(),'no premature receipt '+tag)
            n.process.send_signal(sig)
            if boundary=='before-commit' or outcome=='UNVERIFIED' or kill:
                rc=n.process.wait(timeout=10)
                check(rc==(-signal.SIGKILL if kill else 4),'uncommitted/ambiguous signal exit '+tag)
                check(n.f.exists() == (boundary!='post-release'),'fail-closed or unavoidable kill disposition '+tag)
                check('FULL_UNINSTALL_COMPLETE' not in (n.root/'stdout').read_text(),'no false completion '+tag)
                return
            # Catchable signals must not finish the process while this barrier
            # remains closed. Release is permitted only after the FIFO resume.
            time.sleep(.1)
            check(n.process.poll() is None,'committed signal cannot abort '+tag)
            with (n.root/'resume').open('w') as f:f.write('continue\n')
            rc,fields=n.finish()
            expected='UNVERIFIED' if fault else outcome
            check(fields['class']==expected and rc=={'SUCCESS':0,'FAILED_TERMINAL':3,'REFUSED':2,'UNVERIFIED':4}[expected],'final class/exit '+tag)
            check(fields['fence']==('retained' if fault else 'released'),'actual final F disposition '+tag)
            check(n.f.exists()==bool(fault),'final F existence '+tag)
            check(('FULL_UNINSTALL_COMPLETE' in (n.root/'stdout').read_text())==(expected=='SUCCESS'),'completion only exact success '+tag)
            if fault=='foreign':check((n.f/'owner').read_text()=='foreign\n','foreign F untouched '+tag)
            if outcome=='REFUSED':check('cleaner' not in n.events_read() and (n.root/'jffs/addons/mervlan').exists(),'refusal never cleans MAIN '+tag)
        finally:n.close()
    for outcome in ('SUCCESS','FAILED_TERMINAL','REFUSED'):
        for sig in signals:
            run(outcome,'before-commit',sig)
            for boundary in ('committed','during-release','post-release'):
                run(outcome,boundary,sig)
    for sig in signals:
        for fault in ('fail','foreign'):
            run('SUCCESS','during-release',sig,fault=fault)
        for boundary in ('before-commit','committed'):
            run('UNVERIFIED',boundary,sig)
        # Known no-entry refusal must release safely even if decision publication
        # failed; this existing exception must also close the catchable gap.
        for boundary in ('before-commit','committed','during-release','post-release'):
            run('REFUSED',boundary,sig,publish_failure=True)
    for boundary in ('committed','during-release','post-release'):
        run('SUCCESS',boundary,signal.SIGKILL,kill=True)
        run('SUCCESS',boundary,signal.SIGTERM,busybox=True)
    print('PHASE9_SIGNAL_CHECKS',COUNT-begin,flush=True)
    print('PHASE9_ALL_CHECKS',COUNT,flush=True)

if __name__=='__main__':
    if '--signals-only' not in sys.argv:local_contracts()
    finalization_signal_contracts()
