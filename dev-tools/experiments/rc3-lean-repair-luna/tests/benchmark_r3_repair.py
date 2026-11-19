#!/usr/bin/env python3
"""Exact R2/R3 invocations with alternating isolated fixture workloads."""
import argparse
from hashlib import sha256
import json
from pathlib import Path
import statistics
import subprocess
import sys
import tarfile
import tempfile
import time

from benchmark_persistent_repair import (
    ENGINE_REL, PROFILE_FUNCTIONS, configure, git, instrument, timed,
)
from test_standalone_persistent_repair import ENGINE, FILES, Fixture

REF = '321d5afac2b4de9441846014e9dddb80e701ae8d'
R2_HASH = 'acdb9ffa862cfda43019f77ac6749eb670ea0f48f584bae543727afc1b96d57e'
R3_HASH = 'c3a56c942f3551c1d5fe0c2534d96b57144e0b3a1dba3365c3c18ac28da732b9'
CASES = {
    'default_correct': (None, 0),
    'full_damaged': ('1', 10),
    'selective_noop': ('0', 0),
    'selective_one': ('0', 1),
    'selective_ten': ('0', 10),
    'selective_all': ('0', 58),
}


def run(engine, archive, name, case, processes, profile=False):
    full, bad_count = CASES[case]
    f = Fixture()
    try:
        if profile:
            funcs = (*PROFILE_FUNCTIONS, 'owner_ok', 'owner_fields_read',
                     'backup_payload_verify', 'mode_value', 'mode_ok', 'prepare_publication')
            if name != 'R2':
                funcs += ('select_publication',)
            engine = instrument(engine, funcs)
        script = configure(f, engine, archive, processes, ref=REF)
        with tarfile.open(f.archive) as snapshot:
            expected = {rel: snapshot.extractfile(f'mervlan-{REF}/{rel}').read() for _, rel in FILES}
        before = {}
        for i, (mode, rel) in enumerate(FILES):
            target = f.base / rel
            data = expected[rel]
            if i == 1 and i < bad_count:
                target.unlink()
                continue
            if 1 < i < bad_count:
                data = bytes([data[0] ^ 1]) + data[1:]  # wrong bytes, correct size
            target.write_bytes(data)
            target.chmod(0o600 if i == 0 and bad_count else int(mode, 8))
            before[rel] = target.stat().st_ino
        f.env.pop('FULL', None)
        if full is not None:
            f.env['FULL'] = full
        if profile:
            add_operation_counters(f)
        result = timed(f, script, REF)
        changes = 0
        for i, (mode, rel) in enumerate(FILES):
            target = f.base / rel
            assert target.read_bytes() == expected[rel], rel
            assert target.stat().st_mode & 0o7777 == int(mode, 8), rel
            changed = before.get(rel) != target.stat().st_ino
            assert changed == (name == 'R2' or full != '0' or i < bad_count), rel
            changes += changed
        f.assert_protected()
        counter = f.root / 'sync.calls'
        result['syncs'] = int(counter.read_text()) if counter.exists() else 0
        result['replacements'] = changes
        result['complete_installed_verifications'] = 58
        result['preclassification_checks'] = 58 if name != 'R2' and full == '0' else 0
        result['private_payload_bytes'] = (
            f.archive.stat().st_size + 2 * sum(map(len, expected.values())) +
            sum(len(data) for data, _ in f.protected.values()))
        assert result['syncs'] == (6 if changes else 0)
        assert bool(list(f.backups.glob('mervlan.repair.*'))) == bool(changes)
        if changes:
            bundle = f.bundle()
            result['bundle_bytes'] = sum(p.stat().st_size for p in bundle.rglob('*') if p.is_file())
            result['peak_siblings_bytes'] = sum(len(expected[rel]) for _, rel in
                                                FILES[:changes])
            journal = (bundle / 'journal').read_bytes()
            assert journal.endswith(b'state=committed\n')
            prepared = b'format=1\nstate=prepared\n'
            publishing = prepared + b'state=publishing\n' + b''.join(
                line for line in journal.splitlines(keepends=True) if line.startswith(b'pending|'))
            result['journal_image_bytes_written'] = len(prepared) + len(publishing) + len(journal)
            result['persistent_payload_bytes'] = (
                result['bundle_bytes'] + result['peak_siblings_bytes'] + len(prepared) + len(publishing))
        if profile:
            rows = [line.split('\t', 2) for line in (f.root / 'operations').read_text().splitlines()]
            result['hash_launches'] = sum(command == 'openssl' for command, _, _ in rows)
            result['cmp_calls'] = sum(command == 'cmp' for command, _, _ in rows)
            result['proc_tr_calls'] = sum(command == 'tr' and arg == r'\000'
                                          for command, arg, _ in rows)
            result['copy_calls'] = sum(command == 'cp' for command, _, _ in rows)
            result['persistent_copy_calls'] = sum(command == 'cp' and '/jffs/' in dest
                                                 for command, _, dest in rows)
        return result
    finally:
        f.close()


