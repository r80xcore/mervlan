#!/usr/bin/env python3
"""Host-only isolated qualification for standalone persistent Repair."""
from __future__ import annotations
from hashlib import sha256
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import tarfile
import tempfile
import time
import io

ROOT = Path(__file__).resolve().parents[4]
ENGINE = ROOT / 'functions/update_mervlan_repair.sh'
MANIFEST_PATH = ROOT / 'functions/update_mervlan_repair.manifest'
MANIFEST = MANIFEST_PATH.read_bytes()
FILES = [line.split(' ', 1) for line in MANIFEST.decode().splitlines()[2:]]
assert len(FILES) == 58
REF = 'a' * 40
TEST_SHELL = ['/bin/sh']


def busybox_engine_bytes(engine):
    busybox = shutil.which('busybox')
    assert busybox
    handoff = b'exec /bin/sh "$_rhw_engine"'
    assert engine.count(handoff) == 1
    engine = engine.replace(handoff, f'exec {busybox} ash "$_rhw_engine"'.encode())
    start = b'\nset -u\n'
    # A standalone BusyBox can resolve applets ahead of PATH. Route fault
    # shims explicitly so their tests exercise the same injection boundaries.
    shims = 'sync() { "${TEST_BIN_WRAPPERS:?}/sync" "$@"; }\n'
    for applet in ('cat', 'cmp', 'cp', 'df', 'mv', 'sleep'):
        shims += f'''{applet}() {{
  if [ -x "${{TEST_BIN_WRAPPERS:-/nonexistent}}/{applet}" ]; then
    "$TEST_BIN_WRAPPERS/{applet}" "$@"
  else
    command {applet} "$@"
  fi
}}
'''
    return engine.replace(start, start + shims.encode(), 1)


class Fixture:
    def __init__(self):
        self.root = Path(tempfile.mkdtemp(prefix='mervlan_standalone_fixture.'))
        self.base = self.root / 'jffs/addons/mervlan'
        self.base.mkdir(parents=True)
        self.tmp = self.root / 'tmp'
        self.tmp.mkdir()
        self.backups = self.root / 'jffs/addons/mervlan_backups'
        self.locks = self.root / 'locks'
        self.locks.mkdir()
        self.proc = self.root / 'proc'
        self.proc.mkdir()
        self.fakebin = self.root / 'fakebin'
        self.fakebin.mkdir()
        self.meminfo = self.root / 'meminfo'
        self.meminfo.write_text('MemAvailable: 400000 kB\n')
        self.archive = self.root / 'snapshot.tar.gz'
        self.make_archive()
        self.make_curl()
        self.make_sync()
        self.original = {}
        self.protected = {}
        self.absent = {'changelog.txt', 'functions/mervlan_node_runner.sh'}
        for i, (mode, rel) in enumerate(FILES):
            dest = self.base / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            if rel in self.absent:
                continue
            # Deliberately invalid old shell content: Repair must preserve raw bytes.
            data = b'\x00old-invalid::' + rel.encode() + b'\n\xff\x80'
            dest.write_bytes(data)
            old_mode = 0o600 if i % 2 == 0 else 0o640
            dest.chmod(old_mode)
            self.original[rel] = (data, old_mode)
        self.add_protected('settings/settings.json', b'{"General":{"kept":"yes"}}\n', 0o600)
        self.add_protected('.ssh/vlan_manager', b'private-key-placeholder\n', 0o600)
        self.add_protected('.ssh/vlan_manager.pub', b'public-key-placeholder\n', 0o644)
        self.add_protected('tmp/mac_shield.db', b'mac-shield-db\n', 0o600)
        self.add_protected('tmp/mac_shield_override.db', b'mac-override-db\n', 0o600)
        self.add_protected('tmp/client_name_override.db', b'client-name-db\n', 0o600)
        self.add_protected('flags/.install_ok', b'install-marker\n', 0o600)
        self.add_protected('www/settings/hardware_profiles.json', b'{"profile":"keep"}\n', 0o600)
        self.env = os.environ.copy()
        self.env.update({
            'MERV_BASE': str(self.base),
            'MERV_REPAIR_TMP_ROOT': str(self.tmp),
            'MERV_REPAIR_PROC_ROOT': str(self.proc),
            'MERV_REPAIR_OWNER_PROC_ROOT': '/proc',
            'MERV_REPAIR_MEMINFO': str(self.meminfo),
            'MERV_REPAIR_LOCK': str(self.locks / 'mervlan_maintenance.lock'),
            'MERV_REPAIR_ACTION_LOCK': str(self.locks / 'mervlan_action.lock'),
            'MERV_REPAIR_MANAGER_LOCK': str(self.locks / 'mervlan_manager.lock'),
            'MERV_REPAIR_LEGACY_LOCK_ROOT': str(self.locks),
            'MERV_REPAIR_BACKUP_ROOT': str(self.backups),
            'MERV_REPAIR_SNAPSHOT_BASE': 'https://fixture.invalid/snapshot',
            'MERV_REPAIR_CURL': str(self.fakebin / 'curl'),
            'MERV_REPAIR_TEST_ONLY': '1',
            'TEST_ARCHIVE': str(self.archive),
            'TEST_BIN_WRAPPERS': str(self.fakebin),
            'PATH': str(self.fakebin) + os.pathsep + os.environ.get('PATH', '/usr/bin:/bin'),
        })

    def make_archive(self, engine_override=None):
        with tarfile.open(self.archive, 'w:gz', format=tarfile.USTAR_FORMAT) as tar:
            for mode, rel in FILES:
                if rel == 'functions/update_mervlan_repair.manifest':
                    data = MANIFEST
                elif rel == 'functions/update_mervlan_repair.sh':
                    data = ENGINE.read_bytes() if engine_override is None else engine_override
                elif rel.endswith('.sh') or rel in ('install.sh', 'uninstall.sh'):
                    data = ('#!/bin/sh\n# fixture replacement: ' + rel + '\n:\n').encode()
                else:
                    data = ('fixture replacement: ' + rel + '\n').encode()
                info = tarfile.TarInfo('mervlan-fixture/' + rel)
                info.size = len(data)
                info.mode = int(mode, 8)
                tar.addfile(info, io.BytesIO(data))

    def make_curl(self):
        curl = self.fakebin / 'curl'
        curl.write_text('''#!/bin/sh
: "${TEST_ARCHIVE:?}"
out=
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then out=$2; shift 2; continue; fi
  shift
done
[ -n "$out" ] || exit 2
cp "$TEST_ARCHIVE" "$out"
''')
        curl.chmod(0o755)

    def make_sync(self):
        sync = self.fakebin / 'sync'
        sync.write_text('''#!/bin/sh
[ -n "${MERV_REPAIR_SYNC_COUNTER:-}" ] || exit 0
count=0
[ ! -f "$MERV_REPAIR_SYNC_COUNTER" ] || read count <"$MERV_REPAIR_SYNC_COUNTER"
case "$count" in ''|*[!0-9]*) exit 2 ;; esac
count=$((count + 1))
printf '%s\\n' "$count" >"$MERV_REPAIR_SYNC_COUNTER"
[ "$count" != "${MERV_REPAIR_SYNC_FAIL_AT:-}" ]
''')
        sync.chmod(0o755)

    def add_protected(self, rel, data, mode):
        path = self.base / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(mode)
        self.protected[rel] = (data, mode)

    def run(self, extra=None, helper=None, timeout=90):
        env = self.env.copy()
        env.update(extra or {})
        engine = helper or ENGINE
        return subprocess.run([*TEST_SHELL, str(engine), REF], env=env, capture_output=True,
                              text=True, timeout=timeout)

    def start(self, extra=None):
        env = self.env.copy()
        env.update(extra or {})
        if env.get('MERV_REPAIR_TEST_PAUSE_AT'):
            pause = self.fakebin / 'sleep'
            pause.write_text('#!/bin/sh\n: >"$TEST_PAUSE_MARKER"\nexec /bin/sleep "$@"\n')
            pause.chmod(0o755)
            env['TEST_PAUSE_MARKER'] = str(self.root / 'publication.paused')
        return subprocess.Popen([*TEST_SHELL, str(ENGINE), REF], env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                start_new_session=True)

    def bundle(self):
        found = list(self.backups.glob('mervlan.repair.*'))
        assert len(found) == 1, f'expected one backup bundle, got {found}'
        return found[0]

    def assert_original(self):
        for rel, (data, mode) in self.original.items():
            path = self.base / rel
            assert path.read_bytes() == data, f'original bytes differ: {rel}'
            assert path.stat().st_mode & 0o7777 == mode, f'original mode differs: {rel}'
        for rel in self.absent:
            assert not (self.base / rel).exists(), f'originally absent path exists: {rel}'

    def assert_protected(self):
        for rel, (data, mode) in self.protected.items():
            path = self.base / rel
            assert path.read_bytes() == data, f'protected bytes differ: {rel}'
            assert path.stat().st_mode & 0o7777 == mode, f'protected mode differs: {rel}'

    def assert_replaced(self):
        for mode, rel in FILES:
            path = self.base / rel
            assert path.is_file() and not path.is_symlink(), f'missing replacement: {rel}'
            assert path.stat().st_mode & 0o777 == int(mode, 8), f'new mode differs: {rel}'
            assert path.read_bytes() != self.original.get(rel, (None,))[0], f'not replaced: {rel}'

    def reboot_tmp(self):
        # The transaction evidence is on simulated JFFS; locks and /tmp vanish on reboot.
        shutil.rmtree(self.locks, ignore_errors=True)
        self.locks.mkdir()
        shutil.rmtree(self.tmp, ignore_errors=True)
        self.tmp.mkdir()

    def close(self):
        shutil.rmtree(self.root, ignore_errors=True)


