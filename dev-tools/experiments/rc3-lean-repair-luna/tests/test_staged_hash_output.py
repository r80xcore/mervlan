#!/usr/bin/env python3
"""Isolated Dash tests for exact staged SHA-256 backend output."""
import argparse
from hashlib import sha256
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

from test_standalone_persistent_repair import (
    ENGINE, FILES, Fixture, install_correct_cohort, installed_inodes, ok, refused,
)

CASES = (
    'extra-valid', 'extra-invalid', 'extra-empty-line', 'trailing-newline',
    'unterminated-trailing-record', 'trailing-nul', 'trailing-binary',
    'missing-final', 'truncated-final', 'duplicate', 'reordered',
    'wrong-path', 'nonhex', 'nonzero', 'embedded-nul',
)
R3_R1_HASH = '94008a3215dd6c94bb2d539b9c0bfa931f7ef4c0b86fcc781cdee60cc255ce10'


def malformed_output(data, case):
    records = data.splitlines(keepends=True)
    suffixes = {
        'extra-valid': records[0],
        'extra-invalid': b'unexpected staged hash output\n',
        'extra-empty-line': b'\n\n',
        'trailing-newline': b'\n',
        'unterminated-trailing-record': records[0][:-1],
        'trailing-nul': b'\x00',
        'trailing-binary': b'\xff\x00\x80\x01',
    }
    if case in suffixes:
        return data + suffixes[case]
    edits = {
        'missing-final': b''.join(records[:-1]),
        'truncated-final': b''.join(records[:-1]) + records[-1][:33],
        'duplicate': records[0] + records[0] + b''.join(records[2:]),
        'reordered': records[1] + records[0] + b''.join(records[2:]),
        'wrong-path': records[0][:66] + b'/unexpected/stage/path\n' + b''.join(records[1:]),
        'nonhex': b'z' + data[1:],
        'embedded-nul': data[:8] + b'\x00' + data[8:],
        'nonzero': data,
        'valid': data,
    }
    return edits[case]


def hash_wrapper(args):
    tool, backend, case, directory, *argv = args
    capture = Path(directory)
    if backend == 'individual' and '-r' in argv:
        (capture / 'probe-refused').touch()
        return 65
    result = subprocess.run([tool, *argv], stdout=subprocess.PIPE)
    paths = argv[3:] if backend == 'openssl' else argv
    if backend == 'individual' and len(argv) == 3:
        with (capture / 'individual-paths').open('ab') as out:
            out.write(os.fsencode(argv[-1]) + b'\n')
    elif len(paths) == len(FILES):
        genuine = result.stdout
        emitted = malformed_output(genuine, case)
        (capture / 'genuine').write_bytes(genuine)
        (capture / 'emitted').write_bytes(emitted)
        (capture / 'stage').write_text(str(Path(paths[0]).parent))
        sys.stdout.buffer.write(emitted)
        return 67 if case == 'nonzero' else result.returncode
    sys.stdout.buffer.write(result.stdout)
    return result.returncode


def exercise(engine, backend, case, capture_dir, historical=False):
    f = Fixture()
    try:
        f.make_archive(engine.read_bytes())
        install_correct_cohort(f)
        before = installed_inodes(f)
        names = ['awk', 'cat', 'chmod', 'cmp', 'cp', 'date', 'df', 'grep', 'gzip',
                 'head', 'ls', 'mkdir', 'mv', 'readlink', 'rm', 'rmdir', 'sed',
                 'sh', 'tar', 'tr', 'wc']
        for name in names:
            (f.fakebin / name).symlink_to(shutil.which(name))
        name = 'sha256sum' if backend == 'sha256sum' else 'openssl'
        args = [sys.executable, str(Path(__file__).resolve()), '--hash-wrapper',
                shutil.which(name), backend, case, str(capture_dir.resolve())]
        wrapper = f.fakebin / name
        wrapper.write_text('#!/bin/sh\nexec ' + shlex.join(args) + ' "$@"\n')
        wrapper.chmod(0o755)
        if backend == 'individual':
            # Keep the actual staged output before successful no-op cleanup.
            cmp = f.fakebin / 'cmp'
            real_cmp = cmp.readlink()
            cmp.unlink()
            cmp.write_text(f'''#!/bin/sh
case "${{2:-}}:${{3:-}}" in
  *.expected:*/stage.hashes) cp "$3" {shlex.quote(str(capture_dir.resolve() / 'emitted'))} || exit 2 ;;
esac
exec {shlex.quote(str(real_cmp))} "$@"
''')
            cmp.chmod(0o755)
        counter = f.root / 'sync.calls'
        result = f.run({'FULL': '0', 'PATH': str(f.fakebin),
                        'MERV_REPAIR_SYNC_COUNTER': str(counter)}, helper=engine)
        (capture_dir / 'repair.log').write_text(result.stderr)
        accepted = case == 'valid' or historical
        if accepted:
            ok(result)
            assert 'replaced=0 verified no-op' in result.stderr
        else:
            refused(result, 'installed target classification failed')
            assert ' SELECT ' not in result.stderr and ' SUCCESS ' not in result.stderr
        f.assert_original()
        f.assert_protected()
        assert installed_inodes(f) == before
        assert not f.backups.exists() and not counter.exists()
        if backend == 'individual':
            assert (capture_dir / 'probe-refused').exists()
            paths = (capture_dir / 'individual-paths').read_bytes().splitlines()
            assert len(paths) == 58
            assert paths == [os.fsencode(Path(os.fsdecode(paths[0])).parent / rel) for _, rel in FILES]
            expected = b''.join(sha256(f.original[rel][0]).hexdigest().encode() + b'  ' +
                                path + b'\n' for (_, rel), path in zip(FILES, paths))
            assert (capture_dir / 'emitted').read_bytes() == expected
        else:
            stage = Path((capture_dir / 'stage').read_text())
            sep = b'  ' if backend == 'sha256sum' else b' *'
            genuine = b''.join(sha256(f.original[rel][0]).hexdigest().encode() + sep +
                               os.fsencode(stage / rel) + b'\n' for _, rel in FILES)
            assert (capture_dir / 'genuine').read_bytes() == genuine
            emitted = (capture_dir / 'emitted').read_bytes()
            assert emitted == malformed_output(genuine, case)
            if not accepted:
                # The engine retains its exact backend input on refusal.
                assert stage.parent.joinpath('stage.hashes').read_bytes() == emitted
        print(f'PASS {backend} {case} rc={result.returncode} '
              f'{"historical no-op reproduced" if historical else "accepted" if accepted else "refused"} '
              'capture checked; zero replacements, persistent writes and flushes', flush=True)
    finally:
        f.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capture-dir', type=Path, required=True)
    parser.add_argument('--historical', type=Path, help='preserved R3-R1 engine for the Luna control')
    args = parser.parse_args()
    if args.historical:
        assert sha256(args.historical.read_bytes()).hexdigest() == R3_R1_HASH
        matrix = [('sha256sum', 'extra-invalid')]
    else:
        matrix = [(backend, case) for backend in ('sha256sum', 'openssl')
                  for case in (*CASES, 'valid')] + [('individual', 'valid')]
    for backend, case in matrix:
        capture = args.capture_dir / backend / case
        capture.mkdir(parents=True, exist_ok=False)
        exercise(args.historical or ENGINE, backend, case, capture, bool(args.historical))


if __name__ == '__main__':
    if sys.argv[1:2] == ['--hash-wrapper']:
        raise SystemExit(hash_wrapper(sys.argv[2:]))
    main()