def add_operation_counters(f):
    # Uninstrumented wall runs exercise the actual invocations. These wrappers
    # count tool launches separately, including hash batches and file copies.
    for name in ('openssl', 'cmp', 'tr', 'cp'):
        tool = f.fakebin / name
        target = tool.readlink()
        tool.unlink()
        invocation = f'{target} {name}' if target.name == 'busybox' else str(target)
        tool.write_text(f'''#!/bin/sh
for last do :; done
printf '%s\\t%s\\t%s\\n' '{name}' "${{1:-}}" "${{last:-}}" >>'{f.root / 'operations'}'
exec {invocation} "$@"
''')
        tool.chmod(0o755)


def scan_probe(engines):
    result = {}
    with tempfile.TemporaryDirectory(prefix='mervlan-scan.') as directory:
        root = Path(directory)
        for count in (64, 140):
            for i in range(10000, 10000 + count):
                entry = root / str(i)
                entry.mkdir(exist_ok=True)
                (entry / 'cmdline').write_bytes(b'/usr/sbin/fixture-service\0--foreground\0')
            for shell in (('/bin/sh',), ('busybox', 'ash')):
                key = f'{count}:{" ".join(shell)}'
                result[key] = {name: [] for name in engines}
                for trial in range(3):
                    for name in (engines if trial % 2 == 0 else reversed(engines)):
                        script = root / 'scan.sh'
                        script.write_bytes(engines[name].split(b'\ntrap cleanup 0\n', 1)[0] + b'''
MERV_REPAIR_PROC_ROOT=$1
for n in 1 2 3 4 5; do scan_processes || exit 1; done
''')
                        start = time.monotonic()
                        subprocess.run([*shell, script, root], check=True)
                        result[key][name].append((time.monotonic() - start) / 5)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--processes', type=int, default=140)
    parser.add_argument('--scanner-only', action='store_true')
    parser.add_argument('--case', choices=CASES)
    parser.add_argument('--original-r3', type=Path, help='also compare against preserved original R3 bytes')
    args = parser.parse_args()
    if args.runs < 1 or args.processes < 0:
        parser.error('use at least one run and a nonnegative process count')
    baseline = git('show', f'{REF}:{ENGINE_REL}')
    assert sha256(baseline).hexdigest() == R2_HASH
    engines = {'R2': baseline, 'R3': ENGINE.read_bytes()}
    if args.original_r3:
        original = args.original_r3.read_bytes()
        assert sha256(original).hexdigest() == R3_HASH
        engines = {'R2': baseline, 'R3': original, 'R3-R1': ENGINE.read_bytes()}
    result = {'engines': {k: sha256(v).hexdigest() for k, v in engines.items()},
              'processes': args.processes}
    if args.scanner_only:
        result['scanner_seconds_per_scan'] = scan_probe(engines)
    else:
        archive = git('archive', '--format=tar', f'--prefix=mervlan-{REF}/', REF)
        cases = CASES if not args.original_r3 else [case for case in CASES if case != 'full_damaged']
        for case in ((args.case,) if args.case else cases):
            runs = {name: [] for name in engines}
            for trial in range(args.runs):
                if args.original_r3:
                    names = list(engines)
                    start = trial % len(names)
                    order = names[start:] + names[:start]
                else:
                    order = engines if trial % 2 == 0 else reversed(engines)
                for name in order:
                    runs[name].append(run(engines[name], archive, name, case, args.processes))
            for name, samples in runs.items():
                result.setdefault(case, {})[name] = {
                    'runs': samples,
                    'median_seconds': statistics.median(row['total'] for row in samples),
                    'profile': run(engines[name], archive, name, case, args.processes, True),
                }
            print(f'Completed {case}', file=sys.stderr, flush=True)
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
