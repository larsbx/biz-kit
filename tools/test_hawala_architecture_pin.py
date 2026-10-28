"""Negative controls for the cross-repository drift gate; no network needed."""
import copy
import json
import tempfile
import unittest
from pathlib import Path
from check_hawala_architecture_pin import ADR, COPIES, REQUIRED, check, gaps, normative, sha


class PairingGate(unittest.TestCase):
    def test_pin_rejects_text_source_and_identity_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'source'
            record = root / 'record.md'
            pin_path = root / 'pin.json'
            text = ('<!-- HAWALA_NORMATIVE_BEGIN -->\nN1 through N7\n'
                    '<!-- HAWALA_NORMATIVE_END -->\n'
                    '## Open gaps (must close before Accepted)\nG1 through G11\n'
                    '## Local context\n')
            record.write_text(text)
            for name in REQUIRED:
                p = source / name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text(text if name == ADR else f'fixture: {name}')
            pin = {'source_repository': 'larsbx/hawala-core', 'source_commit': 'a' * 40,
                   'files': {name: sha((source / name).read_bytes()) for name in REQUIRED},
                   'normative_sha256': sha(normative(text)), 'gaps_sha256': sha(gaps(text)), 'copies': COPIES}
            for src, dest in COPIES.items():
                target = root / dest
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes((source / src).read_bytes())
            pin_path.write_text(json.dumps(pin))
            check(pin_path, source, record, root)
            for before, after in [('N1 through N7', 'changed decision'),
                                  ('G1 through G11', 'unreviewed gap closure')]:
                record.write_text(text.replace(before, after))
                with self.assertRaises(ValueError):
                    check(pin_path, source, record, root)
                record.write_text(text)
            for src, dest in COPIES.items():
                target = root / dest
                target.write_bytes(target.read_bytes() + b'corrupt host expectation')
                with self.assertRaisesRegex(ValueError, 'host fixture drift'):
                    check(pin_path, source, record, root)
                target.write_bytes((source / src).read_bytes())
            canonical = source / 'formal/lean/CrossAuthority.lean'
            canonical.write_text('changed proof')
            with self.assertRaisesRegex(ValueError, 'source drift'):
                check(pin_path, source, record, root)
            bad = copy.deepcopy(pin)
            bad['source_commit'] = 'main'
            pin_path.write_text(json.dumps(bad))
            with self.assertRaisesRegex(ValueError, 'immutable'):
                check(pin_path, source, record, root)


if __name__ == '__main__':
    unittest.main()