def ok(result):
    assert result.returncode == 0, f'rc={result.returncode}\n{result.stderr[-5000:]}'


def refused(result, text=None):
    assert result.returncode != 0, 'unexpected success'
    if text:
        assert text in result.stderr, f'missing refusal {text!r}: {result.stderr[-2500:]}'


def make_live_lock(path, pid=None, nonce='fixture-live-owner', sidecars=True):
    pid = pid or os.getpid()
    stat = Path(f'/proc/{pid}/stat').read_text()
    start = stat.rsplit(')', 1)[1].split()[19]
    now = str(int(time.time()))
    values = {
        'pid': str(pid), 'proc_start_time': start,
        'owner_nonce': nonce, 'created': now, 'heartbeat': now,
    }
    path.mkdir(mode=0o700)
    (path / 'owner').write_text(''.join(f'{key}={value}\n' for key, value in values.items()))
    (path / 'owner').chmod(0o600)
    if sidecars:
        for key, value in values.items():
            sidecar = path / key
            sidecar.write_text(value + '\n')
            sidecar.chmod(0o600)
    return values


def install_mv_injector(f):
    wrapper = f.fakebin / 'mv'
    wrapper.write_text('''#!/bin/sh
dest=
for arg do dest=$arg; done
/bin/mv "$@" || exit $?
if [ -n "${MERV_TEST_DROP_SELF_STAT:-}" ] && [ "$dest" = "${MERV_TEST_ACTION_OWNER_DEST:-}" ]; then
  pid=$(cat "$MERV_TEST_PID_FILE") || exit 2
  rm -f "$MERV_TEST_OWNER_PROC_ROOT/$pid/stat"
fi
if [ -n "${MERV_TEST_DROP_ACTION_OWNER:-}" ] && [ "$dest" = "${MERV_TEST_MANAGER_OWNER_DEST:-}" ]; then
  rm -f "$MERV_TEST_ACTION_OWNER_DEST"
fi
''')
    wrapper.chmod(0o755)


def gate_curl_until_owner_proc_ready(f):
    real = f.fakebin / 'curl.real'
    (f.fakebin / 'curl').rename(real)
    wrapper = f.fakebin / 'curl'
    wrapper.write_text('''#!/bin/sh
"$MERV_TEST_REAL_CURL" "$@" || exit $?
waited=0
while [ ! -e "$MERV_TEST_CURL_GATE" ]; do
  waited=$((waited + 1))
  [ "$waited" -lt 1000 ] || exit 124
  sleep 0.01
done
''')
    wrapper.chmod(0o755)
    return real


def wait_for_pending_and_kill(f, proc):
    deadline = time.time() + 45
    while time.time() < deadline:
        if (f.root / 'publication.paused').is_file():
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait(timeout=10)
            bundle = f.bundle()
            journal = (bundle / 'journal').read_text()
            assert 'state=publishing\n' in journal and journal.count('pending|') == 58
            return bundle
        if proc.poll() is not None:
            out, err = proc.communicate()
            raise AssertionError(f'repair exited before interruption gate: {proc.returncode}\n{err[-3000:]}')
        time.sleep(0.05)
    proc.kill()
    out, err = proc.communicate()
    raise AssertionError(f'timed out waiting for interrupted publication\n{err[-3000:]}')


def current_state(f, rel):
    path = f.base / rel
    return path.read_bytes() if path.exists() or path.is_symlink() else None


def test_success_and_observation():
    f = Fixture()
    try:
        # A read-only dispatcher and an unrelated observation lock do not block Repair.
        pd = f.proc / '987654'
        pd.mkdir()
        (pd / 'cmdline').write_bytes((str(f.base / 'functions/service-event-handler.sh') +
                                      '\0collectclients_vlanmgr\0').encode())
        (f.locks / 'client_observation.lock').mkdir()
        r = f.run()
        ok(r)
        assert 'ADMISSION' in r.stderr and 'action, maintenance and Manager ownership acquired' in r.stderr
        f.assert_replaced()
        f.assert_protected()
        bundle = f.bundle()
        assert (bundle / 'READY').is_file() and (bundle / 'recover.sh').is_file()
        helper = bundle / 'recover.sh'
        assert helper.read_bytes() == ENGINE.read_bytes(), 'recovery helper is not an exact engine copy'
        assert helper.stat().st_mode & 0o7777 == 0o700, 'recovery helper mode is not private/executable'
        assert (bundle / 'journal').read_text().splitlines()[-1] == 'state=committed'
        # Deliberately invalid originals were never parsed or executed.
        for rel, (data, _) in f.original.items():
            if rel.endswith('.sh'):
                assert data.startswith(b'\x00old-invalid')
        # A byte-valid committed backup remains ineligible for restoration.
        r = subprocess.run([*TEST_SHELL, str(helper), 'recover', bundle.name],
                           env=f.env, capture_output=True, text=True, timeout=60)
        refused(r, 'committed repair is not eligible for rollback')
        f.assert_replaced()
        f.assert_protected()
    finally:
        f.close()


def test_lock_conflict_refuses_without_stealing():
    f = Fixture()
    try:
        lock = Path(f.env['MERV_REPAIR_MANAGER_LOCK'])
        lock.mkdir()
        (lock / 'pid').write_text('999999\n')
        before = {rel: (f.base / rel).read_bytes() for rel in f.original}
        r = f.run()
        refused(r, 'action, maintenance or Manager ownership is unavailable')
        assert 'admission=manager_lock_failed reason=owner_record_incomplete' in r.stderr
        assert lock.is_dir() and (lock / 'pid').read_text() == '999999\n'
        for rel, data in before.items():
            assert (f.base / rel).read_bytes() == data
        assert not list(f.backups.glob('mervlan.repair.*'))
    finally:
        f.close()

    f = Fixture()
    try:
        lock = Path(f.env['MERV_REPAIR_ACTION_LOCK'])
        make_live_lock(lock)
        before = {rel: (f.base / rel).read_bytes() for rel in f.original}
        r = f.run()
        refused(r, 'action, maintenance or Manager ownership is unavailable')
        assert 'admission=action_lock_busy reason=live_owner' in r.stderr
        assert (lock / 'owner').is_file() and (lock / 'pid').read_text() == str(os.getpid()) + '\n'
        for rel, data in before.items():
            assert (f.base / rel).read_bytes() == data
        assert not list(f.backups.glob('mervlan.repair.*'))
    finally:
        f.close()


def test_canonical_owner_record_diagnostics():
    # The canonical owner record is authoritative; absent compatibility
    # sidecars do not hide a live owner or permit Repair to take its lock.
    f = Fixture()
    try:
        lock = Path(f.env['MERV_REPAIR_ACTION_LOCK'])
        make_live_lock(lock, sidecars=False)
        r = f.run()
        refused(r, 'action, maintenance or Manager ownership is unavailable')
        assert 'admission=action_lock_busy reason=live_owner' in r.stderr
        assert (lock / 'owner').is_file()
        assert not list(f.backups.glob('mervlan.repair.*'))
    finally:
        f.close()

    for mode, expected in (
        ('incomplete', 'admission=action_lock_failed reason=owner_record_incomplete'),
        ('malformed', 'admission=action_lock_failed reason=owner_record_invalid'),
        ('unsafe', 'admission=action_lock_failed reason=lock_object_unsafe'),
    ):
        f = Fixture()
        try:
            lock = Path(f.env['MERV_REPAIR_ACTION_LOCK'])
            if mode == 'unsafe':
                lock.write_text('unexpected file object\n')
            else:
                lock.mkdir(mode=0o700)
                if mode == 'malformed':
                    (lock / 'owner').write_text('pid=not-a-pid\n')
            r = f.run()
            refused(r, 'action, maintenance or Manager ownership is unavailable')
            assert expected in r.stderr, f'{mode}: {r.stderr[-2000:]}'
            assert not list(f.backups.glob('mervlan.repair.*'))
        finally:
            f.close()

    f = Fixture()
    try:
        lock = Path(f.env['MERV_REPAIR_MANAGER_LOCK'])
        make_live_lock(lock)
        r = f.run()
        refused(r, 'action, maintenance or Manager ownership is unavailable')
        assert 'admission=manager_lock_busy reason=live_owner' in r.stderr
        assert not Path(f.env['MERV_REPAIR_ACTION_LOCK']).exists()
        assert not Path(f.env['MERV_REPAIR_LOCK']).exists()
        assert lock.is_dir(), 'live Manager owner was altered'
    finally:
        f.close()


