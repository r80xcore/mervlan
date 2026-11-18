#!/usr/bin/env python3
"""Compare immutable and working-tree Repair using isolated host fixtures."""
import argparse
from collections import Counter, defaultdict
from hashlib import sha256
import io
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import tarfile
import tempfile
import time

from test_standalone_persistent_repair import ENGINE, FILES, ROOT, Fixture


REF = 'd97a2ceff369a5cdcc4c216beb61a41aa0a7b3b4'
R1_SHA = '288be05cf5aeb30d73791dc81d9bac28acf826b80c32f51b227b9c3f18bba94e'
BASELINE_SHA = '8e50a80aad7f522d29b13691f7336c145884502996b407f74f810d8a818b8914'
# XT8 pre-trial inventory byte counts in trusted manifest order. Contents are synthetic.
SIZES = (
    183052, 38440, 741201, 51848, 40289, 21515, 11550, 66983,
    73698, 35116, 18437, 5020, 115025, 72414, 83330, 132304,
    30866, 68338, 28991, 63500, 29249, 77954, 2693, 83138,
    10071, 90755, 129465, 152876, 2223, 57882, 189094, 11901,
    8516, 3591, 4954, 12938, 10833, 3953, 62315, 56206,
    44346, 134868, 32459, 3525, 21692, 34229, 12606, 7031,
    106950, 78978, 10671, 15355, 39710, 13784, 111074, 14595,
    5111, 53304,
)
assert len(SIZES) == len(FILES) and sum(SIZES) == 3622812
ENGINE_REL = str(ENGINE.relative_to(ROOT))
PROFILE_FUNCTIONS = (
    'fetch_archive', 'validate_archive', 'stage_files', 'backup_files',
    'publication', 'final_verify', 'journal_validate', 'journal_append',
    'scan_processes', 'sha256_file', 'restore_transaction',
)


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT)


def instrument(engine):
    text = engine.decode()
    wrappers = []
    for name in (*PROFILE_FUNCTIONS, 'sync'):
        target = 'command sync' if name == 'sync' else f'profile_original_{name}'
        if name != 'sync':
            declaration = f'\n{name}() {{'
            assert text.count(declaration) == 1, name
            text = text.replace(declaration, f'\n{target}() {{', 1)
        wrappers.append(f'''{name}() {{
  printf 'PROFILE start {name}\\n' >&9
  if {target} "$@"; then
    printf 'PROFILE end {name}\\n' >&9
    return 0
  else
    profile_rc=$?
    printf 'PROFILE end {name}\\n' >&9
    return "$profile_rc"
  fi
}}''')
    return text.replace('\nmain "$@"', '\n' + '\n'.join(wrappers) + '\nexec 9>&2\nmain "$@"').encode()


