#!/usr/bin/env python3
"""Only synthetic fixtures. Never contacts routers, never modifies a repo."""
from __future__ import annotations
import argparse
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tarfile
import tempfile
import time
import io
import threading

HERE=Path(__file__).resolve().parent
ENGINE=Path(os.environ.get('MERV_TEST_ENGINE', HERE/'update_mervlan_repair_lean.sh'))
CANDIDATE=Path(os.environ.get('MERV_TEST_CANDIDATE', HERE.parent/'candidates/update_mervlan_repair_R2_cleanup_candidate.sh'))
FORCE_SHELL=os.environ.get('MERV_TEST_FORCE_SHELL', '')
if FORCE_SHELL not in ('', 'dash', 'busybox'):
    raise SystemExit('MERV_TEST_FORCE_SHELL must be dash or busybox')
MANIFEST=(HERE/'baseline/update_mervlan_repair.manifest').read_text()
FILES=[line.split(' ',1) for line in MANIFEST.splitlines()[2:]]
assert len(FILES)==58
SUMMARY=[]
TEST_INDEX=0

class Fixture:
    def __init__(self, process_count=0, archive_mutation=None, realistic=False):
        self.root=Path(tempfile.mkdtemp(prefix='mervlan_lean_fixture.',dir='/tmp'))
        self.base=self.root/'addon'; self.base.mkdir()
        self.tmp=self.root/'tmp'; self.tmp.mkdir()
        self.locks=self.root/'locks'; self.locks.mkdir()
        self.proc=self.root/'proc'; self.proc.mkdir()
        self.fakebin=self.root/'fakebin'; self.fakebin.mkdir()
        self.meminfo=self.root/'meminfo'; self.meminfo.write_text('MemAvailable: 400000 kB\n')
        self.archive=self.root/'snapshot.tar.gz'
        self.arc_mut=archive_mutation
        self.realistic=realistic
        self.make_archive()
        self.make_curl()
        self.populate(process_count)
        self.protected=self.base/'settings/settings.json';self.protected.parent.mkdir(parents=True,exist_ok=True)
        self.protected.write_text('secret user custom settings\n')
        self.ssh=self.base/'.ssh/vlan_manager';self.ssh.parent.mkdir(parents=True,exist_ok=True)
        self.ssh.write_text('secret ssh material\n')
        for mode,rel in FILES:
            target=self.base/rel
            target.parent.mkdir(parents=True,exist_ok=True)
            target.write_bytes(('original::'+rel+'\n').encode() + (b'old contents cache\n'*2500 if self.realistic else b''))
            target.chmod(0o755 if mode=='0755' else 0o644)
        self.originals={rel:(self.base/rel).read_bytes() for _,rel in FILES}
        self.child=None
        self.env=os.environ.copy()
        self.env.update(MERV_BASE=str(self.base),MERV_REPAIR_TMP_ROOT=str(self.tmp),
            MERV_REPAIR_PROC_ROOT=str(self.proc),MERV_REPAIR_MEMINFO=str(self.meminfo),
            MERV_REPAIR_LOCK=str(self.locks/'mervlan_maintenance.lock'),
            MERV_REPAIR_LEGACY_LOCK_ROOT=str(self.locks),
            MERV_REPAIR_CURL=str(self.fakebin/'curl'), TEST_ARCHIVE=str(self.archive),
            MERV_REPAIR_TEST_ONLY='1', PATH=f'{self.fakebin}:'+os.environ.get('PATH','/usr/bin:/bin'))
    def make_archive(self):
        with tarfile.open(self.archive,'w:gz',format=tarfile.USTAR_FORMAT) as t:
            members=[('0644','functions/update_mervlan_repair.manifest',MANIFEST.encode())]
            for mode,rel in FILES:
                if rel=='functions/update_mervlan_repair.manifest': continue
                data=(f'#!/bin/sh\n# new {rel}\n: \n' if rel.endswith('.sh') else 'new::'+rel+'\n').encode()
                if self.realistic: data += ((b'# '+rel.encode()+b' filler bytes\n') * 2500)[:61000]
                members.append((mode,rel,data))
            if self.arc_mut=='manifest':
                members[0]=('0644','functions/update_mervlan_repair.manifest',MANIFEST.replace('control-plane','wrong-plane').encode())
            if self.arc_mut=='missing': members=members[:-1]
            if self.arc_mut=='duplicate': members.append(members[-1])
            if self.arc_mut=='traversal': members.append(('0644','mervlan-main/../../evil',b'bad'))
            if self.arc_mut=='symlink':
                info=tarfile.TarInfo('mervlan-main/functions/fake_link')
                info.type=tarfile.SYMTYPE;info.linkname='/etc/passwd';t.addfile(info)
            if self.arc_mut=='badscript':
                members=[(m,r,b'if (\n' if r=='functions/heal_event.sh' else d) for m,r,d in members]
            if self.realistic:
                other=os.urandom(2460000)
                info=tarfile.TarInfo('mervlan-main/docs/realistic-unselected-payload.bin')
                info.size=len(other);info.mode=0o644
                t.addfile(info,io.BytesIO(other))
            for mode,rel,data in members:
                name=rel if self.arc_mut=='traversal' and rel.startswith('mervlan-') else 'mervlan-main/'+rel
                info=tarfile.TarInfo(name); info.size=len(data);info.mode=int(mode,8)
                t.addfile(info,io.BytesIO(data))
    def make_curl(self):
        script=self.fakebin/'curl'
        script.write_text('''#!/bin/sh
: "${TEST_ARCHIVE:?}"
[ "${TEST_CURL_FAIL:-0}" != 1 ] || exit 28
out=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = '-o' ]; then out=$2; shift 2; continue; fi
  shift
done
[ -n "$out" ] || exit 2
cp "$TEST_ARCHIVE" "$out"
''')
        script.chmod(0o755)
    def populate(self,count):
        for n in range(1,count+1):
            d=self.proc/str(n);d.mkdir(exist_ok=True)
            (d/'cmdline').write_bytes(b'/bin/sh\0ordinary background worker\0worker flag with spaces\0')
    def run(self,shell='/usr/bin/dash',ref='main',more=None,timeout=60,engine=None):
        env=self.env.copy();env.update(more or {})
        engine=Path(engine) if engine else ENGINE
        if FORCE_SHELL:
            shell=FORCE_SHELL
        if shell=='busybox': argv=['busybox','ash',str(engine),ref]
        else: argv=[shell,str(engine),ref]
        return subprocess.run(argv,env=env,capture_output=True,text=True,timeout=timeout)
    def start(self,shell='dash',more=None):
        env=self.env.copy();env.update(more or {})
        if FORCE_SHELL:
            shell=FORCE_SHELL
        argv=['busybox','ash',str(ENGINE),'main'] if shell=='busybox' else ['dash',str(ENGINE),'main']
        self.child=subprocess.Popen(argv,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        return self.child
    def works(self): return list(self.tmp.glob('mervlan_lean.*'))
    def all_old(self): return all((self.base/rel).read_bytes()==self.originals[rel] for _,rel in FILES)
    def all_new(self): return all((self.base/rel).read_bytes()!=self.originals[rel] for _,rel in FILES)
    def close(self):
        if self.child and self.child.poll() is None:
            self.child.kill();self.child.wait()
        shutil.rmtree(self.root,ignore_errors=True)

def check(label,fn):
    global TEST_INDEX
    TEST_INDEX+=1
    batch=os.environ.get('MERV_TEST_RANGE','')
    if batch:
        lo,hi=map(int,batch.split('-'))
        if not (lo <= TEST_INDEX <= hi):return
    try: fn(); SUMMARY.append((label,'PASS'));print('PASS',label,flush=True)
    except Exception as e:
        SUMMARY.append((label,'FAIL: '+str(e)));print('FAIL',label,e,flush=True)

def injected_test_engine(f,name,functions):
    source=ENGINE.read_text()
    marker='set -u\n'
    assert source.count(marker)==1,'test injection anchor drifted'
    path=f.root/name
    path.write_text(source.replace(marker,marker+functions,1))
    path.chmod(0o755)
    return path

def assert_ok(result,needle=None):
    assert result.returncode==0, f'rc={result.returncode} stderr={result.stderr[-2600:]}'
    if needle: assert needle in result.stderr

def assert_no(result,needle=None):
    assert result.returncode!=0, 'unexpected success'
    if needle: assert needle in result.stderr,repr(result.stderr[-700:])

def with_fixture(fn,**opts):
    f=Fixture(**opts)
    try:fn(f)
    finally:f.close()

def basic(f,shell):
    r=f.run(shell)
    assert_ok(r,'SUCCESS')
    assert f.all_new() and f.protected.read_text()=='secret user custom settings\n'
    assert f.ssh.read_text()=='secret ssh material\n'
    assert not f.works(), 'success left workspace'
    assert not (f.locks/'mervlan_maintenance.lock').exists()
    for term in ['START','DOWNLOAD','ARCHIVE','PREFLIGHT','ADMISSION','STAGING','verified=10/58','verified=58/58','VERIFY']:
        assert term in r.stderr,term
    assert 'no Update/Apply invoked' in r.stderr

def negative_archive(f):
    r=f.run();assert_no(r,'validation failed')
    assert f.all_old()
    assert not (f.locks/'mervlan_maintenance.lock').exists()

def wrong_destination(f):
    victim=f.base/'functions/heal_event.sh';victim.unlink();victim.symlink_to('/etc/passwd')
    r=f.run();assert_no(r)
    assert victim.is_symlink() and f.protected.read_text()=='secret user custom settings\n'

def missing_dest(f):
    victim=f.base/'functions/hw_probe.sh';victim.unlink()
    r=f.run();assert_ok(r);assert victim.is_file()

def short_mem(f):
    f.meminfo.write_text('MemAvailable: 1024 kB\n')
    r=f.run();assert_no(r,'insufficient RAM or storage');assert f.all_old()

def timeout(f):
    r=f.run(more={'TEST_CURL_FAIL':'1'})
    assert_no(r,'download failed'); assert f.all_old()

def ref_bad(f):
    r=f.run(ref='../../bad');assert_no(r,'invalid source ref');assert f.all_old()

def existing_owner(f):
    lock=f.locks/'mervlan_maintenance.lock';lock.mkdir();(lock/'owner').write_text('pid=999999\n')
    r=f.run();assert_no(r,'maintenance admission refused');assert (lock/'owner').read_text()=='pid=999999\n';assert f.all_old()

def existing_legacy_owner(f):
    # Even an apparently stale owner is not removed or automatically bypassed.
    lock=f.locks/'old-updater.lock';lock.mkdir()
    (lock/'pid').write_text('99999999\n')
    r=f.run();assert_no(r,'initial legacy mutator exclusion failed')
    assert f.all_old() and lock.exists() and (lock/'pid').exists()

def hardware_gate(f):
    r=f.run(more={'MERV_REPAIR_TEST_ONLY':'0'})
    assert_no(r,'hardware publication disabled')
    assert f.all_old() and not f.works()

def legacy_mutator(f):
    sleeper=subprocess.Popen(['sleep','45'])
    try:
        d=f.proc/str(sleeper.pid);d.mkdir(exist_ok=True)
        (d/'cmdline').write_bytes(f'/bin/sh\0{f.base}/functions/heal_event.sh\0'.encode())
        (d/'stat').write_bytes(Path(f'/proc/{sleeper.pid}/stat').read_bytes())
        r=f.run();assert_no(r,'initial legacy mutator exclusion failed');assert f.all_old()
    finally:sleeper.terminate();sleeper.wait()

def scanner_race(f):
    sleeper=subprocess.Popen(['sleep','45'])
    try:
        early=f.proc/'1'/'cmdline';early.write_bytes(b'/bin/sh\0not_a_mutator\0')
        late=f.proc/str(sleeper.pid);late.mkdir(exist_ok=True)
        (late/'cmdline').write_bytes(b'/bin/sh\0ordinary\0')
        (late/'stat').write_bytes(Path(f'/proc/{sleeper.pid}/stat').read_bytes())
        trigger=f.root/'triggered';payload=f.root/'later';payload.write_bytes(f'/bin/sh\0{f.base}/functions/heal_event.sh\0'.encode())
        test_engine=injected_test_engine(f,'candidate_scanner_race.sh', '''tr() {
  _merv_fd=$(readlink /proc/self/fd/0 2>/dev/null || :)
  if [ "$_merv_fd" = "${MERV_TEST_EARLY_CMDLINE:-}" ] &&
     [ ! -e "${MERV_TEST_TRIGGER:-}" ]; then
    /usr/bin/cp "$MERV_TEST_PAYLOAD" "$MERV_TEST_LATE_CMDLINE" || return 96
    : >"$MERV_TEST_TRIGGER" || return 97
  fi
  /usr/bin/tr "$@"
}
''')
        extra={'MERV_TEST_EARLY_CMDLINE':str(early),'MERV_TEST_LATE_CMDLINE':str(late/'cmdline'),
            'MERV_TEST_PAYLOAD':str(payload),'MERV_TEST_TRIGGER':str(trigger)}
        r=f.run(more=extra,engine=test_engine);assert_no(r,'initial legacy mutator exclusion failed')
        assert trigger.exists() and late.joinpath('cmdline').read_bytes()==payload.read_bytes()
        assert f.all_old()
    finally:sleeper.terminate();sleeper.wait()

def failure_at(f,n):
    r=f.run(more={'MERV_REPAIR_TEST_FAIL_AT':str(n)})
    assert_no(r,'publication failed')
    assert f.all_old(),f'rollback not exact at {n}'
    assert re.search(r'ROLLBACK elapsed=\d+s verified complete', r.stderr), r.stderr[-1800:]
    assert f.works() and not (f.locks/'mervlan_maintenance.lock').exists()
    assert not list(f.base.rglob('*.lean.*')), 'leftover temporary destination'

def old_mode_preserved(f):
    target=f.base/'functions/heal_event.sh'
    target.chmod(0o700)
    r=f.run(more={'MERV_REPAIR_TEST_FAIL_AT':'20'})
    assert_no(r,'publication failed')
    assert target.stat().st_mode & 0o777 == 0o700
    assert f.all_old()

def low_storage(f):
    test_engine=injected_test_engine(f,'candidate_low_storage.sh', '''df() {
  cat <<'DF_OUTPUT'
Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/test 30000 29900 100 99% /tmp
DF_OUTPUT
}
''')
    r=f.run(engine=test_engine)
    assert_no(r,'insufficient RAM or storage')
    assert f.all_old()

def relative_ambiguous(f):
    sleeper=subprocess.Popen(['sleep','45'])
    try:
        d=f.proc/str(sleeper.pid);d.mkdir(exist_ok=True)
        (d/'cmdline').write_bytes(b'/bin/sh\0functions/./heal_event.sh\0')
        (d/'stat').write_bytes(Path(f'/proc/{sleeper.pid}/stat').read_bytes())
        (d/'cwd').symlink_to(f.base)
        r=f.run(); assert_no(r,'initial legacy mutator exclusion failed'); assert f.all_old()
    finally:sleeper.terminate();sleeper.wait()

def post_acquisition_race(f):
    sleeper=subprocess.Popen(['sleep','45'])
    try:
        early=f.proc/'1'/'cmdline';early.write_bytes(b'/bin/sh\0ordinary\0')
        late=f.proc/str(sleeper.pid);late.mkdir(exist_ok=True)
        (late/'cmdline').write_bytes(b'/bin/sh\0ordinary\0')
        (late/'stat').write_bytes(Path(f'/proc/{sleeper.pid}/stat').read_bytes())
        trigger=f.root/'triggered';once=f.root/'once';payload=f.root/'later'
        payload.write_bytes(f'/bin/sh\0{f.base}/functions/heal_event.sh\0'.encode())
        test_engine=injected_test_engine(f,'candidate_post_acquisition_race.sh', '''tr() {
  _merv_fd=$(readlink /proc/self/fd/0 2>/dev/null || :)
  if [ "$_merv_fd" = "${MERV_TEST_EARLY_CMDLINE:-}" ]; then
    if [ ! -e "${MERV_TEST_ONCE:-}" ]; then
      : >"$MERV_TEST_ONCE" || return 97
    elif [ ! -e "${MERV_TEST_TRIGGER:-}" ]; then
      /usr/bin/cp "$MERV_TEST_PAYLOAD" "$MERV_TEST_LATE_CMDLINE" || return 96
      : >"$MERV_TEST_TRIGGER" || return 97
    fi
  fi
  /usr/bin/tr "$@"
}
''')
        extra={'MERV_TEST_EARLY_CMDLINE':str(early),'MERV_TEST_LATE_CMDLINE':str(late/'cmdline'),
            'MERV_TEST_PAYLOAD':str(payload),'MERV_TEST_ONCE':str(once),'MERV_TEST_TRIGGER':str(trigger)}
        r=f.run(more=extra,engine=test_engine);assert_no(r,'post-acquisition legacy mutator exclusion failed')
        assert trigger.exists() and f.all_old()
        assert not (f.locks/'mervlan_maintenance.lock').exists()
    finally:sleeper.terminate();sleeper.wait()

def owner_changed(f):
    p=f.start(more={'MERV_REPAIR_TEST_PAUSE_AT':'1'})
    end=time.monotonic()+20;lock=f.locks/'mervlan_maintenance.lock'
    while time.monotonic()<end:
        works=f.works()
        if works and any((w/'ledger').exists() and (w/'ledger').stat().st_size>0 for w in works):break
        if p.poll() is not None:raise AssertionError('process exited before pause')
        time.sleep(.01)
    else:raise AssertionError('no ledger')
    owner=lock/'owner';text=owner.read_text();owner.write_text(text.replace('owner_nonce=lean.', 'owner_nonce=successor.'))
    _,err=p.communicate(timeout=30)
    assert p.returncode!=0,err
    assert f.all_old(),'published despite owner replacement before rename'
    assert 'SKIPPED: no verified owner' in err,err
    assert owner.exists(),'foreign owner deleted'

def signal_rollback(f):
    p=f.start(more={'MERV_REPAIR_TEST_PAUSE_AT':'12'})
    end=time.monotonic()+25
    while time.monotonic()<end:
        works=f.works()
        if works and any(len(x.read_text().splitlines())>=12 for x in [w/'ledger' for w in works] if x.exists()):break
        if p.poll() is not None:raise AssertionError('process exited before pause')
        time.sleep(.015)
    else:raise AssertionError('did not reach pause')
    p.send_signal(signal.SIGTERM)
    _,err=p.communicate(timeout=20)
    assert p.returncode!=0
    assert f.all_old(),'interrupted rollback incomplete'
    assert re.search(r'ROLLBACK elapsed=\d+s verified complete', err),err[-1700:]

def simulated_reboot(f):
    p=f.start(more={'MERV_REPAIR_TEST_PAUSE_AT':'12'})
    end=time.monotonic()+25
    while time.monotonic()<end:
        works=f.works()
        if works and any(len(x.read_text().splitlines())>=12 for x in [w/'ledger' for w in works] if x.exists()):break
        time.sleep(.015)
    else:raise AssertionError('did not reach pause')
    p.kill();p.communicate(timeout=10)
    assert not f.all_old() and not f.all_new(), 'expected mixed cohort after SIGKILL'
    for w in works:shutil.rmtree(w)
    assert not list(f.tmp.glob('mervlan_lean.*')),'volatile evidence survived simulated reboot'
    # A stale lock may also survive only on same boot; reboot clears /tmp.
    assert not f.all_old(),'reboot automatically rolled back -- false recovery claim'

def competing_writers(f):
    p=f.start(more={'MERV_REPAIR_TEST_PAUSE_AT':'1'})
    end=time.monotonic()+20;lock=f.locks/'mervlan_maintenance.lock'
    while time.monotonic()<end and not (lock/'owner').exists():
        if p.poll() is not None:raise AssertionError('finished early')
        time.sleep(.01)
    assert lock.exists()
    for role in ('service-event-handler','heal_event'):
        try: lock.mkdir();raise AssertionError(role+' entered occupied gate')
        except FileExistsError: pass
    out,err=p.communicate(timeout=40)
    assert p.returncode==0,err[-1600:]
    assert f.all_new()


# R2 targeted regression cases. All use the ACTUAL corrected shell engine.
def attach_live_candidate(f, arg, cwd=None):
    sleeper=subprocess.Popen(['sleep','45'])
    d=f.proc/str(sleeper.pid); d.mkdir(exist_ok=True)
    (d/'cmdline').write_bytes(b'/bin/sh\0'+arg.encode()+b'\0')
    (d/'stat').write_bytes(Path(f'/proc/{sleeper.pid}/stat').read_bytes())
    if cwd is not None: (d/'cwd').symlink_to(cwd)
    return sleeper, d

def candidate_case(f,arg,cwd,shell):
    sleeper,entry=attach_live_candidate(f,arg,cwd)
    try:
        r=f.run(shell)
        assert_no(r,'initial legacy mutator exclusion failed')
        assert f.all_old() and not (f.locks/'mervlan_maintenance.lock').exists()
    finally:
        sleeper.terminate();sleeper.wait()

def unreadable_cmdline(f,shell):
    d=f.proc/'1';(d/'cmdline').unlink()
    r=f.run(shell);assert_no(r,'initial legacy mutator exclusion failed');assert f.all_old()

def missing_writer_stat(f,shell):
    sleeper,entry=attach_live_candidate(f,'heal_event.sh',f.base/'functions')
    try:
        (entry/'stat').unlink()
        r=f.run(shell);assert_no(r,'initial legacy mutator exclusion failed');assert f.all_old()
    finally:sleeper.terminate();sleeper.wait()

def unreadable_writer_cwd(f,shell):
    sleeper,entry=attach_live_candidate(f,'heal_event.sh',None)
    try:
        r=f.run(shell);assert_no(r,'initial legacy mutator exclusion failed');assert f.all_old()
    finally:sleeper.terminate();sleeper.wait()

def dead_writer_pid(f,shell):
    sleeper,entry=attach_live_candidate(f,'heal_event.sh',f.base/'functions')
    sleeper.terminate();sleeper.wait()
    r=f.run(shell);assert_no(r,'initial legacy mutator exclusion failed');assert f.all_old()

def prior_workspace(f,shell,kind,nonempty=True,alt=False):
    root=f.root/'other_bootstrap' if alt else f.tmp
    root.mkdir(exist_ok=True)
    d=root/('mervlan_repair.123.456.0' if kind=='r1' else 'mervlan_lean.123.456.0')
    d.mkdir();(d/'.owner').write_text('mervlan-repair-workspace-v2\n' if kind=='r1' else 'lean-repair-v1\n')
    if nonempty: (d/'ledger').write_text('pending|0755|functions/heal_event.sh|old|fixture|fixture\n')
    extra={'MERV_REPAIR_BOOTSTRAP_DIR':str(root)} if alt else None
    r=f.run(shell,more=extra)
    if nonempty:
        assert_no(r,'workspace unavailable or earlier transaction unresolved')
        assert f.all_old() and (d/'ledger').exists()
    else:
        assert_ok(r,'SUCCESS');assert f.all_new();assert d.exists()

def malformed_prior_workspace(f):
    d=f.tmp/'mervlan_repair.malformed'; d.mkdir()
    (d/'.owner').write_text('unknown\n'); (d/'ledger').write_text('pending\n')
    r=f.run();assert_no(r,'workspace unavailable or earlier transaction unresolved')
    assert f.all_old() and d.exists()

def backup_incomplete(f):
    # Disallow a late original backup while earlier backups have succeeded.
    bad=f.base/'functions/heal_event.sh'; bad.unlink();bad.symlink_to('/dev/null')
    r=f.run();assert_no(r,'backup/protected-state capture failed')
    assert f.all_old() is False  # the deliberate malformed input is unchanged
    assert bad.is_symlink()
    assert not (f.locks/'mervlan_maintenance.lock').exists()
    assert not any(w.joinpath('ledger').exists() for w in f.works()), 'backup failure unexpectedly published'

def after_rename_error(f,shell):
    # BusyBox ash resolves applets before PATH shims. Inject a shell function
    # into a private test copy so both shells execute the same deterministic
    # rename-then-error path. The supplied candidate itself stays untouched.
    source=CANDIDATE.read_text()
    assert source==ENGINE.read_text(),'suite engine drifted from the cleanup candidate'
    injection='''mv() {
  if [ "${MERV_TEST_RENAME_FAIL:-0}" = 1 ] && [ "$#" -eq 3 ] && [ "$1" = "-f" ]; then
    case "$2" in
      *.lean.*)
        /bin/mv "$@" || return $?
        [ ! -e "$2" ] && [ -f "$3" ] || return 98
        printf 'rename_succeeded|%s|%s|return=11\\n' "$2" "$3" >>"${MERV_TEST_RENAME_TRACE:?}" || return 97
        return 11 ;;
    esac
  fi
  /bin/mv "$@"
}
'''
    assert source.count('set -u\n')==1
    test_engine=f.root/'candidate_after_rename_failure.sh'
    test_engine.write_text(source.replace('set -u\n','set -u\n'+injection,1))
    test_engine.chmod(0o755)
    before={p.relative_to(f.base).as_posix():(p.read_bytes(),p.stat().st_mode&0o777)
            for p in f.base.rglob('*') if p.is_file() and not p.is_symlink()}
    trace=f.root/'rename-fault.trace'
    r=f.run(shell,more={'MERV_TEST_RENAME_FAIL':'1','MERV_TEST_RENAME_TRACE':str(trace)},engine=test_engine)
    assert_no(r,'publication failed')
    assert trace.is_file(), 'injected mv did not complete the underlying rename'
    rows=trace.read_text().splitlines()
    assert len(rows)==1, f'expected exactly one injected rename, got {rows}'
    tag,src,dst,reported_rc=rows[0].split('|',3)
    assert tag=='rename_succeeded' and reported_rc=='return=11',rows[0]
    assert Path(dst)==f.base/'changelog.txt',f'fault targeted unexpected destination: {dst}'
    assert not Path(src).exists(),'renamed source still exists after rollback'
    assert f.all_old(),'complete rollback did not restore all 58 candidate destinations'
    after={p.relative_to(f.base).as_posix():(p.read_bytes(),p.stat().st_mode&0o777)
           for p in f.base.rglob('*') if p.is_file() and not p.is_symlink()}
    assert before==after,'rollback changed an unrelated fixture destination or protected file'
    assert 'verified complete' in r.stderr,'repair did not report verified rollback'
    assert 'publication failed' in r.stderr,'Repair did not detect the simulated mv failure'
    works=f.works()
    assert len(works)==1 and (works[0]/'ledger').is_file() and (works[0]/'ledger').stat().st_size>0, \
        'post-publication recovery evidence was not retained'
    assert not (f.locks/'mervlan_maintenance.lock').exists(),'maintenance ownership was not released'
    assert not list(f.base.rglob('*.lean.*')),'rollback left an adjacent rename temporary'

def truncated_ledger(f):
    p=f.start(more={'MERV_REPAIR_TEST_PAUSE_AT':'12'})
    end=time.monotonic()+25;work=None
    while time.monotonic()<end:
        items=f.works()
        if items and (items[0]/'ledger').exists() and len((items[0]/'ledger').read_text().splitlines())>=12:
            work=items[0];break
        if p.poll() is not None:raise AssertionError('exited before tamper fixture')
        time.sleep(.012)
    assert work is not None
    ledger=work/'ledger';lines=ledger.read_text().splitlines()
    ledger.write_text('\n'.join(lines[5:])+'\n')
    p.send_signal(signal.SIGTERM)
    _,err=p.communicate(timeout=30)
    assert p.returncode!=0 and 'ROLLBACK' in err
    assert 'verified complete' not in err,err
    assert 'INCOMPLETE' in err and work.exists() and not f.all_old()

def malformed_proc_pid(f):
    d=f.proc/'123abc';d.mkdir();(d/'cmdline').write_bytes(b'/bin/sh\0ordinary\0')
    r=f.run();assert_no(r,'initial legacy mutator exclusion failed');assert f.all_old()

def zero_proc_pid(f):
    d=f.proc/'0';d.mkdir();(d/'cmdline').write_bytes(b'/bin/sh\0ordinary\0')
    r=f.run();assert_no(r,'initial legacy mutator exclusion failed');assert f.all_old()

def symlinked_legacy_root(f):
    link=f.root/'legacy_root_link';link.symlink_to(f.locks,target_is_directory=True)
    r=f.run(more={'MERV_REPAIR_LEGACY_LOCK_ROOT':str(link)})
    assert_no(r,'initial legacy mutator exclusion failed');assert f.all_old()

def pid_generation_changes_mid_read(f,shell):
    # Exercise the actual scanner function with deterministic different values
    # from its two process-generation reads. This is an isolated scanner test,
    # not a live-process /proc PID-reuse integration test.
    sleeper,entry=attach_live_candidate(f,'heal_event.sh',f.base/'functions')
    try:
        scanner=f.root/'scanner_lib.sh'
        scanner.write_text(ENGINE.read_text().split('\n# A proof of cooperating writer exclusion')[0])
        marker=f.root/'stat_generation_seen'
        program = (f'. "{scanner}"\n'
                   + 'proc_start() {\n'
                   + f'  if [ -e "{marker}" ]; then printf "200\\n";\n'
                   + f'  else : > "{marker}"; printf "100\\n"; fi\n'
                   + '}\nscan_processes\n')
        selected=FORCE_SHELL or shell
        args=['busybox','ash','-c',program] if selected=='busybox' else ['dash','-c',program]
        r=subprocess.run(args,env=f.env,capture_output=True,text=True,timeout=10)
        assert r.returncode!=0,r.stderr
        assert 'writer process generation changed' in r.stderr,r.stderr
        assert marker.exists() and f.all_old()
    finally:sleeper.terminate();sleeper.wait()

def backup_copy_interrupted(f):
    # Simulate a failed copy into a later original backup; no ledger or write.
    marker=f.root/'backup_copy_seen'
    test_engine=injected_test_engine(f,'candidate_backup_copy_failure.sh', '''cp() {
  case "$*" in
    *'/backup/functions/heal_event.sh'*)
      : >"${TEST_BACKUP_MARKER:?}" || return 97
      return 7 ;;
  esac
  /usr/bin/cp "$@"
}
''')
    r=f.run(more={'TEST_BACKUP_MARKER':str(marker)},engine=test_engine)
    assert_no(r,'backup/protected-state capture failed')
    assert marker.exists() and f.all_old()
    assert all(not (w/'ledger').exists() for w in f.works())

def run_all():
    for shell in ['dash','busybox']:
        check(f'{shell} 58-entry healthy and terminal log',lambda sh=shell:with_fixture(lambda f:basic(f,sh),process_count=3))
    for case in ['manifest','missing','duplicate','traversal','symlink','badscript']:
        check('archive '+case,lambda c=case:with_fixture(negative_archive,archive_mutation=c))
    for name,fn in [('malformed destination',wrong_destination),('missing installed destination repaired',missing_dest),
        ('memory refusal',short_mem),('storage refusal',low_storage),('download failure',timeout),('invalid ref',ref_bad),
        ('unknown/stale owner preserved',existing_owner),('stale legacy owner rejected',existing_legacy_owner),('hardware gate refuses publication',hardware_gate),('recognized active mutator',legacy_mutator),
        ('sequential scanner later PID race',scanner_race),('post-acquisition scanner later PID race',post_acquisition_race),('ambiguous relative script refused',relative_ambiguous),('before first rename rollback',lambda f:failure_at(f,1)),
        ('mid-publication rollback',lambda f:failure_at(f,13)),('rollback preserves original mode',old_mode_preserved),('owner replacement refuses publication',owner_changed),('TERM rollback',signal_rollback),
        ('cooperating event/Heal gate',competing_writers),('SIGKILL/reboot loss is NOT recovered',simulated_reboot)]:
        check(name,lambda func=fn:with_fixture(func,process_count=8))
    for shell in ('dash','busybox'):
        cases=(
            ('bare name', 'heal_event.sh','functions'),
            ('dot relative', './heal_event.sh','functions'),
            ('nested relative', 'functions/heal_event.sh','base'),
            ('nested dot relative', './functions/./heal_event.sh','base'),
            ('absolute path', 'ABS','base'),
            ('invalid parent relative','../functions/heal_event.sh','base'),
        )
        for label,arg,where in cases:
            def runner(f, a=arg, w=where, sh=shell):
                cwd=f.base/'functions' if w=='functions' else f.base
                if a=='ABS':a=str(f.base/'functions/heal_event.sh')
                candidate_case(f,a,cwd,sh)
            check(f'{shell} writer {label}',lambda fn=runner:with_fixture(fn,process_count=3))
        check(f'{shell} unreadable cmdline',lambda sh=shell:with_fixture(lambda f:unreadable_cmdline(f,sh),process_count=3))
        check(f'{shell} unreadable writer stat',lambda sh=shell:with_fixture(lambda f:missing_writer_stat(f,sh),process_count=3))
        check(f'{shell} missing writer cwd',lambda sh=shell:with_fixture(lambda f:unreadable_writer_cwd(f,sh),process_count=3))
        check(f'{shell} reused or disappeared PID',lambda sh=shell:with_fixture(lambda f:dead_writer_pid(f,sh),process_count=3))
        check(f'{shell} R1 pending workspace',lambda sh=shell:with_fixture(lambda f:prior_workspace(f,sh,'r1'),process_count=3))
        check(f'{shell} R1 alternate bootstrap pending',lambda sh=shell:with_fixture(lambda f:prior_workspace(f,sh,'r1',alt=True),process_count=3))
        check(f'{shell} lean pending workspace',lambda sh=shell:with_fixture(lambda f:prior_workspace(f,sh,'lean'),process_count=3))
        check(f'{shell} harmless R1 pre-ledger workspace',lambda sh=shell:with_fixture(lambda f:prior_workspace(f,sh,'r1',nonempty=False),process_count=3))
        check(f'{shell} interrupted rename returns error',lambda sh=shell:with_fixture(lambda f:after_rename_error(f,sh),process_count=3))
    for shell in ('dash','busybox'):
        check(f'{shell} PID generation replacement is rejected',lambda sh=shell:with_fixture(lambda f:pid_generation_changes_mid_read(f,sh),process_count=3))
    check('partial backup copy failure prevents publication',lambda:with_fixture(backup_copy_interrupted,process_count=3))
    check('PID zero is rejected',lambda:with_fixture(zero_proc_pid,process_count=3))
    check('malformed numeric PID entry is rejected',lambda:with_fixture(malformed_proc_pid,process_count=3))
    check('unsafe legacy-lock root rejected',lambda:with_fixture(symlinked_legacy_root,process_count=3))
    check('malformed historical workspace is retained',lambda:with_fixture(malformed_prior_workspace,process_count=3))
    check('incomplete backup blocks publication',lambda:with_fixture(backup_incomplete,process_count=3))
    check('truncated ledger cannot claim rollback success',lambda:with_fixture(truncated_ledger,process_count=3))
    print('RESULT',sum(s=='PASS' for _,s in SUMMARY),'/',len(SUMMARY))
    return all(s=='PASS' for _,s in SUMMARY)

if __name__=='__main__':
    a=argparse.ArgumentParser();a.add_argument('--benchmark',action='store_true');a.add_argument('--shell',choices=('dash','busybox'),default=None);args=a.parse_args()
    if args.shell and not args.benchmark:
        FORCE_SHELL=args.shell
    if args.benchmark:
        for count in (50,140,250):
            f=Fixture(process_count=count)
            try:
                start=time.monotonic()
                result=f.run(args.shell,timeout=120)
                print(count, 'elapsed',round(time.monotonic()-start,3),'return',result.returncode,
                    'stdout',len(result.stdout),'stderr',len(result.stderr),flush=True)
                if result.returncode:print(result.stderr[-3500:])
            finally:f.close()
    else:raise SystemExit(0 if run_all() else 1)