def test_authenticated_action_parent_contract():
    f = Fixture()
    try:
        lock = Path(f.env['MERV_REPAIR_ACTION_LOCK'])
        owner = make_live_lock(lock, nonce='fixture-parent-owner')
        env = {
            'MERV_ACTION_LOCK_PARENT_HELD': '1',
            'MERV_ACTION_LOCK_PARENT_PID': owner['pid'],
            'MERV_ACTION_LOCK_PARENT_START': owner['proc_start_time'],
            'MERV_ACTION_LOCK_PARENT_NONCE': owner['owner_nonce'],
            'MERV_ACTION_LOCK_PATH': str(lock),
        }
        parent = f.proc / owner['pid']
        parent.mkdir()
        (parent / 'stat').write_bytes((Path('/proc') / owner['pid'] / 'stat').read_bytes())
        cmdline = parent / 'cmdline'
        cmdline.write_bytes(os.fsencode(f.base / 'functions/service-event-handler.sh') + b'\0repair\0')
        r = f.run(env)
        ok(r)
        assert 'action, maintenance and Manager ownership acquired' in r.stderr
        assert (lock / 'owner').is_file(), 'Repair released its inherited parent lock'
        assert not Path(f.env['MERV_REPAIR_LOCK']).exists()
        assert not Path(f.env['MERV_REPAIR_MANAGER_LOCK']).exists()
        f.assert_replaced()
        f.assert_protected()
        cmdline.write_bytes(os.fsencode(f.base) + b'/functions/./service-event-handler.sh\0repair\0')
        refused(f.run(env), 'initial legacy mutator exclusion failed')
        assert (lock / 'owner').is_file()
    finally:
        f.close()

    f = Fixture()
    try:
        lock = Path(f.env['MERV_REPAIR_ACTION_LOCK'])
        owner = make_live_lock(lock, nonce='fixture-parent-owner')
        r = f.run({
            'MERV_ACTION_LOCK_PARENT_HELD': '1',
            'MERV_ACTION_LOCK_PARENT_PID': owner['pid'],
            'MERV_ACTION_LOCK_PARENT_START': owner['proc_start_time'],
            'MERV_ACTION_LOCK_PARENT_NONCE': owner['owner_nonce'],
            'MERV_ACTION_LOCK_PATH': str(f.locks / 'noncanonical_action.lock'),
        })
        refused(r, 'action lock parent is malformed or unauthenticated')
        assert 'admission=action_parent_invalid' in r.stderr
        assert (lock / 'owner').is_file(), 'invalid parent path altered canonical owner'
        assert not Path(f.env['MERV_REPAIR_LOCK']).exists()
        assert not Path(f.env['MERV_REPAIR_MANAGER_LOCK']).exists()
    finally:
        f.close()


def test_transient_live_action_lock_is_a_nonblocking_refusal():
    f = Fixture()
    holder = subprocess.Popen(['sleep', '30'])
    try:
        lock = Path(f.env['MERV_REPAIR_ACTION_LOCK'])
        make_live_lock(lock, pid=holder.pid, nonce='fixture-transient-owner')
        started = time.monotonic()
        r = f.run()
        elapsed = time.monotonic() - started
        refused(r, 'action, maintenance or Manager ownership is unavailable')
        assert 'admission=action_lock_busy reason=live_owner' in r.stderr
        assert elapsed < 10, f'action lock contention unexpectedly blocked for {elapsed:.2f}s'
        assert lock.is_dir(), 'live action lock was altered during refusal'
        assert not list(f.backups.glob('mervlan.repair.*'))
    finally:
        holder.terminate()
        holder.wait(timeout=5)
        f.close()


def test_each_lock_step_reports_failure_and_releases_prior_locks():
    for stage in ('action', 'maintenance', 'manager'):
        f = Fixture()
        try:
            blocker = f.root / f'{stage}-parent-is-a-file'
            blocker.write_text('not a directory\n')
            bad_lock = str(blocker / 'lock')
            if stage == 'action':
                extra = {'MERV_REPAIR_ACTION_LOCK': bad_lock}
            elif stage == 'maintenance':
                extra = {'MERV_REPAIR_LOCK': bad_lock}
            else:
                extra = {'MERV_REPAIR_MANAGER_LOCK': bad_lock}
            r = f.run(extra)
            refused(r, 'action, maintenance or Manager ownership is unavailable')
            assert f'admission={stage}_lock_failed reason=unsafe_lock_path' in r.stderr
            assert not Path(f.env['MERV_REPAIR_ACTION_LOCK']).exists(), \
                f'{stage} failure retained a previously acquired action lock'
            assert not Path(f.env['MERV_REPAIR_LOCK']).exists(), \
                f'{stage} failure retained a previously acquired maintenance lock'
            assert not Path(f.env['MERV_REPAIR_MANAGER_LOCK']).exists(), \
                f'{stage} failure left the Manager lock acquired'
            assert not list(f.backups.glob('mervlan.repair.*'))
        finally:
            f.close()


def test_self_owner_verification_diagnostics():
    # A deterministic host-only mv seam invalidates the fake /proc generation
    # after the action owner record is published, exercising its self-check.
    f = Fixture()
    owner_proc = f.root / 'owner-proc'
    owner_proc.mkdir()
    gate = f.root / 'curl.gate'
    pid_file = f.root / 'repair.pid'
    action_lock = Path(f.env['MERV_REPAIR_ACTION_LOCK'])
    install_mv_injector(f)
    real_curl = gate_curl_until_owner_proc_ready(f)
    proc = f.start({
        'MERV_REPAIR_OWNER_PROC_ROOT': str(owner_proc),
        'MERV_TEST_OWNER_PROC_ROOT': str(owner_proc),
        'MERV_TEST_PID_FILE': str(pid_file),
        'MERV_TEST_ACTION_OWNER_DEST': str(action_lock / 'owner'),
        'MERV_TEST_DROP_SELF_STAT': '1',
        'MERV_TEST_REAL_CURL': str(real_curl),
        'MERV_TEST_CURL_GATE': str(gate),
    })
    try:
        child_proc = owner_proc / str(proc.pid)
        child_proc.mkdir()
        (child_proc / 'stat').write_text(Path(f'/proc/{proc.pid}/stat').read_text())
        pid_file.write_text(str(proc.pid) + '\n')
        gate.touch()
        _, stderr = proc.communicate(timeout=90)
        assert proc.returncode != 0
        assert 'admission=action_lock_failed reason=self_owner_verification_failed' in stderr, stderr[-3000:]
        assert (action_lock / 'owner').is_file(), 'unverified claim evidence was unexpectedly removed'
        assert not Path(f.env['MERV_REPAIR_LOCK']).exists()
        assert not Path(f.env['MERV_REPAIR_MANAGER_LOCK']).exists()
        assert not list(f.backups.glob('mervlan.repair.*'))
    finally:
        if proc.poll() is None:
            proc.kill(); proc.wait()
        f.close()

    # The combined owner check catches a lost action record after all three
    # acquisitions; cleanup releases the still-authenticated later locks.
    f = Fixture()
    install_mv_injector(f)
    action_lock = Path(f.env['MERV_REPAIR_ACTION_LOCK'])
    manager_lock = Path(f.env['MERV_REPAIR_MANAGER_LOCK'])
    r = f.run({
        'MERV_TEST_ACTION_OWNER_DEST': str(action_lock / 'owner'),
        'MERV_TEST_MANAGER_OWNER_DEST': str(manager_lock / 'owner'),
        'MERV_TEST_DROP_ACTION_OWNER': '1',
    })
    try:
        refused(r, 'action, maintenance or Manager ownership is unavailable')
        assert 'admission=self_owner_validation_failed reason=action_owner_invalid' in r.stderr
        assert not Path(f.env['MERV_REPAIR_LOCK']).exists(), 'maintenance lock was not released'
        assert not manager_lock.exists(), 'Manager lock was not released'
        assert action_lock.is_dir() and not (action_lock / 'owner').exists(), \
            'unverifiable action lock evidence was unexpectedly removed'
    finally:
        f.close()


