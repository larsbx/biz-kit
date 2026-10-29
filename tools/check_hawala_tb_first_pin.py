"""Verify the immutable Hawala-owned TB-first profile/core, not runtime conformance."""
import argparse
import hashlib
import json
import re
from pathlib import Path, PurePosixPath
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
PIN = ROOT / 'docs/architecture/fixtures/hawala-tigerbeetle-first-pin.json'
REQUIRED = {
    'docs/NODE_BOOKS_TIGERBEETLE_SPEC.md',
    'docs/NODE_BOOKS_POSTGRES_FIRST_ARCHIVED.md',
    'crates/hawala-tigerbeetle-flow/Cargo.toml',
    'crates/hawala-tigerbeetle-flow/README.md',
    'crates/hawala-tigerbeetle-flow/src/lib.rs',
    'crates/hawala-tigerbeetle-flow/tests/flow.rs',
    'Cargo.toml', 'Cargo.lock', '.github/workflows/rust.yml',
    'tools/check_tb_first_mutations.py',
    'crates/hawala-tigerbeetle-flow/src/replay.rs',
    'crates/hawala-tigerbeetle-flow/tests/replay.rs',
    'formal/README.md',
    'formal/lean/TigerBeetleFirst.lean',
    'formal/lean/ExportTigerBeetleFirst.lean',
    'formal/lean/lakefile.toml', 'formal/lean/lean-toolchain',
    'formal/quint/tigerBeetleFirst.qnt',
    'formal/quint/tigerBeetleFirstConformance.qnt',
    'formal/traces/tigerBeetleFirst.tsv',
    'formal/package.json', 'formal/package-lock.json',
    'tools/generate_tb_first_certificate.py',
    'tools/check_tb_first_quint.sh', 'tools/check_trace_artifacts.sh',
    '.github/workflows/formal.yml',
    '.github/workflows/tigerbeetle-native.yml',
    'formal/lean/TigerBeetleStorage.lean',
    'formal/quint/tigerBeetleStorage.qnt',
    'tools/check_tb_storage_mutations.py',
    'tools/check_tb_storage_quint.sh',
    'crates/hawala-tigerbeetle-native/Cargo.toml',
    'crates/hawala-tigerbeetle-native/README.md',
    'crates/hawala-tigerbeetle-native/src/accounting.rs',
    'crates/hawala-tigerbeetle-native/src/durable.rs',
    'crates/hawala-tigerbeetle-native/src/evidence.rs',
    'crates/hawala-tigerbeetle-native/src/lib.rs',
    'crates/hawala-tigerbeetle-native/src/native.rs',
    'crates/hawala-tigerbeetle-native/tests/durable.rs',
    'crates/hawala-tigerbeetle-native/tests/fixtures/README.md',
    'crates/hawala-tigerbeetle-native/tests/fixtures/node-books-50-first-pairs.tsv',
    'crates/hawala-tigerbeetle-native/tests/fixtures/node-books-50-registry.bin',
    'crates/hawala-tigerbeetle-native/tests/native.rs',
    'crates/hawala-tigerbeetle-native/tests/support/mod.rs',
}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def check(pin_path=PIN, source=None):
    pin = json.loads(Path(pin_path).read_text())
    if (pin.get('profile') != 'hawala-tigerbeetle-first/v1'
            or pin.get('source_repository') != 'larsbx/hawala-core'
            or not re.fullmatch(r'[0-9a-f]{40}', pin.get('source_commit', ''))):
        raise ValueError('immutable TB-first profile identity required')
    if not isinstance(pin.get('files'), dict) or not REQUIRED <= pin['files'].keys():
        raise ValueError('missing TB-first source/core pins')
    for name, expected in pin['files'].items():
        path = PurePosixPath(name)
        if (path.is_absolute() or '..' in path.parts or '\\' in name
                or str(path) != name or not re.fullmatch(r'[0-9a-f]{64}', expected)):
            raise ValueError('unsafe source path or invalid digest')
        if source is not None:
            data = (Path(source) / name).read_bytes()
        else:
            url = ('https://raw.githubusercontent.com/larsbx/hawala-core/'
                   f"{pin['source_commit']}/{name}")
            with urlopen(url, timeout=30) as response:
                data = response.read(2_000_001)
        if len(data) > 2_000_000 or sha(data) != expected:
            raise ValueError(f'TB-first source drift: {name}')
    return pin


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, help='offline hawala-core checkout')
    args = parser.parse_args()
    result = check(source=args.source)
    print(f"PASS: {len(result['files'])} TB-first source/core pins at "
          f"hawala-core@{result['source_commit']}; native adapter acceptance is separate")
