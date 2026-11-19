"""Exact R3-R1/R3-R2 paired benchmark using the existing isolated fixtures."""
from hashlib import sha256
import json
from pathlib import Path
from statistics import median
import sys

from benchmark_r3_repair import REF, git, run
from test_standalone_persistent_repair import ENGINE

evidence = Path(__file__).resolve().parent
engines = {'R3-R1': (evidence / 'original-r3-r1.sh').read_bytes(),
           'R3-R2': ENGINE.read_bytes()}
identities = {key: sha256(payload).hexdigest() for key, payload in engines.items()}
assert identities['R3-R1'] == '94008a3215dd6c94bb2d539b9c0bfa931f7ef4c0b86fcc781cdee60cc255ce10'
processes = 16
data = {'engines': identities, 'processes': processes}
archive = git('archive', '--format=tar', f'--prefix=mervlan-{REF}/', REF)
repeat = sys.argv[1:] == ['--repeat-default']
cases = ('default_correct',) if repeat else (
    'selective_noop', 'selective_one', 'selective_ten', 'default_correct')
for case in cases:
    rows = {key: [] for key in engines}
    for trial in range(3):
        for name in (engines if (trial + repeat) % 2 == 0 else reversed(engines)):
            rows[name].append(run(engines[name], archive, name, case, processes))
    data[case] = {name: {'runs': samples,
                        'median_seconds': median(row['total'] for row in samples),
                        'profile': run(engines[name], archive, name, case, processes, True)}
                  for name, samples in rows.items()}
    print(f'Completed {case}', file=sys.stderr, flush=True)
print(json.dumps(data, indent=2))