def test_snapshot_engine_mismatch_refuses_before_admission():
    f = Fixture()
    try:
        before = {rel: (path.read_bytes(), path.stat().st_mode & 0o7777)
                  for rel in f.original
                  for path in (f.base / rel,)}
        f.make_archive(ENGINE.read_bytes() + b'\n# different executable identity\n')
        r = f.run()
        refused(r, 'downloaded Repair executable does not match trusted bootstrap')
        for rel, (data, mode) in before.items():
            path = f.base / rel
            assert path.read_bytes() == data and path.stat().st_mode & 0o7777 == mode
        f.assert_protected()
        assert not list(f.backups.glob('mervlan.repair.*'))
        for name in ('mervlan_action.lock', 'mervlan_maintenance.lock', 'mervlan_manager.lock'):
            assert not (f.locks / name).exists(), f'lock acquired before source identity check: {name}'
        workdirs = list(f.tmp.glob('mervlan_lean.*'))
        assert len(workdirs) == 1 and not (workdirs[0] / '.handoff').exists(), \
            'mismatched executable reached handoff publication'
    finally:
        f.close()


def test_publication_failure_rolls_back():
    f = Fixture()
    try:
        r = f.run({'MERV_REPAIR_TEST_FAIL_AFTER_AT': '9'})
        refused(r, 'publication failed')
        f.assert_original()
        f.assert_protected()
        bundle = f.bundle()
        assert (bundle / 'journal').read_text().splitlines()[-1] == 'state=rolled-back'
    finally:
        f.close()


def test_backup_sync_failure_stops_before_ready_or_publication():
    f = Fixture()
    try:
        counter = f.root / 'sync.calls'
        r = f.run({'MERV_REPAIR_SYNC_COUNTER': str(counter),
                   'MERV_REPAIR_SYNC_FAIL_AT': '1'})
        refused(r, 'persistent manifest backup failed; no installed files were replaced')
        f.assert_original()
        f.assert_protected()
        bundle = f.bundle()
        assert not (bundle / 'READY').exists(), 'backup was marked ready after sync failure'
        assert (bundle / 'journal').read_text().splitlines()[-1] == 'state=prepared'
        assert not list(f.base.glob('**/*.mervlan-repair.*.publish.part'))
    finally:
        f.close()


def test_precommit_sync_failure_rolls_back():
    f = Fixture()
    try:
        counter = f.root / 'sync.calls'
        r = f.run({'MERV_REPAIR_SYNC_COUNTER': str(counter),
                   'MERV_REPAIR_SYNC_FAIL_AT': '5'})
        refused(r, 'could not durably flush verified replacement files')
        f.assert_original()
        f.assert_protected()
        bundle = f.bundle()
        assert (bundle / 'journal').read_text().splitlines()[-1] == 'state=rolled-back'
    finally:
        f.close()


def test_final_commit_sync_failure_retains_verified_files_and_evidence():
    f = Fixture()
    try:
        counter = f.root / 'sync.calls'
        r = f.run({'MERV_REPAIR_SYNC_COUNTER': str(counter),
                   'MERV_REPAIR_SYNC_FAIL_AT': '6'})
        refused(r, 'could not durably finish the Repair transaction')
        f.assert_replaced()
        f.assert_protected()
        bundle = f.bundle()
        assert (bundle / 'journal').read_text().splitlines()[-1] == 'state=committed'
        assert list(f.tmp.glob('mervlan_lean.*')), 'failure evidence workspace was removed'
    finally:
        f.close()


def test_interruption_recovery_without_installed_helpers():
    f = Fixture()
    proc = f.start({'MERV_REPAIR_TEST_PAUSE_AT': '9'})
    try:
        bundle = wait_for_pending_and_kill(f, proc)
        # Exercise a genuinely mixed state, then remove installed lifecycle helpers.
        changed = sum((f.base / rel).read_bytes() != data for rel, (data, _) in f.original.items())
        assert changed == 7, f'expected seven originally present files among the first eight publications, got {changed}'
        for rel in ('functions/update_mervlan.sh', 'functions/mervlan_boot.sh', 'functions/mervlan_recover.sh'):
            (f.base / rel).unlink()
        r = subprocess.run([*TEST_SHELL, str(bundle / 'recover.sh'), 'recover', bundle.name],
                           env=f.env, capture_output=True, text=True, timeout=60)
        ok(r)
        f.assert_original()
        f.assert_protected()
        assert (bundle / 'journal').read_text().splitlines()[-1] == 'state=rolled-back'
        # Recovery classified and quarantined only the three complete lock
        # records left by the killed process; their evidence remains inspectable.
        assert len(list(f.locks.glob('.*.repair-stale.*'))) == 3
    finally:
        if proc.poll() is None:
            proc.kill(); proc.wait()
        f.close()


def test_corrupt_backup_refuses_before_restore():
    f = Fixture()
    proc = f.start({'MERV_REPAIR_TEST_PAUSE_AT': '5'})
    try:
        bundle = wait_for_pending_and_kill(f, proc)
        mixed_before = {rel: current_state(f, rel) for _, rel in FILES}
        original_file = bundle / 'original/functions/update_mervlan.sh'
        original_file.write_bytes(b'corrupted backup\n')
        f.reboot_tmp()
        r = subprocess.run([*TEST_SHELL, str(bundle / 'recover.sh'), 'recover', bundle.name],
                           env=f.env, capture_output=True, text=True, timeout=60)
        refused(r, 'backup is incomplete or corrupt')
        for _, rel in FILES:
            assert current_state(f, rel) == mixed_before[rel], f'recovery mutated {rel} before refusing'
        latest_state = next(line for line in reversed((bundle / 'journal').read_text().splitlines())
                            if line.startswith('state='))
        assert latest_state == 'state=publishing'
    finally:
        if proc.poll() is None:
            proc.kill(); proc.wait()
        f.close()


def test_unknown_publication_temporary_refuses_before_restore():
    f = Fixture()
    proc = f.start({'MERV_REPAIR_TEST_PAUSE_AT': '5'})
    try:
        bundle = wait_for_pending_and_kill(f, proc)
        mixed_before = {rel: current_state(f, rel) for _, rel in FILES}
        _, rel = FILES[4]
        tmp = Path(str(f.base / rel) + f'.mervlan-repair.{bundle.name}.publish.part')
        tmp.write_bytes(b'unknown partial publication temp\n')
        r = subprocess.run([*TEST_SHELL, str(bundle / 'recover.sh'), 'recover', bundle.name],
                           env=f.env, capture_output=True, text=True, timeout=60)
        refused(r, 'unknown or unsafe destination state')
        for _, path in FILES:
            assert current_state(f, path) == mixed_before[path], f'recovery mutated {path} before refusing'
        f.assert_protected()
    finally:
        if proc.poll() is None:
            proc.kill(); proc.wait()
        f.close()


def test_journal_validator_rejects_corrupt_evidence():
    with tempfile.TemporaryDirectory(prefix='mervlan-journal-test.') as directory:
        root = Path(directory)
        ledger = root / 'journal'
        script = root / 'validate.sh'
        script.write_bytes(ENGINE.read_bytes().split(b'\ntrap cleanup 0\n', 1)[0] +
                           b'\nCOHORT=$1 LEDGER=$2\njournal_validate || exit 1\nprintf "%s\\n" "$JOURNAL_STATE"\n')
        cohort = root / 'cohort'
        cohort.write_bytes(b'\n'.join(MANIFEST.splitlines()[2:]) + b'\n')
        prepared = b'format=1\nstate=prepared\n'
        publishing = prepared + b'state=publishing\n'
        records = b''.join(f'pending|{rel}\ndone|{rel}\n'.encode() for _, rel in FILES)
        pending, done = records.splitlines(keepends=True)[:2]
        malformed = (
            b'', b'format=2\nstate=prepared\n', b'format=1\n',
            prepared + pending, publishing + b'state=unknown\n',
            publishing + b'pending|outside/manifest\n',
            publishing + b'pending|./changelog.txt\n',
            publishing + b'pending|changelog.txt|extra\n',
            publishing + b'pending|changelog.txt \n',
            publishing + pending + pending, publishing + done + done,
            publishing + pending.rstrip(b'\n') + b'\0' + done,
            publishing + b'state=committed\n',
            publishing + records + b'state=committed\nstate=rolled-back\n',
            publishing + b'x' * 16384,
        )
        expected = ((prepared, 'prepared'), (publishing + pending, 'publishing'),
                    (publishing + records + b'state=committed', 'committed'),
                    (publishing + records + b'state=rolled-back\n', 'rolled-back'))
        for data, state in (*expected, *((data, None) for data in malformed)):
            ledger.write_bytes(data)
            result = subprocess.run([*TEST_SHELL, script, cohort, ledger], capture_output=True,
                                    text=True, timeout=5)
            assert (result.returncode == 0) == (state is not None), data[:160]
            if state is not None:
                assert result.stdout.strip() == state, result.stdout


