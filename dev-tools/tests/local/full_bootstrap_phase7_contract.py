from full_programs import full_program, TOPOLOGY
"""Phase 7: production bootstrap + canonical probe + real inert shell staging.

No hardware or production paths. dbclient is the sole fixture transport; it
checks key-only argv and pinned known_hosts, emits real probe process state,
and executes the actual closed staging payload under per-node fixture roots.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import time
from urllib.parse import quote

BASE = Path(__file__).resolve().parents[3]
CHECKS = 0


def check(condition, message):
    global CHECKS
    CHECKS += 1
    if not condition:
        raise AssertionError(message)


def parse(raw, ok=True, contains=None):
    for cmd in (["awk"], ["busybox", "awk"]):
        result = subprocess.run(cmd + ["-f", str(TOPOLOGY)],
                                input=raw, text=True, capture_output=True, env=dict(os.environ, LC_ALL="C"))
        check((result.returncode == 0) == ok, f"parser {cmd}: {raw!r}: {result.stderr}")
        if contains is not None:
            check(contains in result.stdout, f"parser output {result.stdout!r}")


parse('{"NODE1":"192.0.2.1"}', contains="NODE1 192.0.2.1 none")
parse('{"Nodes":{"NODE1":"192.0.2.2"},"NODE1":"192.0.2.1"}', contains="NODE1 192.0.2.2")
parse('{"Nodes":{"NODE1":"none"},"NODE1":"192.0.2.1"}', contains="COUNT 0")
parse('{"Nodes":{},"NODE1":"192.0.2.1"}', contains="NODE1 192.0.2.1")
parse('{"NODE1_IP":"192.0.2.1"}', contains="COUNT 0")
parse('{}', contains="COUNT 0")
parse('{"Nodes":{"NODE10":"192.0.2.10"}}', contains="NODE10 192.0.2.10")
parse('{"unknown":"é😀"}', contains="COUNT 0")
parse('{"unknown":{"nested":[1,true,false,null,{"str":"\\u00e9"}]}}', contains="COUNT 0")
parse('{"Nodes":{"NODE1":"192.0.2.1"},"AUTO_NODE1_MAC":"aa:bb:cc:dd:ee:ff"}', contains="AA:BB:CC:DD:EE:FF")
parse('{"VLAN":{"WAN_Native":{"WAN_NATIVE_MAIN":"20"}},"Nodes":{"NODE1":"192.0.2.1","NODE1_ROLE":"aimesh","NODE1_WAN_NATIVE_IP":"198.51.100.1"}}', contains="aimesh none 20 198.51.100.1")
for raw in (
    '{"Nodes":{"NODE1":null},"NODE1":"192.0.2.1"}',
    '{"Nodes":{"NODE1":{}},"NODE1":"192.0.2.1"}',
    '{"Nodes":{"NODE1":[]},"NODE1":"192.0.2.1"}',
    '{"Nodes":null,"NODE1":"192.0.2.1"}',
    '{"Nodes":[],"NODE1":"192.0.2.1"}',
    '{"Nodes":42,"NODE1":"192.0.2.1"}',
    '{"Nodes":{"NODE1":"192.0.2.1","NODE2":"192.0.2.1"}}',
    '{"Nodes":{"NODE11":"192.0.2.11"}}',
    '{"Nodes":{"NODE11":"none"}}',
    '{"NODE11":"192.0.2.11"}',
    '{"Nodes":{},"Nodes":{}}',
    '{"NODE1":"none","NODE1":"192.0.2.1"}',
    '{"Nodes":{"NODE1":"none","NODE\\u0031":"192.0.2.1"}}',
    '{"SSH":{"NODE_SSH_USER":"admin","NODE_SSH_USER":"root"}}',
    '{"SSH":{"NODE_SSH_PORT":"22","NODE_SSH_PORT":"2222"}}',
    '{"Nodes":{"NODE1":"192.0.2.1"},"AUTO_NODE1_MAC":"bad"}',
    '{"Nodes":{"NODE1":"192.0.2.1","NODE2":"192.0.2.2"},"AUTO_NODE1_MAC":"AA:BB:CC:DD:EE:FF","AUTO_NODE2_MAC":"AA:BB:CC:DD:EE:FF"}',
    '{"VLAN":{"WAN_Native":{"WAN_NATIVE_NODE1":"20"}},"NODE1":"192.0.2.1"}',
    '{"NODE1":"192.0.2.1","NODE1_WAN_NATIVE_IP":"256.1.1.1"}',
    '{"NODE1":"192.0.2.1","NODE1_ROLE":"unknown"}',
    '{"SSH":null}', '{"SSH":{"NODE_SSH_PORT":"0"}}',
    '{"SSH":{"NODE_SSH_USER":"admin;id"}}',
    '{"NODE1":"192.0.2.1"} junk', '{"NODE1":"192.0.2.1",}',
    '{"a":"\\q"}', '{"a":01}', '{"a":"\\ud800"}',
    '{"a":truefalse}', '{"a":"raw\nnewline"}', '[]', '',
):
    parse(raw, ok=False)
for ip in ("", " ", "192.0.2.256", "192.0.2", "192.0.2.1;id", "192.0.2.01", "999999999999.0.2.1", "host.example", "-1.0.2.1"):
    parse(json.dumps({"Nodes": {"NODE1": ip}}), ok=False)
print("PASS strict topology matrix (host and BusyBox awk)", flush=True)

CLIENT = r'''#!/usr/bin/python3
import base64, hashlib, json, os, pathlib, subprocess, sys, time
from urllib.parse import quote
root = pathlib.Path(__file__).resolve().parents[2]
cfg = json.loads((root/'fixture.json').read_text())
args = sys.argv[1:]
assert args.count('BatchMode=yes') == 1 and args.count('PasswordAuthentication=no') == 1
assert not any(k in os.environ for k in ('DROPBEAR_PASSWORD','SSH_ASKPASS','DISPLAY','SSH_AUTH_SOCK','SSH_AGENT_PID','SSH_ASKPASS_ALWAYS'))
target = next(a for a in args if '@' in a)
user, host = target.split('@')
assert user == cfg['user']
assert args[args.index('-p')+1] == cfg['port']
assert pathlib.Path(args[args.index('-i')+1]).read_text() == 'fixture-permanent-key'
slot = cfg['hosts'][host]
home = pathlib.Path(os.environ['HOME'])
scenario = cfg.get('scenario','ok')
probe = '-N' in args
command = args[-1] if not probe else ''
op = 'probe' if probe else 'proof' if command.startswith('printf ') else next(x for x in ('init','receive','verify') if "'"+x+"'" in command)
with (root/'events').open('a') as f: f.write(json.dumps({'slot':slot,'host':host,'op':op,'home':str(home)})+'\n')
counts = json.loads((root/'counts').read_text()) if (root/'counts').exists() else {}
counter = host+'-'+op
counts[counter] = counts.get(counter,0)+1
(root/'counts').write_text(json.dumps(counts))
n = counts[counter]
if scenario == 'live-settings' and probe and n == 1:
    (root/'base/settings/settings.json').write_text('{"NODE1":"203.0.113.9","SSH":{"NODE_SSH_USER":"root","NODE_SSH_PORT":"2222"}}')
if scenario == 'source-live-cleaner' and probe and n == 1:
    (root/'base/functions/mervlan_full_cleanup.sh').write_text('# changed installed generation\n')
if scenario == 'source-live-client' and probe and n == 1:
    (root/'base/bin/dbclient').write_text('#!/bin/sh\nexit 99\n')
if scenario == 'fallback' and probe and host.startswith('198.'):
    print('Connect failed',file=sys.stderr); sys.exit(10)
if scenario == 'pinned-failure' and probe and n == 2:
    print('Connect failed',file=sys.stderr); sys.exit(10)
key = cfg['key2'] if scenario == 'host-replaced' and probe and n == 2 else cfg['key']
fp = 'SHA256:'+base64.b64encode(hashlib.sha256(base64.b64decode(key)).digest()).decode().rstrip('=')
token = host if cfg['port']=='22' else '['+host+']:'+cfg['port']
if probe:
    assert '-y' in args
    assert sys.stdin.read() == ''
    if scenario == 'probe-retained': (home/'recovery.pending').write_text('unresolved probe fixture')
    (home/'.ssh/known_hosts').write_text(token+' ssh-ed25519 '+key+'\n')
    print(fp,file=sys.stderr,flush=True)
    time.sleep(5)
    sys.exit(0)
assert '-y' not in args
assert (home/'.ssh/known_hosts').read_text() == token+' ssh-ed25519 '+key+'\n'
if scenario == 'auth-failure' or (scenario == 'partial-trust' and slot == 'NODE3'):
    sys.exit(255)
if op == 'proof':
    if scenario == 'main-helper-tamper' and n == 1:
        (home.parent/'main/stage.sh').write_text('# Full inert stage protocol: phase7-stage-v2\nprintf unsafe\n')
    if n == 1 and scenario.startswith('map-'):
        dest=home.parent/('trust.identity.map' if 'trust' in scenario else 'endpoint.map')
        if scenario.endswith('symlink'):
            data=dest.read_text(); dest.unlink(); (home.parent/'replacement').write_text(data); dest.symlink_to(home.parent/'replacement')
        elif scenario.endswith('mode'): dest.chmod(0o644)
        elif scenario.endswith('foreign'): os.chown(dest,65534,65534)
        elif scenario.endswith('truncate'): dest.write_text('NODE1\n')
        elif scenario.endswith('duplicate'): dest.write_text(dest.read_text()*2)
        elif scenario.endswith('extra'): dest.write_text(dest.read_text()+'UNSUPPORTED field\n')
        elif scenario.endswith('missing'): dest.write_text('')
        elif scenario.endswith('unsafe'): dest.write_text(dest.read_text().replace('192.0.2.1','192.0.2.1;id'))
        elif scenario.endswith('field'): dest.write_text(dest.read_text().replace('NODE1','NODE1 NODE1',1))
        elif scenario.endswith('manifest'):
            dest.write_text(dest.read_text()+'UNSUPPORTED field\n')
            (home.parent/'maps.manifest').write_text('')
    if n == 1 and scenario.startswith('snapshot-'):
        dest=home.parent/'settings.snapshot.json'
        if scenario.endswith('symlink'):
            dest.unlink(); dest.symlink_to(root/'base/settings/settings.json')
        elif scenario.endswith('mode'): dest.chmod(0o644)
        elif scenario.endswith('foreign'): os.chown(dest,65534,65534)
        else: dest.write_text('{}')
    print('PHASE7_AUTH_OK')
    sys.exit(0)
if scenario == 'trust-drift' and op == 'init':
    trust=root/'state/ssh_trust/known_hosts.v1'
    trust.write_text(trust.read_text().replace(quote(cfg['key'],safe='-._~'),quote(cfg['key2'],safe='-._~')))
node = root/'remote'/slot
node.mkdir(parents=True,exist_ok=True)
mapped = command.replace('/tmp/.mervlan-full-stage.', str(node/'stage.'))
rc = subprocess.run(['/bin/sh','-c',mapped],stdin=sys.stdin).returncode
stage = next(node.glob('stage.*')) if list(node.glob('stage.*')) else None
if scenario == 'stage-failure' and slot == 'NODE2' and op == 'receive': sys.exit(255)
if scenario == 'second-auth' and slot == 'NODE3' and op == 'verify' and n == 2: sys.exit(255)
if scenario.startswith('tamper-') and op == 'verify' and n == 1 and rc == 0:
    dest=stage/'cleaner.sh'
    if scenario == 'tamper-byte': dest.write_text(dest.read_text()+'# tampered\n')
    if scenario == 'tamper-mode': dest.chmod(0o700)
    if scenario == 'tamper-symlink': dest.unlink(); dest.symlink_to(root/'base/functions/mervlan_full_cleanup.sh')
    if scenario == 'tamper-helper': (stage/'stage.sh').unlink()
    if scenario == 'tamper-syntax': dest.write_text('if then\n')
    if scenario == 'tamper-protocol': dest.write_text(dest.read_text().replace('phase6-v1','unknown'))
    if scenario == 'tamper-wrapper':
        p=stage/'node.sh';p.write_text(p.read_text()+'# drift\n')
    if scenario == 'tamper-q':
        p=stage/'lib_maintenance_quiesce.sh';p.write_text(p.read_text()+'# drift\n')
    if scenario == 'tamper-extra': (stage/'.unexpected').write_text('extra')
if scenario == 'main-tamper' and op == 'verify' and n == 1:
    (home.parent/'main/cleaner.sh').write_text('# replaced\n')
if scenario == 'stage-existing' and op == 'init': sys.exit(255)
sys.exit(rc)
'''


def key(byte):
    return base64.b64encode(struct.pack('>I', 11) + b'ssh-ed25519' + struct.pack('>I', 32) + bytes([byte])*32).decode()


SOURCES = ['functions/mervlan_full_cleanup.sh', 'functions/ssh_hostkey_probe.sh', 'settings/lib_full_uninstall.sh', 'settings/lib_owner_lock.sh', 'settings/lib_action_lock.sh', 'settings/lib_full_fence.sh', 'settings/lib_update_state.sh', 'settings/lib_continuation.sh', 'settings/lib_radio.sh', 'settings/lib_mervqt.sh', 'settings/lib_settings_reconcile.sh', 'settings/lib_maintenance_quiesce.sh', 'settings/lib_selftest_context.sh', 'settings/lib_identity.sh', 'settings/lib_ssh.sh', 'settings/lib_ssh_trust.sh', 'settings/lib_json.sh', 'uninstall.sh']


def run_fixture(scenario="ok", nodes=1, expected=True, wan=False, port="22", bad_source=None):
    with tempfile.TemporaryDirectory(prefix="mervlan-phase7-", dir="/tmp") as tmp:
        root = Path(tmp)
        root.chmod(0o700)
        base = root/'base'
        for name in SOURCES:
            dest = base/name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(BASE/name, dest)
        (base/'.ssh').mkdir(mode=0o700)
        (base/'.ssh/vlan_manager').write_text('fixture-permanent-key')
        (base/'.ssh/vlan_manager').chmod(0o600)
        (base/'bin').mkdir()
        (base/'bin/dbclient').write_text(CLIENT)
        (base/'bin/dbclient').chmod(0o700)
        settings = {"Nodes": {f"NODE{i}": f"192.0.2.{i}" for i in range(1,nodes+1)},
                    "SSH": {"NODE_SSH_USER": "admin", "NODE_SSH_PORT": port}}
        hosts = {f"192.0.2.{i}": f"NODE{i}" for i in range(1,nodes+1)}
        if wan:
            settings['Nodes']['NODE1_WAN_NATIVE_IP'] = '198.51.100.1'
            settings['VLAN'] = {'WAN_Native': {'WAN_NATIVE_NODE1': '20'}}
            hosts['198.51.100.1'] = 'NODE1'
        for slot in hosts.values():
            active=root/'remote'/slot/'active'
            active.mkdir(parents=True,exist_ok=True)
            (active/'settings').write_text('active-node-settings')
            (active/'hooks').write_text('active-node-hooks')
        snapshot_source = base/'settings/settings.json'
        snapshot_source.write_text(json.dumps(settings))
        snapshot_source.chmod(0o600)
        if bad_source == 'symlink':
            snapshot_source.rename(base/'settings/real.json')
            snapshot_source.symlink_to(base/'settings/real.json')
        if bad_source == 'malformed': snapshot_source.write_text('{bad')
        if bad_source == 'duplicate': snapshot_source.write_text('{"Nodes":{},"Nodes":{}}')
        if bad_source == 'key': (base/'.ssh/vlan_manager').unlink()
        if bad_source == 'key-mode': (base/'.ssh/vlan_manager').chmod(0o644)
        if bad_source == 'cleaner-symlink':
            (base/'functions/mervlan_full_cleanup.sh').unlink()
            (base/'functions/mervlan_full_cleanup.sh').symlink_to(BASE/'functions/mervlan_full_cleanup.sh')
        if bad_source == 'cleaner-syntax':
            (base/'functions/mervlan_full_cleanup.sh').write_text('# Cleaner protocol: phase6-v1\nif then\n')
        if bad_source == 'cleaner-protocol':
            p = base/'functions/mervlan_full_cleanup.sh'
            p.write_text(p.read_text().replace('phase6-v1','unknown'))
        trustdir = root/'state/ssh_trust'
        trustdir.mkdir(parents=True,mode=0o700)
        trust = trustdir/'known_hosts.v1'
        header = 'MERV_SSH_TRUST_V1\nversion\tnode_id\tslot\tmac\thost\tport\talgorithm\tpublic_key_b64\tfingerprint_sha256\tcreated_epoch\tupdated_epoch\n'
        now = str(int(time.time()))
        lines = []
        for i in range(1,nodes+1):
            k = key(2) if scenario == 'trust-mismatch' or (scenario == 'partial-trust' and i == 3) else key(1)
            fp = 'SHA256:'+base64.b64encode(hashlib.sha256(base64.b64decode(k)).digest()).decode().rstrip('=')
            lines.append('\t'.join(quote(v,safe='-._~') for v in ['1',f'NODE{i}@192.0.2.{i}:{port}',str(i),'none',f'192.0.2.{i}',port,('ssh-rsa' if scenario=='trust-algorithm' else 'ssh-ed25519'),k,fp,now,now]))
        trust.write_text(header+'\n'.join(lines)+('\n' if lines else ''))
        trust.chmod(0o600)
        (root/'fixture.json').write_text(json.dumps({'scenario':scenario,'hosts':hosts,'user':'admin','port':port,'key':key(1),'key2':key(2)}))
        context=root/'.mervlan-selftest-context'
        context.write_text(f'format=mervlan-selftest-context-v1\nroot={root}\n')
        context.chmod(0o600)
        environment = dict(os.environ, MERV_BASE=str(base), MERVLAN_SELFTEST_CONTEXT=str(context),
                           MERV_FULL_ENDPOINT_MAP='/foreign/map', MERV_FULL_RUN_ROOT='/foreign/root',
                           MERV_SSH_CLIENT='/foreign/client', MERV_STATE_ROOT='/foreign/state',
                           MERV_SSH_HOSTKEY_PROBE_CMD='/foreign/probe', MERV_MAX_NODES='99',
                           SETTINGS_FILE='/foreign/settings', LIB_SSH_TRUST_LOADED='1',
                           LIB_IDENTITY_LOADED='1', VAR_SETTINGS_LOADED='1',
                           DROPBEAR_PASSWORD='fixture-ambient', SSH_ASKPASS='/foreign/askpass',
                           DISPLAY='fixture', SSH_AUTH_SOCK='/foreign/socket')
        result = subprocess.run(['/bin/sh',str(BASE/'dev-tools/tests/local/full_fixture_entry.sh'),'--prepare'],
                                env=environment,text=True,capture_output=True,timeout=300)
        if (result.returncode == 0) != expected:
            for run in root.glob('.mervlan-full.*'):
                print('probe.stderr:', (run/'probe.stderr').read_text() if (run/'probe.stderr').exists() else '', flush=True)
                print('ssh.stderr:', (run/'ssh.stderr').read_text() if (run/'ssh.stderr').exists() else '', flush=True)
        check((result.returncode == 0) == expected, f'{scenario}/{bad_source}: rc={result.returncode}\n{result.stdout}\n{result.stderr}')
        runs = list(root.glob('.mervlan-full.*'))
        check(len(runs) == 1, 'one fresh run')
        run = runs[0]
        check((run/'ready').exists() == expected, 'readiness all-or-nothing')
        events = [json.loads(l) for l in (root/'events').read_text().splitlines()] if (root/'events').exists() else []
        if expected:
            check('READY_FOR_NODE_CLEANUP' in (run/'ready').read_text(), 'strict ready state')
            check('support=full-terminal-v1' in (run/'ready').read_text(), 'NODE support readiness')
            check(len((run/'artifacts.manifest').read_text().splitlines()) == 14, 'complete artifact cohort')
            check('main/node.sh' in (run/'artifacts.manifest').read_text(), 'wrapper bound')
            check('main/lib_maintenance_quiesce.sh' in (run/'artifacts.manifest').read_text(), 'Q bound')
            check(f'node_count={nodes}' in (run/'ready').read_text(), 'node count')
            check((run/'main/cleaner.sh').read_bytes() == (BASE/'functions/mervlan_full_cleanup.sh').read_bytes(), 'frozen MAIN source')
            check((run/'main/stage.sh').read_bytes() == full_program('stage').encode(), 'frozen stage verifier')
            if nodes:
                first_stage = next(i for i,e in enumerate(events) if e['op']=='init')
                check(sum(e['op']=='proof' for e in events[:first_stage]) == nodes, 'all auth before any stage')
                check(sum(e['op']=='verify' for e in events) == nodes*2, 'every node second verified')
                probes=[i for i,e in enumerate(events) if e['op']=='probe']
                second_probe=next(i for i in probes if i>first_stage)
                check(sum(e['op']=='verify' for e in events[:second_probe]) == nodes, 'ALL nodes staged before second preflight')
                check(sum(e['op']=='receive' for e in events[:second_probe]) == nodes*15, 'entire cohort on ALL nodes before second preflight')
                for slot in set(hosts.values()):
                    staged=next((root/'remote'/slot).glob('stage.*'))
                    check(len(list(staged.iterdir()))==15, 'exact stage membership')
                    check((staged/'artifacts.manifest').read_bytes()==(run/'artifacts.manifest').read_bytes(), 'remote manifest hash-bound')
                    for line in (run/'artifacts.manifest').read_text().splitlines():
                        h,n=line.split();f=staged/n.removeprefix('main/')
                        check(hashlib.sha256(f.read_bytes()).hexdigest()==h and f.stat().st_mode&0o777==0o600, 'inert exact staged artifact '+n)
            for name in ('settings.snapshot.json','endpoint.map','trust.identity.map','ready'):
                check((run/name).stat().st_mode & 0o777 == 0o600, 'private '+name)
            if scenario == 'live-settings':
                check('203.0.113.9' not in (run/'topology.map').read_text(), 'live change cannot retarget')
        if scenario in ('trust-mismatch','partial-trust','auth-failure') or bad_source:
            check(not any(e['op']=='init' for e in events), 'first gate blocks ALL staging')
        if scenario == 'pinned-failure':
            probe_hosts=[e['host'] for e in events if e['op']=='probe']
            check(probe_hosts == ['198.51.100.1','198.51.100.1'], 'no post-promotion fallback')
        if scenario == 'fallback':
            probe_hosts=[e['host'] for e in events if e['op']=='probe']
            check(probe_hosts == ['198.51.100.1','192.0.2.1','192.0.2.1'], 'initial fallback then pinned')
        if scenario == 'stage-failure':
            check(events[-1]['slot']=='NODE2' and events[-1]['op']=='receive','ambiguous stage stops without replay')
            check(any((root/'remote/NODE2').glob('stage.*/artifacts.manifest')),'ambiguous inert stage retained')
        for slot in hosts.values():
            check((root/'remote'/slot/'active/settings').read_text()=='active-node-settings','active node settings untouched')
            check((root/'remote'/slot/'active/hooks').read_text()=='active-node-hooks','active node hooks untouched')
        # Staged shell is actually executed in fixtures. Only private /tmp
        # per-node roots change; installed fixtures and source stay untouched.
        check(not list(root.rglob('mervlan_maintenance.lock')), 'no M ownership')
        check(not list(root.rglob('.mervlan-full-uninstall.lock')), 'no F ownership')
        check(not list(root.rglob('terminal')), 'no cleaner terminal/execution')
        print('PASS fixture',scenario,bad_source or '',flush=True)


# Existing/foreign workspaces and snapshot destinations are never reused.
with tempfile.TemporaryDirectory(prefix="mervlan-phase7-path-", dir="/tmp") as tmp:
    root=Path(tmp); root.chmod(0o700)
    base=root/'base'
    for name in SOURCES:
        dest=base/name; dest.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(BASE/name,dest)
    context=root/'.mervlan-selftest-context'
    context.write_text(f'format=mervlan-selftest-context-v1\nroot={root}\n'); context.chmod(0o600)
    env={'PATH':'/usr/sbin:/usr/bin:/sbin:/bin','LC_ALL':'C','MERV_BASE':str(base),'MERVLAN_SELFTEST_CONTEXT':str(context)}
    existing=root/'.mervlan-full.1.2.3.4'
    for kind in ('directory','mode','symlink','file'):
        if kind in ('directory','mode'):
            existing.mkdir(mode=0o700 if kind=='directory' else 0o755)
            (existing/'ready').write_text('stale evidence')
        elif kind=='symlink': existing.symlink_to(base,target_is_directory=True)
        else: existing.write_text('foreign file')
        result=subprocess.run(['/bin/sh','-c', '. "$MERV_BASE/settings/lib_full_uninstall.sh"; merv_identity_nonce_next() { MERV_IDENTITY_NONCE=1.2.3.4; }; full_prepare'],env=env,capture_output=True)
        check(result.returncode!=0,'existing workspace '+kind)
        if kind in ('directory','mode'):
            check((existing/'ready').read_text()=='stale evidence','stale ready untouched')
            shutil.rmtree(existing)
        else: existing.unlink()
    source=root/'source'; source.write_text('fixture data'); source.chmod(0o600)
    destination=root/'destination'
    for kind in ('symlink','file'):
        if kind=='symlink': destination.symlink_to(source)
        else: destination.write_text('existing snapshot'); destination.chmod(0o600)
        result=subprocess.run(['/bin/sh','-c', '. "$MERV_BASE/settings/lib_full_uninstall.sh"; FULL_UID=$(id -u); full_freeze "$1" "$2"', 'test',str(source),str(destination)],env=env,capture_output=True)
        check(result.returncode!=0,'snapshot destination '+kind)
        check(source.read_text()=='fixture data','source untouched')
        destination.unlink()
    # Non-root host: emulate only ls's ownership column through an explicit
    # source-isolated platform fixture; production exposes no override for it.
    for name in ('settings.snapshot.json','endpoint.map','trust.identity.map'):
        dest=root/name; dest.write_text('fixture data'); dest.chmod(0o600)
        result=subprocess.run(['/bin/sh','-c', '. "$MERV_BASE/settings/lib_full_uninstall.sh"; FULL_UID=$(id -u); ls() { /bin/ls "$@" | awk \'{$3=65534; print}\'; }; full_private "$1" -rw-------', 'test',str(dest)],env=env,capture_output=True)
        check(result.returncode!=0,'foreign owner fixture '+name)
    # Raw invalid UTF-8 is not syntactically valid JSON.
    for bad in (b'\xff',b'\xc0\xaf',b'\xed\xa0\x80',b'\xf4\x90\x80\x80'):
        for cmd in (['awk'],['busybox','awk']):
            result=subprocess.run(cmd+['-f',str(TOPOLOGY)],input=b'{"unknown":"'+bad+b'"}',capture_output=True,env=dict(os.environ,LC_ALL='C'))
            check(result.returncode!=0,'invalid UTF-8 rejection')
print('PASS private workspace/snapshot collision and UTF-8 fixtures',flush=True)

run_fixture(nodes=0)
run_fixture(nodes=3,port='2222')
run_fixture('live-settings')
run_fixture('source-live-cleaner')
run_fixture('source-live-client')
run_fixture('fallback',wan=True)
run_fixture('pinned-failure',expected=False,wan=True)
for scenario in ('trust-mismatch','trust-algorithm','trust-drift','host-replaced','auth-failure','probe-retained',
                 'tamper-byte','tamper-mode','tamper-symlink','tamper-helper','tamper-syntax','tamper-protocol','tamper-extra','tamper-wrapper','tamper-q',
                 'main-tamper','main-helper-tamper','snapshot-tamper','snapshot-symlink','snapshot-mode',
                 'map-duplicate','map-trust-duplicate','map-symlink','map-mode','map-truncate','map-extra','map-missing','map-unsafe','map-field','map-manifest'):
    run_fixture(scenario,expected=False)
for scenario in ('partial-trust','stage-failure','second-auth'):
    run_fixture(scenario,nodes=3,expected=False)
for bad in ('symlink','malformed','duplicate','key','key-mode','cleaner-symlink','cleaner-protocol','cleaner-syntax'):
    run_fixture(expected=False,bad_source=bad)
if os.getuid()==0:
    for scenario in ('snapshot-foreign','map-foreign'):
        run_fixture(scenario,expected=False)
else:
    print('SKIP: real-chown foreign snapshot/map fixtures require uid 0; ownership metadata fixtures passed',flush=True)

# Bootstrap still contains no destructive calls; emitted programs are tested
# separately against the Phase-8/9 contracts.
lib=(BASE/'settings/lib_full_uninstall.sh').read_text()
bootstrap=lib[lib.index('full_prepare() {'):lib.index('# ---- 09')]
for forbidden in ('merv_full_fence_acquire','merv_lock_acquire','merv_maintenance_quiesce','--coordinated','nvram set','reboot;'):
    check(forbidden not in bootstrap+full_program('stage'), 'no destructive call '+forbidden)
print(f'PHASE7_TEST_SUMMARY checks={CHECKS} failures=0')