def configure(fixture, engine, archive, processes):
    script = fixture.root / 'engine.sh'
    script.write_bytes(engine)
    with tarfile.open(fileobj=io.BytesIO(archive), mode='r:') as source, \
            tarfile.open(fixture.archive, 'w:gz', format=tarfile.USTAR_FORMAT) as dest:
        for entry in source:
            if entry.name == f'mervlan-{REF}/{ENGINE_REL}':
                entry.size = len(engine)
                dest.addfile(entry, io.BytesIO(engine))
            else:
                dest.addfile(entry, source.extractfile(entry) if entry.isfile() else None)
    fixture.absent.clear()
    old = b'old fixture\x00\xff\n'
    for (_, rel), size in zip(FILES, SIZES):
        path = fixture.base / rel
        data = (old * (size // len(old) + 1))[:size]
        path.write_bytes(data)
        path.chmod(0o640)
        fixture.original[rel] = (data, 0o640)
    for pid in range(10000, 10000 + processes):
        proc = fixture.proc / str(pid)
        proc.mkdir()
        (proc / 'cmdline').write_bytes(b'/usr/sbin/fixture-service\x00--foreground\x00')
    # Use the host BusyBox applets involved in journal parsing. Omitting
    # sha256sum forces the production OpenSSL fallback without changing source.
    for name in ('awk', 'cmp', 'tr'):
        (fixture.fakebin / name).symlink_to(shutil.which('busybox'))
    for name in ('cat', 'chmod', 'cp', 'date', 'df', 'grep', 'gzip', 'head',
                 'ls', 'mkdir', 'mv', 'openssl', 'readlink', 'rm', 'rmdir',
                 'sed', 'sh', 'tar', 'wc'):
        (fixture.fakebin / name).symlink_to(shutil.which(name))
    fixture.env['PATH'] = str(fixture.fakebin)
    fixture.env['MERV_REPAIR_SYNC_COUNTER'] = str(fixture.root / 'sync.calls')
    return script


def timed(fixture, script, *args):
    marks, starts, counts = {}, {}, Counter()
    durations = defaultdict(float)
    messages = []
    start = time.perf_counter()
    # Exact shell runs with targeted stderr markers only in the profile copy.
    with subprocess.Popen([shutil.which('timeout'), '-k', '10s', '120s',
                           '/bin/sh', str(script), *args], env=fixture.env,
                          stderr=subprocess.PIPE, text=True) as process:
        for line in process.stderr:
            now = time.perf_counter() - start
            if line.startswith('PROFILE '):
                _, event, name = line.split()
                if event == 'start':
                    starts[name] = now
                    counts[name] += 1
                else:
                    elapsed = now - starts.pop(name)
                    durations[name] += elapsed
                    if name == 'journal_validate' and 'journal_append' in starts:
                        durations['append_validation'] += elapsed
                continue
            messages.append(line)
            if ' PUBLISH ' in line:
                marks[line.split('replaced=')[1].split()[0]] = now
            if ' BACKUP ' in line:
                marks['ready'] = now
        rc = process.wait()
    if rc:
        raise RuntimeError(''.join(messages))
    assert not starts
    total = time.perf_counter() - start
    marks['total'] = total
    marks['counts'] = dict(counts)
    marks['seconds'] = dict(durations)
    return marks


def run(engine, archive, processes, profile):
    f = Fixture()
    try:
        script = configure(f, instrument(engine) if profile else engine, archive, processes)
        result = timed(f, script, REF)
        saved_syncs = int((f.root / 'sync.calls').read_text())
        batched = b'prepare_publication() {' in engine
        expected_counts = (6, 3, 2, 61, 412) if batched else (64, 119, 118, 61, 528)
        assert saved_syncs == expected_counts[0]
        if profile:
            for name, expected in zip(('sync', 'journal_validate', 'journal_append',
                                       'scan_processes', 'sha256_file'), expected_counts):
                assert result['counts'][name] == expected, result['counts']
        result['flushes'] = saved_syncs
        f.assert_replaced()
        f.assert_protected()
        bundle = f.bundle()
        with tarfile.open(f.archive, 'r:gz') as source:
            for _, rel in FILES:
                saved = bundle / 'original' / rel
                original, mode = f.original[rel]
                assert saved.read_bytes() == original and saved.stat().st_mode & 0o7777 == mode
                assert (f.base / rel).read_bytes() == source.extractfile(f'mervlan-{REF}/{rel}').read()
        journal = bundle / 'journal'
        lines = journal.read_bytes().splitlines(keepends=True)
        assert lines[-1] == b'state=committed\n'
        assert len(lines) == 120
        # Replay the pre-commit disk state after successful final verification.
        # The focused suite separately kills real fixture processes at boundaries.
        incomplete = lines[:61] if batched else lines[:-1]
        journal.write_bytes(b''.join(incomplete))
        f.reboot_tmp()
        result['recovery'] = timed(f, bundle / 'recover.sh', 'recover', bundle.name)
        f.assert_original()
        f.assert_protected()
        return result
    finally:
        f.close()


def validator(engine, repeats=10):
    source = engine.split(b'\ntrap cleanup 0\n', 1)[0]
    probe = b'\nCOHORT=$1 LEDGER=$2\n' + (
        f'i=0; while [ "$i" -lt {repeats} ]; do journal_validate || exit 1; '
        'i=$((i+1)); done\n'
    ).encode()
    medians = {}
    with tempfile.TemporaryDirectory(prefix='mervlan-journal-bench.') as directory:
        root = Path(directory)
        busybox = shutil.which('busybox')
        for name in ('awk', 'cmp', 'tr'):
            (root / name).symlink_to(busybox)
        env = {**os.environ, 'PATH': str(root) + os.pathsep + os.environ['PATH']}
        (root / 'script').write_bytes(source + probe)
        (root / 'cohort').write_text(''.join(f'{mode} {rel}\n' for mode, rel in FILES))
        for count in (0, 10, 20, 30, 40, 50, 58):
            (root / 'journal').write_text('format=1\nstate=prepared\nstate=publishing\n' +
                ''.join(f'pending|{rel}\ndone|{rel}\n' for _, rel in FILES[:count]))
            samples = []
            for _ in range(3):
                start = time.perf_counter()
                subprocess.run([shutil.which('timeout'), '-k', '1s', '60s', busybox,
                                'sh', root / 'script', root / 'cohort', root / 'journal'],
                               env=env, check=True)
                samples.append((time.perf_counter() - start) * 1000 / repeats)
            medians[count] = statistics.median(samples)
    return medians


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-engine', type=Path, help='compare against the verified R1 engine copy')
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--processes', type=int, default=64)
    args = parser.parse_args()
    if not 1 <= args.runs <= 10 or not 0 <= args.processes <= 256:
        parser.error('use 1–10 runs and 0–256 synthetic process entries')
    baseline = args.baseline_engine.read_bytes() if args.baseline_engine else git('show', f'{REF}:{ENGINE_REL}')
    assert sha256(baseline).hexdigest() == (R1_SHA if args.baseline_engine else BASELINE_SHA)
    candidate = ENGINE.read_bytes()
    archive = git('archive', '--format=tar', f'--prefix=mervlan-{REF}/', REF)
    engines = {'baseline': baseline, 'candidate': candidate}
    result = {name: {'sha256': sha256(engine).hexdigest(), 'transactions': []}
              for name, engine in engines.items()}
    for _ in range(args.runs):
        for name, engine in engines.items():
            result[name]['transactions'].append(run(engine, archive, args.processes, False))
    for name, engine in engines.items():
        result[name]['profile'] = run(engine, archive, args.processes, True)
        result[name]['validator_ms'] = validator(engine)
    print(json.dumps({'processes': args.processes, 'engines': result}, indent=2))


if __name__ == '__main__':
    main()