def test_journal_copy_failure_preserves_recoverable_prefix():
    f = Fixture()
    try:
        cat = f.fakebin / 'cat'
        cat.write_text("""#!/bin/sh
case "${1:-}" in
  */journal)
    if [ ! -e "$TEST_COPY_FAILED" ] && grep -qx 'state=publishing' "$1"; then
      : >"$TEST_COPY_FAILED"
      printf 'format=1\\n'
      exit 1
    fi ;;
esac
exec /bin/cat "$@"
""")
        cat.chmod(0o755)
        marker = f.root / 'copy-failed'
        result = f.run({'TEST_COPY_FAILED': str(marker)})
        refused(result, 'could not durably mark the verified repair committed')
        assert marker.exists()
        f.assert_original()
        f.assert_protected()
        journal = (f.bundle() / 'journal').read_text()
        assert journal.count('pending|') == 58 and 'done|' not in journal
        assert journal.endswith('state=rolled-back\n'), journal
    finally:
        f.close()


def test_partial_sibling_creation_never_publishes_and_refuses_unknown_recovery():
    for interruption in ('sigkill', 'allocation-failure'):
        f = Fixture()
        try:
            cp = f.fakebin / 'cp'
            if interruption == 'sigkill':
                action = 'kill -KILL "$PPID"\nexit 99'
            else:
                action = 'exit 1'
            cp.write_text('''#!/bin/sh
dest=
for arg do dest=$arg; done
case "$dest" in
  *.publish.part)
    printf 'partial sibling fixture\\n' >"$dest" || exit 2
    ACTION
    ;;
esac
exec /bin/cp "$@"
'''.replace('ACTION', action))
            cp.chmod(0o755)
            result = f.run()
            if interruption == 'sigkill':
                assert result.returncode == -signal.SIGKILL, (result.returncode, result.stderr[-2000:])
            else:
                refused(result, 'publication failed')
                assert 'synchronous rollback incomplete' in result.stderr

            bundle = f.bundle()
            journal = (bundle / 'journal').read_text()
            assert journal.count('pending|') == 58 and 'done|' not in journal
            assert 'state=publishing\n' in journal
            siblings = list(f.base.glob('**/*.publish.part'))
            assert len(siblings) == 1 and siblings[0].read_bytes() == b'partial sibling fixture\n'
            f.assert_original()
            f.assert_protected()
            if interruption == 'allocation-failure':
                assert not list(f.locks.iterdir()), 'Repair left a lock owned after staging failure'

            f.reboot_tmp()
            recovery = subprocess.run([*TEST_SHELL, bundle / 'recover.sh', 'recover', bundle.name],
                                      env=f.env, capture_output=True, text=True, timeout=60)
            refused(recovery, 'unknown or unsafe destination state')
            assert siblings[0].exists(), 'unknown sibling evidence was removed'
            f.assert_original()
            f.assert_protected()
        finally:
            f.close()


def test_interruption_at_durable_transaction_boundaries():
    for gate in ('before-ready', 'after-ready', 'after-intent', 'before-rename', 'after-rename',
                 'between-files', 'before-batch-flush', 'damaged-preflush',
                 'before-commit', 'during-rollback'):
        f = Fixture()
        try:
            sync = f.fakebin / 'sync'
            sync_real = f.fakebin / 'sync.real'
            sync.rename(sync_real)
            sync.write_text("""#!/bin/sh
"$TEST_BIN/sync.real" "$@" || exit $?
read count <"$MERV_REPAIR_SYNC_COUNTER" || exit 2
case "$TEST_GATE:$count" in
  before-ready:1|after-ready:2|after-intent:3|before-batch-flush:4|damaged-preflush:4|before-commit:5)
    kill -KILL "$PPID" ;;
esac
""")
            sync.chmod(0o755)
            mv = f.fakebin / 'mv'
            mv.write_text("""#!/bin/sh
for dest do :; done
case "$TEST_GATE:$dest" in
  before-rename:*/changelog.txt|between-files:*/mervlan.asp)
    kill -KILL "$PPID"
    exit 1 ;;
esac
/bin/mv "$@" || exit $?
case "$TEST_GATE:$dest" in
  after-rename:*/changelog.txt|during-rollback:*/mervlan.asp)
    # The rollback case only matches the restore rename.
    case "$TEST_GATE:$*" in
      after-rename:*|during-rollback:*.restore.part*) kill -KILL "$PPID" ;;
    esac ;;
esac
""")
            mv.chmod(0o755)
            extra = {'TEST_GATE': gate, 'TEST_BIN': str(f.fakebin),
                     'MERV_REPAIR_SYNC_COUNTER': str(f.root / 'sync.calls')}
            if gate == 'during-rollback':
                extra['MERV_REPAIR_TEST_FAIL_AFTER_AT'] = '9'
            result = f.run(extra)
            assert result.returncode == -signal.SIGKILL, (gate, result.stderr)
            bundle = f.bundle()
            journal = (bundle / 'journal').read_text()
            if gate not in ('before-ready', 'after-ready'):
                assert journal.count('pending|') == 58
                assert 'done|' not in journal and 'state=committed' not in journal
            if gate in ('before-ready', 'after-ready'):
                assert journal.endswith('state=prepared\n')
                f.assert_original()
            elif gate == 'after-intent':
                assert not list(f.base.glob('**/*.publish.part'))
                f.assert_original()
            elif gate in ('before-rename', 'after-rename'):
                assert (f.base / 'changelog.txt').exists() == (gate == 'after-rename')
            elif gate == 'between-files':
                assert (f.base / 'changelog.txt').is_file()
            elif gate in ('before-batch-flush', 'damaged-preflush'):
                assert len(list(f.base.glob('**/*.publish.part'))) == 58
                f.assert_original()
                if gate == 'damaged-preflush':
                    next(f.base.glob('**/*.publish.part')).write_bytes(b'partial synthetic sibling\n')
            elif gate == 'before-commit':
                f.assert_replaced()
            else:
                assert current_state(f, 'mervlan.asp') == f.original['mervlan.asp'][0]
            mv.unlink()
            sync_real.replace(sync)
            f.reboot_tmp()
            recovery = subprocess.run([*TEST_SHELL, bundle / 'recover.sh', 'recover', bundle.name],
                                      env=f.env, capture_output=True, text=True, timeout=60)
            if gate == 'before-ready':
                refused(recovery, 'backup is incomplete or corrupt')
            elif gate == 'damaged-preflush':
                refused(recovery, 'unknown or unsafe destination state')
                refused(f.run(), 'previous transaction unresolved' if f.env.get('FULL') == '0'
                        else 'persistent manifest backup failed')
            else:
                ok(recovery)
                assert (bundle / 'journal').read_text().endswith('state=rolled-back\n')
            f.assert_original()
            f.assert_protected()
        finally:
            f.close()


def test_low_flash_keeps_one_sibling_barrier():
    f = Fixture()
    try:
        df = f.fakebin / 'df'
        df.write_text("""#!/bin/sh
if [ "$2" = "$MERV_BASE" ]; then
  printf 'Filesystem Blocks Used Available Capacity Mounted\\nfixture 20000 11296 8704 57%% /fixture\\n'
else
  exec /bin/df "$@"
fi
""")
        df.chmod(0o755)
        counter = f.root / 'sync.calls'
        result = f.run({'MERV_REPAIR_SYNC_COUNTER': str(counter)})
        ok(result)
        assert int(counter.read_text()) == 63
        f.assert_replaced()
        f.assert_protected()
    finally:
        f.close()


def test_legacy_writer_appearing_between_batch_renames():
    f = Fixture()
    try:
        mv = f.fakebin / 'mv'
        mv.write_text("""#!/bin/sh
for dest do :; done
/bin/mv "$@" || exit $?
if [ "$dest" = "$MERV_BASE/changelog.txt" ]; then
  mkdir "$MERV_REPAIR_PROC_ROOT/987655" || exit 1
  printf '%s\\000' "$MERV_BASE/functions/./update_mervlan.sh" >"$MERV_REPAIR_PROC_ROOT/987655/cmdline"
fi
""")
        mv.chmod(0o755)
        refused(f.run(), 'publication failed')
        assert (f.base / 'changelog.txt').is_file()
        assert current_state(f, 'mervlan.asp') == f.original['mervlan.asp'][0]
        shutil.rmtree(f.proc / '987655')
        f.reboot_tmp()
        bundle = f.bundle()
        recovery = subprocess.run([*TEST_SHELL, bundle / 'recover.sh', 'recover', bundle.name],
                                  env=f.env, capture_output=True, text=True, timeout=60)
        ok(recovery)
        f.assert_original()
        f.assert_protected()
    finally:
        f.close()


