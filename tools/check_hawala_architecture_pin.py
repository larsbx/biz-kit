"""Fail closed on Hawala normative drift; verify a reviewed immutable source pin.

No financial logic or authority is imported. --source is an offline checkout
alternative to fetching the exact pinned public commit. No default-branch reads.
"""
import argparse
import hashlib
import json
import re
from pathlib import Path, PurePosixPath
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
RECORD = ROOT / 'docs/architecture/2026-10-28-federated-hawala-native-capability.md'
PIN = ROOT / 'docs/architecture/fixtures/hawala-cross-authority-v1-pin.json'
ADR = 'docs/decisions/0005-biz-kit-federated-hawala-integration.md'
REQUIRED = {
    ADR, 'docs/CROSS_AUTHORITY_V1.md', 'formal/lean/CrossAuthority.lean',
    'formal/lean/FinancialEvidence.lean', 'formal/lean/ExportCrossAuthority.lean',
    'formal/quint/crossAuthority.qnt', 'formal/quint/crossAuthorityConformance.qnt',
    'formal/traces/crossAuthority.json', 'formal/traces/crossAuthority-negative.json',
    'formal/evidence/cross-authority-v1.json', 'formal/evidence/cross-authority.mjs',
    'tools/check_cross_authority.sh', 'tools/check_cross_authority_evidence.mjs',
    'tools/check_cross_authority_counterexamples.py',
    'formal/lean/ExportFinancialGates.lean', 'formal/traces/crossAuthority.tsv',
    'formal/traces/financialGates.tsv', 'docs/CROSS_AUTHORITY_HOST_CONFORMANCE.md',
    'crates/hawala-cross-authority-test/Cargo.toml',
    'crates/hawala-cross-authority-test/src/lib.rs',
    'crates/hawala-cross-authority-test/tests/host.rs',
    'crates/hawala-cross-authority-test/src/endpoints.rs',
    'crates/hawala-cross-authority-test/src/bin/service.rs',
    'crates/hawala-cross-authority-test/tests/endpoints.rs',
    'formal/lean/EndpointOrchestration.lean', 'formal/lean/ExportEndpointOrchestration.lean',
    'formal/quint/endpointOrchestration.qnt', 'formal/quint/endpointOrchestrationConformance.qnt',
    'formal/traces/endpointOrchestration.tsv', 'formal/traces/endpoint-negative.json',
    'formal/evidence/testEndpoints.tsv', 'tools/check_test_endpoint_vectors.mjs',
    'tools/check_endpoint_orchestration.sh', 'tools/check_endpoint_counterexamples.py',
    'docs/TEST_ENDPOINT_ORCHESTRATION.md',
}

COPIES = {
    'formal/evidence/testEndpoints.tsv': 'apps/hawala_capability/test/fixtures/testEndpoints.tsv',
    'formal/traces/crossAuthority.tsv': 'apps/hawala_capability/test/fixtures/crossAuthority.tsv',
    'formal/traces/financialGates.tsv': 'apps/hawala_capability/test/fixtures/financialGates.tsv',
}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def normative(text):
    begin, end = '<!-- HAWALA_NORMATIVE_BEGIN -->', '<!-- HAWALA_NORMATIVE_END -->'
    if text.count(begin) != 1 or text.count(end) != 1:
        raise ValueError('exactly one normative block required')
    return text.split(begin)[1].split(end)[0].strip().encode()


def gaps(text):
    heading = '## Open gaps (must close before Accepted)'
    if text.count(heading) != 1:
        raise ValueError('exactly one gaps section required')
    return text.split(heading)[1].split('\n## ')[0].strip().encode()


def check(pin_path=PIN, source=None, record_path=RECORD, copy_root=ROOT):
    pin = json.loads(Path(pin_path).read_text())
    if pin['source_repository'] != 'larsbx/hawala-core' or not re.fullmatch(r'[0-9a-f]{40}', pin['source_commit']):
        raise ValueError('invalid immutable source repository/commit')
    if not REQUIRED <= pin['files'].keys():
        raise ValueError('missing canonical proof/profile pins')
    if pin.get('copies') != COPIES:
        raise ValueError('exact canonical host fixture copies required')
    fetched = {}
    for name, expected in pin['files'].items():
        path = PurePosixPath(name)
        if path.is_absolute() or '..' in path.parts or not re.fullmatch(r'[0-9a-f]{64}', expected):
            raise ValueError('unsafe source path or invalid digest')
        if source is not None:
            data = (Path(source) / name).read_bytes()
        else:
            url = f"https://raw.githubusercontent.com/larsbx/hawala-core/{pin['source_commit']}/{name}"
            with urlopen(url, timeout=30) as response:
                data = response.read(2_000_001)
        if len(data) > 2_000_000 or sha(data) != expected:
            raise ValueError(f'canonical source drift: {name}')
        fetched[name] = data
    for canonical_path, local_path in COPIES.items():
        if (Path(copy_root) / local_path).read_bytes() != fetched[canonical_path]:
            raise ValueError(f'host fixture drift: {local_path}')
    canonical = fetched[ADR].decode()
    local = Path(record_path).read_text()
    if normative(local) != normative(canonical) or sha(normative(local)) != pin['normative_sha256']:
        raise ValueError('paired N1–N7 differ from pinned Hawala source')
    if gaps(local) != gaps(canonical) or sha(gaps(local)) != pin['gaps_sha256']:
        raise ValueError('paired G1–G11 differ from pinned Hawala source')
    return pin


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, help='offline hawala-core source checkout')
    args = parser.parse_args()
    result = check(source=args.source)
    print(f"PASS: N1–N7, G1–G11 and {len(result['files'])} canonical files at "
          f"hawala-core@{result['source_commit']}")
