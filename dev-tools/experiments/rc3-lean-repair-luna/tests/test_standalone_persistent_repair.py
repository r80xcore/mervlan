#!/usr/bin/env python3
"""Host-only isolated qualification for standalone persistent Repair."""
from __future__ import annotations
import os
from pathlib import Path
import shutil
import signal
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
        return subprocess.run(['/bin/sh', str(engine), REF], env=env, capture_output=True,
                              text=True, timeout=timeout)

    def start(self, extra=None):
        env = self.env.copy()
        env.update(extra or {})
        return subprocess.Popen(['/bin/sh', str(ENGINE), REF], env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

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


def wait_for_pending_and_kill(f, proc, nth):
    deadline = time.time() + 45
    while time.time() < deadline:
        bundles = list(f.backups.glob('mervlan.repair.*'))
        if bundles and (bundles[0] / 'journal').exists():
            journal = (bundles[0] / 'journal').read_text(errors='replace')
            if 'state=publishing\n' in journal and journal.count('done|') >= nth - 1 and 'pending|' in journal:
                proc.send_signal(signal.SIGKILL)
                proc.wait(timeout=10)
                return bundles[0]
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
        r = subprocess.run(['/bin/sh', str(helper), 'recover', bundle.name],
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
        r = f.run(env)
        ok(r)
        assert 'action, maintenance and Manager ownership acquired' in r.stderr
        assert (lock / 'owner').is_file(), 'Repair released its inherited parent lock'
        assert not Path(f.env['MERV_REPAIR_LOCK']).exists()
        assert not Path(f.env['MERV_REPAIR_MANAGER_LOCK']).exists()
        f.assert_replaced()
        f.assert_protected()
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
                   'MERV_REPAIR_SYNC_FAIL_AT': '2'})
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
                   'MERV_REPAIR_SYNC_FAIL_AT': '63'})
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
                   'MERV_REPAIR_SYNC_FAIL_AT': '64'})
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
        bundle = wait_for_pending_and_kill(f, proc, 9)
        # Exercise a genuinely mixed state, then remove installed lifecycle helpers.
        changed = sum((f.base / rel).read_bytes() != data for rel, (data, _) in f.original.items())
        assert changed == 7, f'expected seven originally present files among the first eight publications, got {changed}'
        for rel in ('functions/update_mervlan.sh', 'functions/mervlan_boot.sh', 'functions/mervlan_recover.sh'):
            (f.base / rel).unlink()
        r = subprocess.run(['/bin/sh', str(bundle / 'recover.sh'), 'recover', bundle.name],
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
        bundle = wait_for_pending_and_kill(f, proc, 5)
        mixed_before = {rel: current_state(f, rel) for _, rel in FILES}
        original_file = bundle / 'original/functions/update_mervlan.sh'
        original_file.write_bytes(b'corrupted backup\n')
        f.reboot_tmp()
        r = subprocess.run(['/bin/sh', str(bundle / 'recover.sh'), 'recover', bundle.name],
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
        bundle = wait_for_pending_and_kill(f, proc, 5)
        mixed_before = {rel: current_state(f, rel) for _, rel in FILES}
        _, rel = FILES[4]
        tmp = Path(str(f.base / rel) + f'.mervlan-repair.{bundle.name}.publish.part')
        tmp.write_bytes(b'unknown partial publication temp\n')
        r = subprocess.run(['/bin/sh', str(bundle / 'recover.sh'), 'recover', bundle.name],
                           env=f.env, capture_output=True, text=True, timeout=60)
        refused(r, 'unknown or unsafe destination state')
        for _, path in FILES:
            assert current_state(f, path) == mixed_before[path], f'recovery mutated {path} before refusing'
        f.assert_protected()
    finally:
        if proc.poll() is None:
            proc.kill(); proc.wait()
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
        bundle = wait_for_pending_and_kill(g, proc, 4)
        mixed_before = {rel: current_state(g, rel) for _, rel in FILES}
        (bundle / 'READY').unlink()
        g.reboot_tmp()
        r = subprocess.run(['/bin/sh', str(bundle / 'recover.sh'), 'recover', bundle.name],
                           env=g.env, capture_output=True, text=True, timeout=60)
        refused(r, 'backup is incomplete or corrupt')
        for _, rel in FILES:
            assert current_state(g, rel) == mixed_before[rel]
        r = g.run()
        refused(r, 'persistent manifest backup failed; no installed files were replaced')
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
        test_legacy_writer_conflict_and_missing_ready,
        test_owner_format_matches_canonical_library,
    ]
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
    raise SystemExit(main())