def test_legacy_writer_conflict_and_missing_ready():
    for pid, relative in (('987655', 'functions/update_mervlan.sh'),
                           ('987656', 'functions/mervlan_backup.sh'),
                           ('987657', 'functions/mervlan_recover.sh')):
        f = Fixture()
        try:
            procdir = f.proc / pid
            procdir.mkdir()
            (procdir / 'cmdline').write_bytes((str(f.base / relative) + '\0').encode())
            r = f.run()
            refused(r, 'initial legacy mutator exclusion failed')
        finally:
            f.close()

    g = Fixture()
    proc = g.start({'MERV_REPAIR_TEST_PAUSE_AT': '4'})
    try:
        bundle = wait_for_pending_and_kill(g, proc)
        mixed_before = {rel: current_state(g, rel) for _, rel in FILES}
        (bundle / 'READY').unlink()
        g.reboot_tmp()
        r = subprocess.run([*TEST_SHELL, str(bundle / 'recover.sh'), 'recover', bundle.name],
                           env=g.env, capture_output=True, text=True, timeout=60)
        refused(r, 'backup is incomplete or corrupt')
        for _, rel in FILES:
            assert current_state(g, rel) == mixed_before[rel]
        r = g.run()
        refused(r, 'previous transaction unresolved' if g.env.get('FULL') == '0'
                else 'persistent manifest backup failed; no installed files were replaced')
        for _, rel in FILES:
            assert current_state(g, rel) == mixed_before[rel], f'new Repair mutated {rel} with a missing prior backup'
    finally:
        if proc.poll() is None:
            proc.kill(); proc.wait()
        g.close()


def test_owner_format_matches_canonical_library():
    f = Fixture()
    proc = f.start({'MERV_REPAIR_TEST_PAUSE_AT': '1'})
    try:
        deadline = time.time() + 30
        while time.time() < deadline:
            owner = Path(f.env['MERV_REPAIR_ACTION_LOCK']) / 'owner'
            if owner.is_file():
                break
            if proc.poll() is not None:
                out, err = proc.communicate()
                raise AssertionError(f'repair exited before lock inspection\n{err[-3000:]}')
            time.sleep(0.05)
        owner = Path(f.env['MERV_REPAIR_ACTION_LOCK']) / 'owner'
        assert owner.is_file()
        contract = """. "$OWNER_LIBRARY"
MERV_OWNER_LOCK_PROC_ROOT=/proc
merv_owner_v2_read "$LOCK_PATH" || exit 1
[ "$MERV_OWNER_V2_PID" = "$(sed -n 's/^pid=//p' "$LOCK_PATH/owner")" ] || exit 1
"""
        # Validate the active lock using the repository's authoritative parser.
        check = subprocess.run(['/bin/sh', '-c', contract], env={**f.env,
            'OWNER_LIBRARY': str(ROOT / 'settings/lib_owner_lock.sh'),
            'LOCK_PATH': str(Path(f.env['MERV_REPAIR_ACTION_LOCK']))},
            capture_output=True, text=True, errors='replace')
        assert check.returncode == 0, check.stderr
        proc.send_signal(signal.SIGTERM)
        proc.communicate(timeout=15)
        assert proc.returncode != 0
    finally:
        if proc.poll() is None:
            proc.kill(); proc.wait()
        f.close()


def install_correct_cohort(f):
    with tarfile.open(f.archive) as snapshot:
        for mode, rel in FILES:
            target = f.base / rel
            target.write_bytes(snapshot.extractfile(f'mervlan-fixture/{rel}').read())
            target.chmod(int(mode, 8))
    f.absent.clear()
    f.original = {rel: ((f.base / rel).read_bytes(), int(mode, 8)) for mode, rel in FILES}


def installed_inodes(f):
    return {rel: (f.base / rel).stat().st_ino for _, rel in FILES if (f.base / rel).is_file()}


def damage_selection(f, count):
    # Gaps exercise the separate index readers in both publication paths.
    selected = [rel for _, rel in FILES[::2][:count]] if count < 58 else [rel for _, rel in FILES]
    for i, rel in enumerate(selected):
        target = f.base / rel
        data, mode = f.original[rel]
        if i == 0:
            target.chmod(0o600)
            f.original[rel] = (data, 0o600)
        elif i == 1:
            target.unlink()
            f.absent.add(rel)
            del f.original[rel]
        else:
            broken = bytes([data[0] ^ 1]) + data[1:]
            target.write_bytes(broken)
            f.original[rel] = (broken, mode)
    return set(selected)


def assert_cohort_matches_snapshot(f):
    with tarfile.open(f.archive) as snapshot:
        for mode, rel in FILES:
            target = f.base / rel
            assert target.read_bytes() == snapshot.extractfile(f'mervlan-fixture/{rel}').read(), rel
            assert target.stat().st_mode & 0o7777 == int(mode, 8), rel
    f.assert_protected()


def accepted_r2(f):
    engine = subprocess.check_output(
        ['git', 'show', '321d5afac2b4de9441846014e9dddb80e701ae8d:'
         'functions/update_mervlan_repair.sh'], cwd=ROOT)
    assert sha256(engine).hexdigest() == 'acdb9ffa862cfda43019f77ac6749eb670ea0f48f584bae543727afc1b96d57e'
    path = f.root / 'accepted-r2.sh'
    path.write_bytes(engine)
    return path


def test_selective_replacement_counts_and_original_inodes():
    for count in (0, 1, 10, 58):
        f = Fixture()
        try:
            install_correct_cohort(f)
            selected = damage_selection(f, count)
            before = installed_inodes(f)
            counter = f.root / 'sync.calls'
            r = f.run({'FULL': '0', 'MERV_REPAIR_SYNC_COUNTER': str(counter)})
            ok(r)
            assert f'replaced={count}' in r.stderr
            changed = {rel for rel, inode in installed_inodes(f).items() if before.get(rel) != inode}
            assert changed == selected, (count, changed, selected)
            assert_cohort_matches_snapshot(f)
            if count:
                bundle = f.bundle()
                journal = (bundle / 'journal').read_text()
                assert journal.count('pending|') == journal.count('done|') == 58
                assert len((bundle / 'index').read_text().splitlines()) == 58
                assert counter.read_text() == '6\n'
            else:
                assert not f.backups.exists() and not counter.exists()
                assert not list(f.tmp.iterdir()) and not list(f.locks.iterdir())
        finally:
            f.close()


def test_selective_noop_prior_transaction_and_reverification():
    f = Fixture()
    try:
        install_correct_cohort(f)
        before = installed_inodes(f)
        old = f.backups / 'mervlan.repair.earlier'
        old.mkdir(parents=True)
        journal = old / 'journal'
        journal.write_text('format=1\nstate=prepared\nstate=publishing\n')
        refused(f.run({'FULL': '0'}), 'previous transaction unresolved')
        journal.write_text('format=1\nstate=prepared\n')
        ok(f.run({'FULL': '0'}))
        assert list(f.backups.iterdir()) == [old]
        assert installed_inodes(f) == before
        # Change a target immediately after its first correct comparison. This
        # simulates a file change between classification and final verification.
        cmp = f.fakebin / 'cmp'
        cmp.write_text('''#!/bin/sh
/usr/bin/cmp "$@" || exit $?
if [ "${3:-}" = "$MERV_BASE/changelog.txt" ]; then
  printf 'changed after comparison' >"$3"
fi
''')
        cmp.chmod(0o755)
        refused(f.run({'FULL': '0'}), 'selective no-op verification failed')
        assert list(f.backups.iterdir()) == [old]
        assert installed_inodes(f) == before
    finally:
        f.close()


def test_full_republishes_even_correct_targets_and_preserves_bundle():
    f = Fixture()
    try:
        install_correct_cohort(f)
        before = installed_inodes(f)
        ok(f.run({'FULL': '1'}))
        bundle = f.bundle()
        originals = {p: p.read_bytes() for p in bundle.rglob('*') if p.is_file()}
        assert all(before[rel] != inode for rel, inode in installed_inodes(f).items())
        before = installed_inodes(f)
        ok(f.run({'FULL': '0'}))
        assert installed_inodes(f) == before
        assert list(f.backups.iterdir()) == [bundle]
        assert all(p.read_bytes() == payload for p, payload in originals.items())
        assert_cohort_matches_snapshot(f)
    finally:
        f.close()


