from full_programs import full_program, TOPOLOGY
"""Public Full pipeline fixtures reuse the Phase-7/8 fake transport substrate.
The real public entry/controller/bootstrap/NODE coordinator/MAIN wrapper and
cleaner execute. No fixture ever reaches production roots or a real router.
"""
import inspect
from pathlib import Path
import re
import subprocess
import sys
import full_nodes_phase8_contract as p8
from full_main_phase9_contract import check


def adapt(source):
    # Before any bootstrap: private fixture copies of MAIN-only code/helpers
    # use relocated canonical device authority. NODE execution remains its
    # separately tested protocol; the fake remote process emits its receipt.
    setup=r'''
        (root/'events').touch()
        runtime=root/'tmp/mervlan_tmp'
        (runtime/'locks').mkdir(parents=True)
        (root/'jffs/addons/mervlan_state').mkdir(parents=True)
        (root/'www/user').mkdir(parents=True)
        toolbin=root/'toolbin';toolbin.mkdir()
        no_dhcp_hold_rules="""case "${3:-}:${4:-}" in
  -L:MERV_DHCP_HOLD) exit 1 ;;
  -L:FORWARD|-L:INPUT) exit 0 ;;
  *) exit 1 ;;
esac"""
        for name,body in {'logger':'exit 0','cru':'exit 0','ebtables':no_dhcp_hold_rules,'sync':'exit 0','reboot':f'touch {root}/reboot'}.items():
            p=toolbin/name;p.write_text('#!/bin/sh\n'+body+'\n');p.chmod(0o700)
        def local_paths(text):
            for path in ('/tmp/mervlan_tmp','/tmp/.mervlan-full-uninstall.lock','/tmp/.mervlan-full-cleanup.','/jffs/addons/mervlan','/www/'):
                text=text.replace(path,str(root)+path)
            return text
        for lib in ('identity','owner_lock','action_lock','full_fence','update_state','continuation','radio','mervqt','settings_reconcile','maintenance_quiesce'):
            p=base/f'settings/lib_{lib}.sh';p.write_text(local_paths(p.read_text()))
        p=base/'settings/lib_full_uninstall.sh';s=local_paths(p.read_text())
        s=s.replace('VAR_SETTINGS_LOADED=1',
                    'VAR_SETTINGS_LOADED=1\nMERV_DHCP_HOLD_CHAIN=MERV_DHCP_HOLD',1)
        s=s.replace('PATH=/usr/sbin:',f'PATH={toolbin}:/usr/sbin:')
        s=s.replace('mw_mstart=$MERV_LOCK_START;',f'printf "MAIN-M\\n" >> {root}/destruction-order\nsha256sum {root}/events > {root}/events-before-main\nmw_mstart=$MERV_LOCK_START;')
        s=s.replace('mw_entered=yes',f'printf "MAIN-CLEANER\\n" >> {root}/destruction-order\nmw_entered=yes')
        p.write_text(s)
        if scenario=='main-after-handoff':
            p=base/'uninstall.sh'
            p.write_text(p.read_text().replace('# No remote operations or source generation changes beyond this point.', '# No remote operations or source generation changes beyond this point.\n'+'printf "# drift\\n" >> "$fc_root/main/terminal.sh"'))
        p=base/'functions/mervlan_full_cleanup.sh';s=p.read_text()
        s=re.sub(r'(?<!\\)/(?:jffs|www|tmp)(?=[/\".*|)])',lambda m:str(root)+m.group(),s)
        s=s.replace('PATH="/usr/sbin:',f'PATH="{toolbin}:/usr/sbin:',1)
        s=re.sub(r'^find_mervlan_processes\(\) \{\n.*?^\}', 'find_mervlan_processes() { printf "\\n"; }',s,flags=re.M|re.S)
        s=s.replace('    remove_glob_list "$MERVLAN_VOLATILE_GLOBS"\n}',f'    remove_glob_list "$MERVLAN_VOLATILE_GLOBS"\n    rm -rf {base}\n}}')
        p.write_text(s)
        public=root/'uninstall.sh'
        public.write_text((base/'uninstall.sh').read_text().replace('MERV_BASE="/jffs/addons/mervlan"','MERV_BASE="'+str(base)+'"',1))
        if scenario=='main-fence':(root/'tmp/.mervlan-full-uninstall.lock').mkdir(mode=0o700)
'''
    marker="        result = subprocess.run(['/bin/sh',str(BASE/'dev-tools/tests/local/full_fixture_entry.sh'),'--prepare'],"
    pos=source.index(marker)
    source=source[:pos]+setup+source[pos:]
    source=source.replace(marker,"        result = subprocess.run(['/bin/sh',str(public),'full']+([] if scenario=='interactive' else ['--yes'])+(['--delete-backups'] if scenario=='delete' else []), input=('UNINSTALL\\nn\\n' if scenario=='interactive' else None),")
    end=source.index('        if (result.returncode == 0) != expected:')
    source=source[:end]+r'''
        success=scenario in ('ok','delete','interactive')
        check((result.returncode==0)==success,'public '+scenario+' '+str(nodes)+' rc='+str(result.returncode)+' '+result.stderr)
        runs=list(root.glob('.mervlan-full.*'));check(len(runs)==1,'public one immutable run')
        run=runs[0]
        order=(root/'destruction-order').read_text().splitlines() if (root/'destruction-order').exists() else []
        expected_order=['NODE'+str(i) for i in range(1,nodes+1)]+['MAIN-M','MAIN-CLEANER'] if success else ['NODE1','NODE2'] if (scenario.startswith('node-') or scenario=='transport-loss') else ['NODE1','NODE2','NODE3','MAIN-M'] if scenario=='main-fence' else ['NODE1','NODE2','NODE3'] if scenario=='main-after-handoff' else []
        check(order==expected_order,'public exact MAIN-last order '+str(order))
        check(('Full uninstall complete.' in result.stdout)==success,'public Full completion only definitive MAIN success')
        check(not (root/'reboot').exists(),'public --yes never surprise reboots')
        if success:
            check(not base.exists(),'public installed source deletion survives exec terminal handoff')
            check(not runtime.exists(),'public runtime root deleted')
            check(not (root/'tmp/.mervlan-full-uninstall.lock').exists(),'public F released last')
            check('state=MAIN_CLEANER_TERMINAL_SUCCESS_F_HELD' in (run/'phase9.claim/decision').read_text(),'public two-stage evidence')
            # Last transport event precedes MAIN ownership; no remote calls at
            # terminal execution. Fake client timestamps each call.
            check((run/'node-phase-complete').exists(),'same run Phase8 handoff')
            check((root/'events-before-main').read_text().split()[0]==hashlib.sha256((root/'events').read_bytes()).hexdigest(),'no remote operations after MAIN ownership')
        elif (scenario.startswith('node-') or scenario=='transport-loss'):
            check(not (run/'phase9.claim').exists(),'NODE failure never starts MAIN wrapper')
            check(base.exists() and runtime.exists(),'MAIN intact after NODE abort')
        elif scenario=='main-after-handoff':
            check('MAIN REFUSED: main-wrapper-changed' in result.stderr,'explicit terminal artifact refusal after NODE handoff')
            check(base.exists() and runtime.exists() and not (run/'phase9.claim').exists(),'tampered terminal never executes or owns MAIN')
        elif scenario=='main-fence':
            check(base.exists() and runtime.exists(),'MAIN refusal after all NODE success')
            check((root/'tmp/.mervlan-full-uninstall.lock').exists(),'pre-existing F preserved')
        if scenario=='delete':
            check('backup_policy=DELETE' in result.stdout,'public frozen DELETE reaches MAIN')
            for i in range(1,nodes+1):check('backup_policy=DELETE' in (run/f'phase8.claim/NODE{i}.result').read_text(),'public same DELETE reaches NODE'+str(i))
        print('PASS PUBLIC',scenario,nodes,flush=True)
'''
    return source

