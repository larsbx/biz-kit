"""Synthetic model checks and implementation trace replay; never imports pilot data."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent


def run(args):
    subprocess.run(args, cwd=HERE, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--quint', default='quint')
    parser.add_argument('--verify', action='store_true', help='also require Apalache bounded verification through 8 steps')
    args = parser.parse_args()
    quint = os.path.abspath(args.quint) if '/' in args.quint else args.quint
    version = subprocess.check_output([quint, '--version'], text=True).strip()
    if version != '0.32.0':
        raise RuntimeError('use pinned Quint 0.32.0')
    spec = 'merchant_pilot.qnt'
    run([quint, 'typecheck', spec])
    run([quint, 'test', spec, '--backend=typescript'])  # Includes five deliberate mutation witnesses.
    run([quint, 'run', spec, '--backend=typescript', '--invariant=safety',
         '--max-samples=3000', '--max-steps=25', '--seed=1', '--verbosity=1'])
    with tempfile.TemporaryDirectory(prefix='merchant-quint-') as directory:
        root = Path(directory)
        run([quint, 'test', spec, '--backend=typescript', '--match=^(?!mutation).*Test$',
             '--out-itf=' + str(root / 'test-{test}-{seq}.itf.json')])
        run([quint, 'run', spec, '--backend=typescript', '--invariant=safety',
             '--max-samples=100', '--max-steps=25', '--seed=2', '--n-traces=100',
             '--out-itf=' + str(root / 'trace-{seq}.itf.json'), '--verbosity=1'])
        traces = sorted(root.glob('*.itf.json'))
        if len(traces) != 112:
            raise RuntimeError('expected 100 simulator traces and twelve scenario traces')
        run([sys.executable, str(HERE / 'replay_quint.py'), *map(str, traces)])
    if args.verify:
        run([quint, 'verify', spec, '--invariant=safety', '--max-steps=8'])
    else:
        print('Apalache bounded verification NOT requested; simulation is not exhaustive verification.')


if __name__ == '__main__':
    main()