def test_preserves_predecessor_bundles():
    f = Fixture()
    try:
        r2 = accepted_r2(f)
        f.make_archive(r2.read_bytes())
        ok(subprocess.run(['/bin/sh', r2, REF], env={**f.env, 'FULL': '1'},
                          capture_output=True, text=True, timeout=90))
        old_r2 = f.bundle()
        # Model the R1 journal ordering with a complete, digest-valid bundle.
        old_r1 = old_r2.with_name('mervlan.repair.r1-fixture')
        shutil.copytree(old_r2, old_r1)
        journal = old_r1 / 'journal'
        journal.write_text('format=1\nstate=prepared\nstate=publishing\n' +
                           ''.join(f'pending|{rel}\ndone|{rel}\n' for _, rel in FILES) +
                           'state=committed\n')
        ready = old_r1 / 'READY'
        ready.write_text(ready.read_text().replace(old_r2.name, old_r1.name))
        before = {p: (p.read_bytes(), p.stat().st_ino)
                  for directory in (old_r1, old_r2) for p in directory.rglob('*') if p.is_file()}
        f.make_archive()
        # The R3 engine is the only incorrect target on the R2 installation.
        ok(f.run({'FULL': '0'}))
        assert len(list(f.backups.iterdir())) == 3
        assert all((p.read_bytes(), p.stat().st_ino) == state for p, state in before.items())
        assert_cohort_matches_snapshot(f)
    finally:
        f.close()


def test_sparse_selective_recovery_both_engines():
    for use_r2 in (False, True):
        f = Fixture()
        proc = None
        try:
            install_correct_cohort(f)
            selected = damage_selection(f, 10)
            before = installed_inodes(f)
            proc = f.start({'FULL': '0', 'MERV_REPAIR_TEST_PAUSE_AT': '4'})
            bundle = wait_for_pending_and_kill(f, proc)
            assert sum(before.get(rel) != inode for rel, inode in installed_inodes(f).items()) == 3
            f.reboot_tmp()
            helper = bundle / 'recover.sh'
            if use_r2:
                helper = accepted_r2(f)
            # Keep the R3 helper named by READY untouched. R2 is the separate
            # trusted recovery executable and authenticates the R3 bundle.
            shell = ['/bin/sh'] if use_r2 else TEST_SHELL
            ok(subprocess.run([*shell, helper, 'recover', bundle.name],
                              env=f.env, capture_output=True, text=True, timeout=60))
            f.assert_original()
            f.assert_protected()
            for rel, inode in installed_inodes(f).items():
                if rel not in selected:
                    assert inode == before[rel], rel
        finally:
            if proc is not None and proc.poll() is None:
                proc.kill()
                proc.wait()
            f.close()


def test_refuses_unsafe_objects_invalid_full_and_resource_floors():
    for defect in ('invalid-mode', 'empty-mode', 'symlink', 'fifo', 'directory', 'unreadable',
                   'bad-archive', 'ram', 'tmp', 'flash'):
        f = Fixture()
        try:
            target = f.base / 'mervlan.asp'
            original = target.read_bytes()
            extra = {}
            if defect == 'invalid-mode':
                extra['FULL'] = '2'
            elif defect == 'empty-mode':
                extra['FULL'] = ''
            elif defect in ('symlink', 'fifo', 'directory'):
                target.unlink()
                if defect == 'symlink':
                    target.symlink_to(f.meminfo)
                elif defect == 'fifo':
                    os.mkfifo(target)
                else:
                    target.mkdir()
            elif defect == 'unreadable':
                if os.geteuid() == 0:
                    continue
                target.chmod(0)
            elif defect == 'bad-archive':
                f.archive.write_bytes(b'malformed gzip')
            elif defect == 'ram':
                f.meminfo.write_text('MemAvailable: 32767 kB\n')
            else:
                df = f.fakebin / 'df'
                path = f.tmp if defect == 'tmp' else f.base
                df.write_text(f'''#!/bin/sh
if [ "$2" = "{path}" ]; then
  printf 'Filesystem Blocks Used Available Capacity Mounted\\nfixture 8000 7000 1000 88%% /fixture\\n'
else
  exec /bin/df "$@"
fi
''')
                df.chmod(0o755)
            result = f.run(extra)
            refused(result)
            assert not list(f.base.rglob('*.publish.part')) and ' PUBLISH ' not in result.stderr
            if defect == 'unreadable':
                target.chmod(0o640)
            if defect not in ('symlink', 'fifo', 'directory'):
                assert target.read_bytes() == original
            f.assert_protected()
        finally:
            f.close()


def test_corrupt_index_ready_and_helper_refuse_before_changes():
    for name in ('index', 'READY', 'recover.sh', 'journal'):
        f = Fixture()
        proc = f.start({'MERV_REPAIR_TEST_PAUSE_AT': '3'})
        try:
            bundle = wait_for_pending_and_kill(f, proc)
            before = installed_inodes(f)
            path = bundle / name
            path.write_bytes(path.read_bytes() + b'corrupt\n')
            f.reboot_tmp()
            # Use the separately trusted candidate, including when the
            # bundled executable itself is the damaged file.
            result = subprocess.run([*TEST_SHELL, ENGINE, 'recover', bundle.name],
                                    env=f.env, capture_output=True, text=True, timeout=60)
            refused(result, 'backup is incomplete or corrupt')
            assert installed_inodes(f) == before
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
            f.close()


def test_recovery_refuses_unknown_installed_content():
    f = Fixture()
    proc = f.start({'MERV_REPAIR_TEST_PAUSE_AT': '4'})
    try:
        bundle = wait_for_pending_and_kill(f, proc)
        target = f.base / 'mervlan.asp'
        target.write_bytes(b'unknown installed bytes after interruption\n')
        mixed = {rel: current_state(f, rel) for _, rel in FILES}
        inodes = installed_inodes(f)
        f.reboot_tmp()
        result = subprocess.run([*TEST_SHELL, bundle / 'recover.sh', 'recover', bundle.name],
                                env=f.env, capture_output=True, text=True, timeout=60)
        refused(result, 'unknown or unsafe destination state')
        assert {rel: current_state(f, rel) for _, rel in FILES} == mixed
        assert installed_inodes(f) == inodes
        f.assert_protected()
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        f.close()


def test_final_verification_failure_rolls_back():
    f = Fixture()
    try:
        cmp = f.fakebin / 'cmp'
        cmp.write_text('''#!/bin/sh
if [ -e "$MERV_REPAIR_SYNC_COUNTER" ] && [ "${3:-}" = "$MERV_BASE/changelog.txt" ]; then
  exit 2
fi
exec /usr/bin/cmp "$@"
''')
        cmp.chmod(0o755)
        counter = f.root / 'sync.calls'
        result = f.run({'MERV_REPAIR_SYNC_COUNTER': str(counter)})
        refused(result, 'final content, mode, protected-state or owner verification failed')
        f.assert_original()
        f.assert_protected()
        assert (f.bundle() / 'journal').read_text().endswith('state=rolled-back\n')
    finally:
        f.close()


def test_sparse_selective_low_flash():
    f = Fixture()
    try:
        install_correct_cohort(f)
        selected = damage_selection(f, 10)
        before = installed_inodes(f)
        df = f.fakebin / 'df'
        df.write_text('''#!/bin/sh
if [ "$2" = "$MERV_BASE" ]; then
  printf 'Filesystem Blocks Used Available Capacity Mounted\\nfixture 20000 11296 8704 57%% /fixture\\n'
else
  exec /bin/df "$@"
fi
''')
        df.chmod(0o755)
        counter = f.root / 'sync.calls'
        ok(f.run({'FULL': '0', 'MERV_REPAIR_SYNC_COUNTER': str(counter)}))
        assert counter.read_text() == '15\n'
        assert {rel for rel, inode in installed_inodes(f).items() if before.get(rel) != inode} == selected
        assert_cohort_matches_snapshot(f)
    finally:
        f.close()