# Reuse only the focused fixture builder, replacing its execution/assertions.
code=inspect.getsource(p8.coordinator_contracts)
code=code.replace('    namespace.update(BASE=BASE,check=check,CLIENT=client)', "    client=client.replace(\"backup_policy='KEEP'\", \"backup_policy=fields['backup_policy']\")\n    namespace.update(BASE=BASE,check=check,CLIENT=client)")
code=code.replace('    exec(source,namespace)','    source=adapt(source)\n    exec(source,namespace)')
start=code.index('    only=next(')
code=code[:start]+'''    only=next((a.split('=',1)[1] for a in sys.argv if a.startswith('--case=')),None)
    if only is None:
        for nodes in (0,3):namespace['run_fixture'](nodes=nodes)
    for scenario in ('delete','interactive','node-refused','node-failed','node-unverified','transport-loss','main-fence','main-after-handoff'):
        if only is None or only==scenario:namespace['run_fixture'](scenario=scenario,nodes=3)
'''
namespace=dict(vars(p8),adapt=adapt,check=check)
exec(code,namespace)
namespace['coordinator_contracts']()

# Real public route regression in source-isolated shell fixtures. All source
# before the legacy admit boundary executes. At that boundary a fixture exits,
# proving standard/reinstall never call the new Full pipeline.
import tempfile
with tempfile.TemporaryDirectory(prefix='mervlan-phase9-public-mode.',dir='/tmp') as tmp:
    root=Path(tmp);text=(p8.BASE/'uninstall.sh').read_text()
    text=text.replace('. /usr/sbin/helper.sh','printf "legacy-helper\\n"')
    text=text.replace('MERV_BASE="/jffs/addons/mervlan"','MERV_BASE="'+str(root)+'/addon"',1)
    text=text[:text.index('uninstall_maintenance_admit || exit 1')]+'printf "legacy-admission:%s\\n" "$ACTION"\nexit 0\n'
    # The parsed Full entry cannot run accidentally: its target is deliberately
    # absent in this standard/reinstall fixture.
    p=root/'uninstall.sh';p.write_text(text)
    for mode in ('standard','reinstall'):
        r=subprocess.run(['/bin/sh',str(p),mode],capture_output=True,text=True)
        check(r.returncode==0 and 'legacy-admission:'+mode in r.stdout,'public '+mode+' uses unchanged legacy admission')
    r=subprocess.run(['/bin/sh',str(p),'full'],input='CANCEL\n',capture_output=True,text=True)
    check(r.returncode==0 and 'cancelled' in r.stdout and 'legacy-admission' not in r.stdout,'public cancellation precedes bootstrap/destruction')
    for opts in (['full','--delete-backups'],['full','--typo'],['standard','--yes'],['full','--yes','--keep-backups','--delete-backups']):
        r=subprocess.run(['/bin/sh',str(p)]+opts,capture_output=True,text=True)
        check(r.returncode==2 and 'legacy-admission' not in r.stdout,'strict public options '+str(opts))
print('PHASE9_PUBLIC_COMPLETE',flush=True)
