"""Phase-6 execution contracts against frozen source in isolated fixture roots."""
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import time

BASE = Path(__file__).resolve().parents[3]
SOURCE = (BASE / 'functions/mervlan_full_cleanup.sh').read_text()
COUNT = 0

def start(pid):
    return Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1].split()[19]

def run(cmd, **kwargs):
    return subprocess.run(cmd, text=True, capture_output=True, timeout=30, **kwargs)

def check(ok, msg):
    global COUNT
    if not ok:
        raise AssertionError(msg)
    COUNT += 1
    print('PASS:', msg, flush=True)

def function(name):
    return re.search(r'^' + name + r'\(\) \{\n.*?^\}', SOURCE, re.M | re.S).group()

class Fixture:
    def __init__(self, hook='', busybox=False):
        self.busybox=busybox
        self.root = Path(tempfile.mkdtemp(prefix='mervlan-phase6-cleaner.', dir='/tmp'))
        self.tmp = self.root / 'tmp'
        self.tmp.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for name, body in {'logger': 'exit 0', 'cru': 'exit 0', 'ebtables': 'exit 1',
                           'sync': 'exit 0', 'reboot': f'touch {self.root}/reboot'}.items():
            p = self.bin / name
            p.write_text('#!/bin/sh\n' + body + '\n')
            p.chmod(0o755)
        s = SOURCE
        # Compile the immutable fixture copy with all device-owned paths relocated.
        # Production contains no environment-selected alternate destructive root.
        s = re.sub(r'(?<!\\)/(?:jffs|www|tmp)(?=[/\".*|)])', lambda m: str(self.root)+m.group(), s)
        s = s.replace('PATH="/usr/sbin:', f'PATH="{self.bin}:/usr/sbin:', 1)
        s = s.replace(function('find_mervlan_processes'),
                      'find_mervlan_processes() { printf "\\n"; }')
        # Hook only the frozen fixture, after the real volatile deletion operation.
        s = s.replace('    remove_glob_list "$MERVLAN_VOLATILE_GLOBS"\n}',
                      '    remove_glob_list "$MERVLAN_VOLATILE_GLOBS"\n' + hook + '\n}')
        self.cleaner = self.root / 'cleaner.sh'
        if self.busybox: s=s.replace('/bin/sh ', 'busybox sh ')
        self.cleaner.write_text(s)
        self.cleaner.chmod(0o755)
        self.fence = self.tmp / '.mervlan-full-uninstall.lock'
        self.runtime = self.tmp / 'mervlan_tmp'
        self.maintenance = self.runtime / 'locks/mervlan_maintenance.lock'
        self.install = self.root / 'jffs/addons/mervlan'
        self.install.mkdir(parents=True)
        self.backups = self.root / 'jffs/addons/mervlan_backups'
        self.backups.mkdir()
        (self.backups / 'archive.tar.gz').write_text('archive')
        (self.backups / '.mervlan.old.stale').write_text('stale')
        (self.runtime/'locks').mkdir(parents=True)
        self.process = None
    def close(self):
        if self.process and self.process.poll() is None:
            self.process.kill()
            self.process.wait()
        if self.fence.is_dir() and not self.fence.is_symlink(): self.fence.chmod(0o700)
        shutil.rmtree(self.root)
    def invoke(self, *args, input=''):
        shell=['busybox','sh'] if self.busybox else ['/bin/sh']
        cmd=[*shell, str(self.cleaner), *args]
        p=subprocess.Popen(cmd, text=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try: stdout,stderr=p.communicate(input, timeout=30)
        except subprocess.TimeoutExpired:
            p.kill(); p.communicate(); raise
        r=subprocess.CompletedProcess(cmd,p.returncode,stdout,stderr)
        r.pid=p.pid
        return r
    def launch(self, *args):
        self.out = (self.root / 'output').open('w')
        shell=['busybox','sh'] if self.busybox else ['/bin/sh']
        self.process = subprocess.Popen([*shell, str(self.cleaner), *args], stdout=self.out, stderr=self.out)
        return self.process
    def wait_file(self, path):
        for _ in range(100):
            if path.exists(): return
            if self.process and self.process.poll() is not None: break
            time.sleep(.05)
        raise AssertionError(f'no {path}: {(self.root / "output").read_text()}')
    def owner(self, path, pid=None, stamp=None, nonce='fixture'):
        path.mkdir(parents=True, exist_ok=True)
        path.chmod(0o700)
        pid = pid or os.getpid()
        p = path / 'owner'
        p.write_text(f'pid={pid}\nproc_start_time={stamp or start(pid)}\nowner_nonce={nonce}\ncreated=1\nheartbeat=1\n')
        p.chmod(0o600)
    def context(self, **changes):
        token = 'external.1'
        directory = self.tmp / f'.mervlan-full-cleanup.{token}'
        directory.mkdir(mode=0o700, exist_ok=True)
        fields = dict(fence=str(self.fence), pid=str(os.getpid()), start=start(os.getpid()),
                      nonce='fixture', run=token, mode='coordinated', keep='1', no_reboot='1')
        fields.update(changes)
        context = directory / 'context'
        context.write_text(''.join(f'{k}={v}\n' for k,v in fields.items()))
        context.chmod(0o600)
        return context, token

def fixture_test(fn):
    f = Fixture()
    try: fn(f)
    finally: f.close()

def terminal_consistent(context, token, pid, rc):
    terminal=context.parent/'terminal'
    actual=terminal.read_text()
    check(actual==f'{token}:{pid}:{rc}\n',
          f'coordinated terminal matches exact run/PID/process rc={rc}, record={actual.strip()}')

def fence_snapshot(f):
    return (str(f.fence),f.fence.stat().st_ino,f.fence.stat().st_mode,
            (f.fence/'owner').read_bytes())

def correction_fixture(busybox=False):
    f=Fixture(busybox=busybox)
    s=f.cleaner.read_text().replace('DISCOVERED_WEB_PAGE="$(metadata_get mervlan_page)"',
        f'printf "%s:%s\\n" "$$" "$PPID" >> "{f.root}/entries"\n'
        'DISCOVERED_WEB_PAGE="$(metadata_get mervlan_page)"')
    f.cleaner.write_text(s)
    f.owner(f.fence)
    context,token=f.context()
    return f,context,token

def borrowed_concurrent(busybox=False):
    f,context,token=correction_fixture(busybox)
    second=None
    try:
        # Fixture-only barrier at the production borrowed-entry boundary:
        # after claim + revalidation, before relocation/destructive execution.
        s=f.cleaner.read_text().replace('            cleanup_prepare || exit 2',
            f'            printf "%s\\n" "$$" >> "{f.root}/claimed"\n'
            f'            while [ ! -e "{f.root}/continue" ]; do sleep 1; done\n'
            '            cleanup_prepare || exit 2')
        s=s.replace('DISCOVERED_WEB_PAGE="$(metadata_get mervlan_page)"',
            f'while [ ! -e "{f.root}/finish" ]; do sleep 1; done\n'
            'DISCOVERED_WEB_PAGE="$(metadata_get mervlan_page)"')
        f.cleaner.write_text(s)
        before=fence_snapshot(f)
        args=('--mervlan-cleanup-borrowed',str(context),token)
        first=f.launch(*args)
        f.wait_file(f.root/'claimed')
        claimant_start=start(first.pid)
        shell=['busybox','sh'] if busybox else ['/bin/sh']
        second=subprocess.Popen([*shell,str(f.cleaner),*args],stdout=f.out,stderr=f.out)
        # Winner remains blocked while the loser attempts the same context.
        try: loser_rc=second.wait(timeout=2)
        except subprocess.TimeoutExpired: loser_rc=None
        (f.root/'continue').touch()
        f.wait_file(f.root/'entries')
        if loser_rc is None:
            # Baseline reproduction: keep both engine entries alive so the
            # race cannot collapse into one finisher plus a terminal refusal.
            for _ in range(100):
                if len((f.root/'entries').read_text().splitlines())==2: break
                time.sleep(.05)
        (f.root/'finish').touch()
        winner_rc=first.wait(timeout=15)
        if loser_rc is None: loser_rc=second.wait(timeout=15)
        entries=(f.root/'entries').read_text().splitlines()
        check(len(entries)==1 and winner_rc==0 and loser_rc==2,
              f'real concurrent borrowed consumers: destructive_entry_count={len(entries)}, rc={winner_rc}/{loser_rc}, busybox={busybox}')
        check(entries==[f'{first.pid}:{os.getpid()}'], 'winning worker keeps claimant PID and direct wrapper parent through exec')
        terminal_consistent(context,token,first.pid,winner_rc)
        consumer=(context.parent/'claim/consumer').read_text()
        record=dict(line.split('=',1) for line in consumer.splitlines())
        check(record==dict(protocol='phase6-v1',run=token,pid=str(first.pid),start=claimant_start,
              owner_pid=str(os.getpid()),owner_start=start(os.getpid()),owner_nonce='fixture',keep='1',no_reboot='1') and
              (context.parent/'claim').stat().st_mode & 0o777==0o700 and
              (context.parent/'claim/consumer').stat().st_mode & 0o777==0o600,
              'permanent strict private claim binds winning PID/start/run and exact wrapper F')
        check(fence_snapshot(f)==before,'concurrent winner/loser preserve exact external F')
    finally:
        if second and second.poll() is None: second.kill(); second.wait()
        f.close()

def borrowed_result_case(kind, busybox=False):
    f,context,token=correction_fixture(busybox)
    try:
        before=fence_snapshot(f)
        if kind=='known-failure': (f.root/'jffs/addons/mervlan.asp').mkdir()
        elif kind=='private-cleanup':
            # Real rmdir failure: execution-local foreign residue, after work
            # is terminal, must affect final rc before terminal publication.
            s=f.cleaner.read_text().replace('    rm -f "$PRIVATE_DIR/cleaner.sh"',
                  '    touch "$PRIVATE_DIR/foreign-residue"\n    rm -f "$PRIVATE_DIR/cleaner.sh"')
            # Also matches corrected conditional cleanup without changing it.
            if s==f.cleaner.read_text():
                s=s.replace('    if ! rm -f "$PRIVATE_DIR/cleaner.sh"',
                  '    touch "$PRIVATE_DIR/foreign-residue"\n    if ! rm -f "$PRIVATE_DIR/cleaner.sh"')
            f.cleaner.write_text(s)
        elif kind=='publication':
            # Force a real rename error in both shells, including BusyBox
            # builds which run applets internally instead of consulting PATH.
            s=f.cleaner.read_text().replace(
                'mv "${CONTEXT%/*}/terminal.tmp" "${CONTEXT%/*}/terminal"',
                'mv "${CONTEXT%/*}/terminal.tmp" "${CONTEXT%/*}/missing-parent/terminal"')
            f.cleaner.write_text(s)
        r=f.invoke('--mervlan-cleanup-borrowed',str(context),token)
        expected={'success':0,'known-failure':3,'private-cleanup':4,'publication':4}[kind]
        check(r.returncode==expected,f'coordinated {kind} process rc={r.returncode}, busybox={busybox}')
        if kind=='publication':
            check(not (context.parent/'terminal').exists(),'failed atomic rename publishes no false terminal')
        else: terminal_consistent(context,token,r.pid,r.returncode)
        check((context.parent/'claim/consumer').is_file(),'claim survives '+kind)
        check(fence_snapshot(f)==before,'exact external F preserved after '+kind)
        entries=(f.root/'entries').read_bytes()
        replay=f.invoke('--mervlan-cleanup-borrowed',str(context),token)
        check(replay.returncode==2 and (f.root/'entries').read_bytes()==entries and fence_snapshot(f)==before,
              'consumed context refuses replay after '+kind)
        if (context.parent/'terminal').exists(): terminal_consistent(context,token,r.pid,r.returncode)
    finally: f.close()

def borrowed_crash():
    f,context,token=correction_fixture()
    try:
        s=f.cleaner.read_text().replace('            cleanup_prepare || exit 2',
            f'            touch "{f.root}/claimed"\n'
            f'            while [ ! -e "{f.root}/continue" ]; do sleep 1; done\n'
            '            cleanup_prepare || exit 2')
        f.cleaner.write_text(s)
        before=fence_snapshot(f)
        p=f.launch('--mervlan-cleanup-borrowed',str(context),token)
        f.wait_file(f.root/'claimed')
        p.kill(); p.wait(timeout=5)
        check((context.parent/'claim/consumer').is_file() and not (context.parent/'terminal').exists(),
              'claimant crash leaves CLAIMED + NO TERMINAL')
        r=f.invoke('--mervlan-cleanup-borrowed',str(context),token)
        check(r.returncode==2 and not (f.root/'entries').exists() and fence_snapshot(f)==before,
              'crashed claimed context refuses replay before destructive work')
    finally: f.close()

# CLI rejection is before any fence or destructive work.
for args in [('--delete-backups',), ('--yes', '--keep-backups', '--delete-backups'), ('--unknown',),
             ('--borrow-f',), ('--mervlan-cleanup-worker',), ('--mervlan-cleanup-relocated', 'bad')]:
    def cli(f):
        r = f.invoke(*args)
        check(r.returncode == 2 and f.install.exists() and not f.fence.exists(), f'CLI rejects {args}')
    fixture_test(cli)
for args, input, keep in [((), 'n\n', True), ((), 'y\n\nn\n', True),
                          (('--yes', '--no-reboot'), '\n', True),
                          (('--keep-backups','--no-reboot'), 'y\n', True),
                          (('--yes','--delete-backups','--no-reboot'), '', False)]:
    def cli_success(f):
        r = f.invoke(*args, input=input)
        check(r.returncode == 0, f'CLI execution {args}: {r.stdout} {r.stderr}')
        if input != 'n\n':
            check(not f.install.exists() and not f.fence.exists(), 'worker success and exact terminal release')
            check(f.backups.exists() == keep, f'backup choice keep={keep}')
            if keep:
                check((f.backups/'archive.tar.gz').exists() and not (f.backups/'.mervlan.old.stale').exists(), 'completed backups kept; stale publications removed')
            check('Reboot this device before reinstalling' in r.stdout, 'reboot requirement reported')
            if '--no-reboot' in args:
                check('Reboot this device now?' not in r.stdout and not (f.root/'reboot').exists(), 'no-reboot suppresses final prompt')
    fixture_test(cli_success)

for marker in ['', '# Cleaner protocol: phase5-v1']:
    f=Fixture()
    try:
        f.cleaner.write_text(f.cleaner.read_text().replace('# Cleaner protocol: phase6-v1', marker, 1))
        r=f.invoke('--yes','--keep-backups','--no-reboot')
        check(r.returncode==2 and f.install.exists() and not f.fence.exists(), 'self-relocation rejects missing/old protocol identity '+repr(marker))
    finally: f.close()

# All existing F objects block, regardless of their diagnostic classification.
for state in ['live', 'dead', 'reused', 'incomplete', 'malformed', 'symlink', 'file', 'permissions']:
    def f_state(f):
        if state == 'dead': f.owner(f.fence, 99999999, '1')
        elif state == 'reused': f.owner(f.fence, stamp='1')
        elif state == 'live': f.owner(f.fence)
        elif state == 'symlink': f.fence.symlink_to(f.install, target_is_directory=True)
        elif state == 'file': f.fence.write_text('obstruction')
        else:
            f.fence.mkdir(mode=0o700)
            if state == 'malformed': (f.fence/'owner').write_text('pid=not-a-pid')
            if state == 'permissions': f.fence.chmod(0)
        before = f.fence.lstat()
        r=f.invoke('--yes','--keep-backups','--no-reboot')
        check(r.returncode==2 and f.install.exists() and f.fence.lstat().st_ino==before.st_ino, 'existing F blocks: '+state)
    fixture_test(f_state)
for state in ['absent', 'dead', 'reused', 'live', 'incomplete', 'malformed', 'file', 'symlink', 'parent-symlink', 'unreadable', 'unobservable', 'parent-missing']:
    def m_state(f):
        if state == 'dead': f.owner(f.maintenance, 99999999, '1')
        elif state == 'reused': f.owner(f.maintenance, stamp='1')
        elif state == 'live': f.owner(f.maintenance)
        elif state != 'absent':
            f.maintenance.parent.mkdir(parents=True, exist_ok=True)
            if state == 'parent-missing': f.maintenance.parent.rmdir()
            elif state == 'file': f.maintenance.write_text('obstruction')
            elif state == 'symlink': f.maintenance.symlink_to(f.install, target_is_directory=True)
            elif state == 'parent-symlink':
                f.maintenance.parent.rmdir()
                f.maintenance.parent.symlink_to(f.install, target_is_directory=True)
            else:
                f.maintenance.mkdir()
                if state == 'malformed': (f.maintenance/'owner').write_text('pid=x')
                if state == 'unreadable':
                    f.owner(f.maintenance, 99999999, '1'); (f.maintenance/'owner').chmod(0)
                if state == 'unobservable': f.maintenance.chmod(0)
        before=time.monotonic()
        r=f.invoke('--yes','--keep-backups','--no-reboot')
        allowed=state in ['absent','dead','reused']
        check(r.returncode==(0 if allowed else 2) and not f.fence.exists() and f.install.exists()!=allowed,
              'M classification after F: '+state+' '+r.stdout+r.stderr)
        check(time.monotonic()-before<5, 'M classification nonblocking: '+state)
        if f.maintenance.is_dir() and not f.maintenance.is_symlink(): f.maintenance.chmod(0o700)
    fixture_test(m_state)

# Damaged installed control plane is never sourced by the cleaner.
def damage(f):
    (f.install/'settings').mkdir()
    (f.install/'settings/settings.json').write_text('not json')
    (f.install/'settings/lib_owner_lock.sh').write_text('exit 99')
    r=f.invoke('--yes','--keep-backups','--no-reboot')
    check(r.returncode==0 and not f.install.exists(), 'partial install, corrupt settings/library, missing manager/event/Update')
fixture_test(damage)

# Genuine destructive engine regressions.
for obj in ['file','symlink','directory','fifo']:
    def asp(f):
        p=f.root/'jffs/addons/mervlan.asp'
        target=f.root/'foreign'; target.write_text('administrator')
        if obj=='file': p.write_text('legacy')
        elif obj=='symlink': p.symlink_to(target)
        elif obj=='directory': p.mkdir(); (p/'keep').write_text('keep')
        else: os.mkfifo(p)
        r=f.invoke('--yes','--keep-backups','--no-reboot')
        check(r.returncode==(0 if obj in ['file','symlink'] else 3) and (p.exists() or p.is_symlink())==(obj in ['directory','fifo']) and target.read_text()=='administrator', 'ASP safety '+obj)
    fixture_test(asp)
def unsafe_hook(f):
    scripts=f.root/'jffs/scripts'; scripts.mkdir()
    (scripts/'services-start').write_text('#!/bin/sh\n### >>> MERVLAN START:broken\n')
    r=f.invoke('--yes','--delete-backups','--no-reboot')
    check(r.returncode==3 and f.install.exists() and f.backups.exists() and not f.runtime.exists() and not f.fence.exists(), 'unsafe shared hook gates persistent destruction, terminal failure releases F')
fixture_test(unsafe_hook)

# Borrowed F is authenticated to this direct test wrapper and never released.
for change in [{}, {'nonce':'wrong'}, {'pid':'99999999'}, {'start':'1'}, {'fence':'/wrong'},
               {'run':'wrong'}, {'mode':'wrong'}, {'keep':'bad'}, {'no_reboot':'0'}, {'unknown':'x'}]:
    def borrowed(f):
        f.owner(f.fence)
        context,token=f.context(**change)
        before=(f.fence/'owner').read_bytes()
        r=f.invoke('--mervlan-cleanup-borrowed',str(context),token)
        check(r.returncode==(0 if not change else 2) and (f.fence/'owner').read_bytes()==before and f.install.exists()==bool(change), 'borrowed authentication '+str(change)+' '+r.stdout+r.stderr)
        if not change:
            check(not f.runtime.exists() and (context.parent/'terminal').read_text().startswith(token+':'), 'borrowed terminal result while wrapper retains F')
            terminal_consistent(context,token,r.pid,r.returncode)
    fixture_test(borrowed)
for keep, args, expected in [
    ('1', ('--yes','--keep-backups','--no-reboot'), 0),
    ('0', ('--yes','--delete-backups','--no-reboot'), 0),
    ('1', ('--yes','--delete-backups','--no-reboot'), 2),
    ('0', ('--delete-backups','--no-reboot'), 2),
    ('1', ('--yes','--keep-backups','--delete-backups'), 2),
    ('1', ('--unknown',), 2),
]:
    f=Fixture()
    try:
        f.owner(f.fence)
        context,token=f.context(keep=keep)
        before=(f.fence/'owner').read_bytes()
        r=f.invoke('--mervlan-cleanup-borrowed',str(context),token,*args)
        check(r.returncode==expected and (f.fence/'owner').read_bytes()==before and f.install.exists()==(expected!=0), 'borrowed mapped public CLI '+str(args)+' '+r.stderr)
        if expected==0:
            check(f.backups.exists()==(keep=='1'), 'borrowed mapped backup policy '+keep)
            terminal_consistent(context,token,r.pid,r.returncode)
    finally: f.close()
for kind in ['duplicate','missing','symlink','mode','foreign','parent','binary','wrong-dir','result-symlink','stale-result']:
    def bad_context(f):
        f.owner(f.fence)
        context,token=f.context()
        if kind=='duplicate': context.write_text(context.read_text()+'pid=1\n')
        elif kind=='missing': context.write_text(context.read_text().replace('keep=1\n',''))
        elif kind=='mode': context.chmod(0o644)
        elif kind=='symlink':
            p=context.parent/'real'; context.rename(p); context.symlink_to(p)
        elif kind=='foreign': f.owner(f.fence, nonce='replacement')
        elif kind=='binary': context.write_bytes(context.read_bytes()+b'\x00')
        elif kind=='result-symlink': (context.parent/'terminal.tmp').symlink_to(f.root/'foreign')
        elif kind=='stale-result': (context.parent/'terminal').write_text('stale')
        elif kind=='wrong-dir':
            new=f.tmp/'context'; context.rename(new); context=new
        args=['/bin/sh', str(f.cleaner),'--mervlan-cleanup-borrowed',str(context),token]
        if kind=='parent': r=run(['/bin/sh','-c','"$@" & child=$!; wait "$child"', 'unexpected-parent',*args])
        else: r=run(args)
        check(r.returncode==2 and f.install.exists() and f.fence.exists(), 'reject unsafe context '+kind)
    fixture_test(bad_context)

# Run-local one-shot lifecycle: UNCLAIMED -> CLAIMED -> CLAIMED + TERMINAL.
# There is no transition back, including crash/publication failure outcomes.
for busybox in [False,True]:
    borrowed_concurrent(busybox)
    for kind in ['success','known-failure','private-cleanup','publication']:
        borrowed_result_case(kind,busybox)
borrowed_crash()
for kind in ['empty','malformed','file','symlink','dangling','mode']:
    f,context,token=correction_fixture()
    try:
        claim=context.parent/'claim'
        if kind=='file': claim.write_text('foreign')
        elif kind in ['symlink','dangling']:
            target=f.root/'foreign-claim'
            if kind=='symlink': target.mkdir()
            claim.symlink_to(target)
        else:
            claim.mkdir(mode=0o700)
            if kind=='malformed': (claim/'consumer').write_text('pid=1\npid=2\n')
            elif kind=='mode': claim.chmod(0o755)
        before=fence_snapshot(f)
        # Access time may legitimately change while refusing a symlink.
        claim_stat=(claim.lstat().st_ino,claim.lstat().st_mode)
        link=os.readlink(claim) if claim.is_symlink() else None
        data=(claim/'consumer').read_bytes() if kind=='malformed' else None
        r=f.invoke('--mervlan-cleanup-borrowed',str(context),token)
        check(r.returncode==2 and not (f.root/'entries').exists() and
              (claim.lstat().st_ino,claim.lstat().st_mode)==claim_stat and
              (link is None or os.readlink(claim)==link),
              'existing '+kind+' claim blocks consumption unchanged')
        check(fence_snapshot(f)==before and (data is None or (claim/'consumer').read_bytes()==data),
              'foreign/incomplete claim never overwritten; external F unchanged '+kind)
    finally: f.close()
for kind in ['incomplete-crash','context-change','claim-replacement']:
    f,context,token=correction_fixture()
    try:
        s=f.cleaner.read_text()
        if kind=='incomplete-crash': anchor='    cleanup_claim_record > "${CONTEXT%/*}/claim/consumer.tmp"'
        elif kind=='context-change': anchor='    # Re-read context/F after consuming it; metadata binds the same policy'
        else: anchor='            cleanup_prepare || exit 2'
        s=s.replace(anchor,
            f'    touch "{f.root}/claimed"\n'
            f'    while [ ! -e "{f.root}/continue" ]; do sleep 1; done\n'+anchor)
        f.cleaner.write_text(s)
        before=fence_snapshot(f)
        p=f.launch('--mervlan-cleanup-borrowed',str(context),token)
        f.wait_file(f.root/'claimed')
        if kind=='incomplete-crash':
            p.kill(); p.wait(timeout=5)
            check((context.parent/'claim').is_dir() and not (context.parent/'claim/consumer').exists(),
                  'death after atomic mkdir leaves incomplete permanently consumed claim')
        elif kind=='context-change':
            context.write_text(context.read_text().replace('keep=1\n','keep=0\n'))
            (f.root/'continue').touch()
            check(p.wait(timeout=10)==2,'post-claim context policy revalidation refuses tampering')
        else:
            claim=context.parent/'claim'
            claim.rename(context.parent/'original-claim')
            claim.mkdir(mode=0o700)
            (claim/'consumer').write_text('foreign')
            (claim/'consumer').chmod(0o600)
            (f.root/'continue').touch()
            check(p.wait(timeout=10)==2,'frozen worker rejects foreign replacement claim')
        r=f.invoke('--mervlan-cleanup-borrowed',str(context),token)
        check(r.returncode==2 and not (f.root/'entries').exists() and fence_snapshot(f)==before,
              'ambiguous/tampered claimed context cannot replay '+kind)
    finally: f.close()

f,context,token=correction_fixture()
try:
    execution=f.tmp/'.mervlan-full-cleanup.raw.1'
    execution.mkdir(mode=0o700)
    worker=execution/'cleaner.sh'
    shutil.copy(f.cleaner,worker)
    before=fence_snapshot(f)
    r=run(['/bin/sh',str(worker),'--mervlan-cleanup-worker',str(context),token])
    check(r.returncode==2 and not (f.root/'entries').exists() and fence_snapshot(f)==before,
          'raw coordinated worker cannot bypass the atomic claimant')
finally: f.close()

# Runtime-root deletion, direct parent, foreign replacement and signal proofs.
for kind in ['success','foreign','term','kill','worker-kill','ambiguous']:
    f=Fixture('    touch "'+str(Path('/PLACEHOLDER'))+'"')
    # Inject a synchronous barrier after the actual runtime deletion.
    s=f.cleaner.read_text().replace('    touch "/PLACEHOLDER"',
       f'    printf "%s:%s\\n" "$$" "$PPID" > "{f.root}/barrier"\n    while [ ! -e "{f.root}/continue" ]; do sleep 1; done')
    f.cleaner.write_text(s)
    try:
        p=f.launch('--yes','--keep-backups','--no-reboot')
        f.wait_file(f.root/'barrier')
        worker,parent=map(int,(f.root/'barrier').read_text().split(':'))
        check(parent==p.pid and worker!=p.pid, 'relocated destructive worker is direct supervisor child: '+kind)
        check(not f.runtime.exists() and f.fence.exists() and f'pid={p.pid}\n' in (f.fence/'owner').read_text(), 'runtime root gone while F authenticates supervisor: '+kind)
        if kind=='success':
            admission = '''
set -eu
MERV_BASE=$1
. "$MERV_BASE/dev-tools/tests/local/selftest_context.sh"
merv_test_context_enable "$MERV_BASE" "$2"
MERV_FULL_FENCE_PATH=$3
. "$MERV_BASE/settings/lib_mutation_admission.sh"
rpath=$4/locks/ordinary.lock
merv_owner_lock_acquire "$rpath" 60 0 phase6
nonce=$MERV_LOCK_NONCE
identity=$(merv_identity_proc_start "$$")
if merv_mutation_admit_r "$rpath" "$$" "$identity" "$nonce"; then exit 1; fi
[ "$MERV_MUTATION_ADMISSION_REASON" = full-fence-live ]
merv_owner_lock_release "$rpath" "$nonce"
'''
            gate=run(['/bin/sh','-c',admission,'admission',str(BASE),str(f.root),str(f.fence),str(f.runtime)])
            check(gate.returncode==0 and f.runtime.exists(), 'canonical post-R admission blocks recreated runtime owner after root deletion '+gate.stderr)
            shutil.rmtree(f.runtime)
        if kind=='foreign':
            f.fence.rename(f.tmp/'old-fence'); f.owner(f.fence, nonce='replacement')
        elif kind in ['term','ambiguous']: p.send_signal(signal.SIGTERM)
        elif kind=='kill': p.kill()
        elif kind=='worker-kill': os.kill(worker,signal.SIGKILL)
        if kind=='ambiguous':
            rc=p.wait(timeout=15)
            check(rc==4 and f.fence.exists(), 'unresponsive worker retains F after bounded signal wait')
            (f.root/'continue').touch()
        else:
            (f.root/'continue').touch()
            rc=p.wait(timeout=10)
            expected={'success':0,'foreign':4,'term':3,'kill':-9,'worker-kill':4}[kind]
            check(rc==expected and f.fence.exists()==(kind in ['foreign','kill','worker-kill']), 'terminal/signal fence outcome: '+kind+f' rc={rc}')
        # Let workers orphaned by deliberately killed supervisors finish.
        for _ in range(60):
            try:
                stat=Path(f'/proc/{worker}/stat').read_text().rsplit(') ',1)[1].split()
                if stat[0]=='Z': break
            except FileNotFoundError: break
            time.sleep(.05)
        else: raise AssertionError('fixture worker still active')
    finally: f.close()

for outcome in ['success','known-failure']:
    f=Fixture(busybox=True)
    try:
        if outcome=='known-failure':
            p=f.root/'jffs/addons/mervlan.asp'; p.mkdir()
        r=f.invoke('--yes','--keep-backups','--no-reboot')
        check(r.returncode==(0 if outcome=='success' else 3) and not f.fence.exists(), 'BusyBox execution and terminal wait '+outcome+' '+r.stderr)
    finally: f.close()
f=Fixture()
try:
    s=f.cleaner.read_text().replace('    if [ "$SIGNALLED" = 1 ] || ! cleanup_context_write; then',
       f'    touch "{f.root}/before-worker"\n    while [ ! -e "{f.root}/continue" ]; do sleep 1; done\n    if [ "$SIGNALLED" = 1 ] || ! cleanup_context_write; then')
    f.cleaner.write_text(s)
    p=f.launch('--yes','--keep-backups','--no-reboot')
    f.wait_file(f.root/'before-worker')
    check(f.fence.exists() and f.install.exists(), 'F held before worker spawn')
    p.terminate(); time.sleep(.1); (f.root/'continue').touch()
    check(p.wait(timeout=5)==2 and f.install.exists() and not f.fence.exists(), 'TERM before worker releases exact F without destruction')
finally: f.close()

# Exercise the actual process scanner with synthetic proc cmdlines. No kill is
# issued and no live proc path is modified.
f=Fixture()
try:
    proc=f.root/'proc'; proc.mkdir()
    body=function('process_matches_mervlan')+'\n'+function('find_mervlan_processes').replace('/proc',str(proc))
    body+=f"\nmkdir '{proc}'/$$ '{proc}'/$PPID '{proc}'/99999999\nprintf '%s\\000' /jffs/addons/mervlan/old.sh > '{proc}'/$$/cmdline\nprintf '%s\\000' /jffs/addons/mervlan/old.sh > '{proc}'/$PPID/cmdline\nprintf '%s\\000' /jffs/addons/mervlan/old.sh > '{proc}'/99999999/cmdline\nfind_mervlan_processes\n"
    r=run(['/bin/sh','-c',body])
    check(r.returncode==0 and r.stdout.strip()=='99999999', 'process scan excludes actual $$ and PPID and still matches old MerVLAN')
finally: f.close()

# Real narrow teardown calls remove owned chains and preserve unrelated chains.
f=Fixture()
try:
    chains=f.root/'chains'; chains.mkdir()
    for name in ['MERV_QT','MERV_MAC','MERV_DHCP_HOLD','MERV_TRUNK_eth2','_merv_test_4','MERV_TRUNK_eth2_extra','administrator']:
        (chains/name).touch()
    (f.bin/'ebtables').write_text(f'''#!/bin/sh
root={chains}
case "$3" in
  -L) if [ "$#" = 4 ]; then [ -f "$root/$4" ]; else
        for chain in "$root"/*; do printf 'Bridge chain: %s, entries: 0\n' "${{chain##*/}}"; done; fi ;;
  -D) exit 1 ;;
  -F) [ -f "$root/$4" ] ;;
  -X) rm "$root/$4" ;;
  *) exit 1 ;;
esac
''')
    r=f.invoke('--yes','--keep-backups','--no-reboot')
    check(r.returncode==0 and sorted(p.name for p in chains.iterdir())==['MERV_TRUNK_eth2_extra','administrator'], 'real ebtables teardown preserves unrelated and near-match chains '+r.stderr)
finally: f.close()
# Approved exact volatile paths disappear; adjacent administrator paths remain.
f=Fixture()
try:
    for name in ['mervlan_recovery','mervlan_repair.123','mervlan_carrier_snap.123','mervlan_unrelated','mervlan_tmp_other']:
        (f.tmp/name).mkdir()
    r=f.invoke('--yes','--keep-backups','--no-reboot')
    check(r.returncode==0 and not (f.tmp/'mervlan_recovery').exists() and not (f.tmp/'mervlan_repair.123').exists() and not (f.tmp/'mervlan_carrier_snap.123').exists() and (f.tmp/'mervlan_unrelated').exists() and (f.tmp/'mervlan_tmp_other').exists(), 'exact/pattern volatile scope preserves adjacent administrator paths')
finally: f.close()

# CRU and narrow chain matching use the original unmodified parser functions.
r=run(['/bin/sh',str(BASE/'functions/mervlan_full_cleanup.sh'),'--mervlan-cleanup-test-cru-parser'], input='* * * * * /jffs/addons/mervlan/functions/health.sh #mervlan_health#\n* * * * * /jffs/addons/mervlan/functions/health.sh #other#\n* * * * * /other #mervlan_foreign#\n')
check(r.returncode==0 and r.stdout.strip()=='mervlan_health','CRU exact ownership parser')
for chain,expected in [('MERV_TRUNK_eth4',0),('_merv_test_12',0),('MERV_TRUNK_eth4_extra',1),('other',1)]:
    r=run(['/bin/sh','-c',function('mervlan_discovered_ebtables_chain_name')+'\nmervlan_discovered_ebtables_chain_name "$1"','chains',chain])
    check(r.returncode==expected,'narrow owned ebtables chain '+chain)
for cmd,expected in [('/jffs/addons/mervlan/functions/old.sh',0),('/tmp/.mervlan-full-uninstall.lock',1),('/tmp/.mervlan-full-cleanup.1/cleaner.sh',1),('/tmp/mervlan_repair.123/repair.sh',0)]:
    r=run(['/bin/sh','-c',function('process_matches_mervlan')+'\nprocess_matches_mervlan "$1"','process',cmd])
    check(r.returncode==expected,'process matcher '+cmd)
check('rm -rf /tmp/mervlan*' not in SOURCE and F'{"/tmp/.mervlan-full-uninstall.lock"}' not in SOURCE.split('MERVLAN_OWNED_PATHS="',1)[1].split('"',1)[0], 'volatile cleanup excludes F and broad mervlan glob')
print(f'CLEANER_PHASE6_SUMMARY checks={COUNT} failures=0', flush=True)