def classification_race(case, seam='df', historical=False):
    f = Fixture()
    try:
        install_correct_cohort(f)
        selected = 'mervlan.asp'
        target = f.base / selected
        rel = selected
        mode = f.original[selected][1]
        target.write_bytes(b'bad-A\n')
        action = 'cat "$RACE_PAYLOAD" >"$RACE_TARGET"'
        payload = b'bad-B\n'
        if case == 'invalid-to-correct':
            payload = f.original[selected][0]
        elif case == 'mode-to-mode':
            target.write_bytes(f.original[selected][0])
            target.chmod(0o600)
            action = 'chmod 0640 "$RACE_TARGET"'
        elif case == 'present-to-absent':
            action = 'rm "$RACE_TARGET"'
        elif case == 'absent-to-present':
            target.unlink()
            action += f' && chmod {mode:o} "$RACE_TARGET"'
        elif case in ('unselected-content', 'unselected-mode', 'final-target'):
            rel = FILES[-1][1] if case == 'final-target' else FILES[0][1]
            if case == 'unselected-mode':
                action = 'chmod 0600 "$RACE_TARGET"'
        elif case == 'present-to-symlink':
            action = 'rm "$RACE_TARGET" && ln -s "$RACE_PAYLOAD" "$RACE_TARGET"'

        def states():
            tree = {}
            for _, path in FILES:
                entry = f.base / path
                if entry.is_symlink():
                    tree[path] = ('link', os.readlink(entry))
                elif entry.exists():
                    stat = entry.stat()
                    tree[path] = (entry.read_bytes(), stat.st_mode & 0o7777, stat.st_ino)
            return tree

        before = states()
        payload_path = f.root / 'mutation'
        payload_path.write_bytes(payload)
        trigger = f.root / 'mutated'
        counter = f.root / 'sync.calls'
        env = {'FULL': '0', 'RACE_TARGET': str(f.base / rel), 'RACE_PAYLOAD': str(payload_path),
               'RACE_TRIGGER': str(trigger), 'MERV_REPAIR_SYNC_COUNTER': str(counter)}
        injection = action + ' || exit 97\n: >"$RACE_TRIGGER" || exit 98\n'
        shim = f.fakebin / seam
        if seam == 'df':
            script = ('if [ "$2" = "$MERV_REPAIR_BACKUP_ROOT" ]; then\n' + injection +
                      'fi\nexec /bin/df "$@"\n')
        elif seam == 'cp':
            script = ('for dest do :; done\ncase "$dest" in */original/mervlan.asp)\n' +
                      injection + ';; esac\nexec /bin/cp "$@"\n')
        else:
            shim.rename(f.fakebin / 'sync.real')
            script = ('"$TEST_BIN_WRAPPERS/sync.real" "$@" || exit $?\n'
                      'read count <"$MERV_REPAIR_SYNC_COUNTER" || exit 99\n'
                      'if [ "$count" = 4 ]; then\n' + injection + 'fi\n')
        shim.write_text('#!/bin/sh\n' + script)
        shim.chmod(0o755)
        result = f.run(env)
        assert trigger.is_file(), (case, seam, result.stderr)
        bundle = f.bundle()
        f.assert_protected()
        journal = (bundle / 'journal').read_text()
        if historical:
            ok(result)
            assert (bundle / 'original' / rel).read_bytes() == payload
            assert journal.endswith('state=committed\n')
            assert_cohort_matches_snapshot(f)
            print('REPRODUCED original R3 accepted same-length invalid B and saved it as original', flush=True)
            return
        refused(result, 'publication failed' if seam == 'sync' else 'persistent manifest backup failed')
        assert ' SUCCESS ' not in result.stderr and 'state=committed' not in journal
        records = next(f.tmp.glob('mervlan_lean.*/classified')).read_text().splitlines()
        assert len(records) == len(FILES)
        for record, (_, path) in zip(records, FILES):
            source, approved_mode = f.original[path]
            approved_digest = sha256(source).hexdigest()
            if path not in before:
                assert record == f'new|-|0|-|{approved_digest}|{path}|1'
            else:
                data, original_mode, _ = before[path]
                selected_bit = int((data, original_mode) != (source, approved_mode))
                old_mode = stat.filemode(stat.S_IFREG | original_mode)
                assert record == (f'old|{old_mode}|{len(data)}|{sha256(data).hexdigest()}|'
                                  f'{approved_digest}|{path}|{selected_bit}')
        if seam != 'sync':
            assert journal == 'format=1\nstate=prepared\n'
            assert not (bundle / 'READY').exists() and not counter.exists()
        after = states()
        assert {k: v for k, v in before.items() if k != rel} == {
            k: v for k, v in after.items() if k != rel}, (case, seam)
        if case == 'present-to-absent':
            assert rel not in after
        elif case == 'present-to-symlink':
            assert after[rel] == ('link', str(payload_path))
        elif case in ('mode-to-mode', 'unselected-mode'):
            assert after[rel] == (before[rel][0], 0o640 if case == 'mode-to-mode' else 0o600,
                                  before[rel][2])
        else:
            assert after[rel][0] == payload
            if rel in before:
                assert after[rel][1:] == before[rel][1:]
        print(f'PASS classification race {seam} {case}', flush=True)
    finally:
        f.close()


def test_selective_classification_races():
    for case in ('invalid-to-invalid', 'invalid-to-correct', 'mode-to-mode',
                 'present-to-absent', 'absent-to-present', 'unselected-content',
                 'unselected-mode', 'present-to-symlink', 'final-target'):
        classification_race(case)
    classification_race('invalid-to-invalid', seam='cp')
    classification_race('unselected-content', seam='cp')  # already copied earlier
    classification_race('invalid-to-invalid', seam='sync')


def test_selective_one_content_repair():
    f = Fixture()
    try:
        install_correct_cohort(f)
        rel = 'mervlan.asp'
        path = f.base / rel
        original = path.read_bytes()
        path.write_bytes(bytes([original[0] ^ 1]) + original[1:])
        before = installed_inodes(f)
        result = f.run({'FULL': '0'})
        ok(result)
        assert {name for name, inode in installed_inodes(f).items() if before[name] != inode} == {rel}
        assert_cohort_matches_snapshot(f)
    finally:
        f.close()


def test_interrupted_backup_retains_prepared():
    f = Fixture()
    try:
        cp = f.fakebin / 'cp'
        cp.write_text('''#!/bin/sh
for dest do :; done
/bin/cp "$@" || exit $?
case "$dest" in */original/mervlan.asp) kill -KILL "$PPID" ;; esac
''')
        cp.chmod(0o755)
        result = f.run()
        assert result.returncode == -signal.SIGKILL, result.stderr
        bundle = f.bundle()
        assert (bundle / 'original/mervlan.asp').is_file()
        assert not (bundle / 'READY').exists()
        assert (bundle / 'journal').read_text() == 'format=1\nstate=prepared\n'
        f.assert_original()
        f.assert_protected()
        cp.unlink()
        f.reboot_tmp()
        result = subprocess.run([*TEST_SHELL, bundle / 'recover.sh', 'recover', bundle.name],
                                env=f.env, capture_output=True, text=True, timeout=60)
        refused(result, 'backup is incomplete or corrupt')
        f.assert_original()
        f.assert_protected()
    finally:
        f.close()


def main():
    tests = [
        test_success_and_observation,
        test_snapshot_engine_mismatch_refuses_before_admission,
        test_lock_conflict_refuses_without_stealing,
        test_canonical_owner_record_diagnostics,
        test_authenticated_action_parent_contract,
        test_transient_live_action_lock_is_a_nonblocking_refusal,
        test_each_lock_step_reports_failure_and_releases_prior_locks,
        test_self_owner_verification_diagnostics,
        test_publication_failure_rolls_back,
        test_backup_sync_failure_stops_before_ready_or_publication,
        test_precommit_sync_failure_rolls_back,
        test_final_commit_sync_failure_retains_verified_files_and_evidence,
        test_interruption_recovery_without_installed_helpers,
        test_corrupt_backup_refuses_before_restore,
        test_unknown_publication_temporary_refuses_before_restore,
        test_journal_validator_rejects_corrupt_evidence,
        test_journal_copy_failure_preserves_recoverable_prefix,
        test_partial_sibling_creation_never_publishes_and_refuses_unknown_recovery,
        test_interruption_at_durable_transaction_boundaries,
        test_low_flash_keeps_one_sibling_barrier,
        test_legacy_writer_appearing_between_batch_renames,
        test_legacy_writer_conflict_and_missing_ready,
        test_owner_format_matches_canonical_library,
    ]
    tests += [
        test_selective_replacement_counts_and_original_inodes,
        test_selective_noop_prior_transaction_and_reverification,
        test_full_republishes_even_correct_targets_and_preserves_bundle,
        test_preserves_predecessor_bundles,
        test_sparse_selective_recovery_both_engines,
        test_refuses_unsafe_objects_invalid_full_and_resource_floors,
        test_corrupt_index_ready_and_helper_refuse_before_changes,
        test_recovery_refuses_unknown_installed_content,
        test_final_verification_failure_rolls_back,
        test_sparse_selective_low_flash,
        test_selective_classification_races,
        test_selective_one_content_repair,
        test_interrupted_backup_retains_prepared,
    ]
    names = os.environ.get('MERVLAN_TEST_NAMES', '').split(',')
    if names != ['']:
        tests = [test for test in tests if test.__name__ in names]
        assert len(tests) == len(names), names
    failures = []
    for test in tests:
        try:
            test()
            print('PASS', test.__name__, flush=True)
        except Exception as exc:
            failures.append((test.__name__, str(exc)))
            print('FAIL', test.__name__, exc, flush=True)
    if failures:
        for name, message in failures:
            print('DETAIL', name, message)
        return 1
    print(f'PASS {len(tests)} focused standalone Repair tests')
    return 0


if __name__ == '__main__':
    if os.environ.get('MERVLAN_TEST_BUSYBOX') == '1':
        with tempfile.TemporaryDirectory(prefix='mervlan-busybox-engine.') as directory:
            native = Path(directory) / ENGINE.name
            native.write_bytes(busybox_engine_bytes(ENGINE.read_bytes()))
            ENGINE = native
            TEST_SHELL[:] = [shutil.which('busybox'), 'ash']
            raise SystemExit(main())
    raise SystemExit(main())
