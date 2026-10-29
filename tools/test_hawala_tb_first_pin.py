"""Offline positive and drift controls for the independent TB-first source pin."""
import copy
import json
import tempfile
import unittest
from pathlib import Path
from check_hawala_tb_first_pin import REQUIRED, check, sha


class TigerBeetleFirstPin(unittest.TestCase):
    def test_exact_core_then_reject_source_identity_path_and_hash_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'source'
            pin_path = Path(directory) / 'pin.json'
            for name in REQUIRED:
                path = source / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(f'canonical fixture {name}')
            pin = {
                'profile': 'hawala-tigerbeetle-first/v1',
                'source_repository': 'larsbx/hawala-core',
                'source_commit': 'a' * 40,
                'files': {name: sha((source / name).read_bytes()) for name in REQUIRED},
            }
            pin_path.write_text(json.dumps(pin))
            self.assertEqual(check(pin_path, source), pin)
            for name in sorted(REQUIRED):
                path = source / name
                original = path.read_bytes()
                path.write_bytes(original + b'changed')
                with self.assertRaisesRegex(ValueError, 'source drift'):
                    check(pin_path, source)
                path.write_bytes(original)
            mutations = [
                ('source_commit', 'main'),
                ('source_repository', 'other/hawala-core'),
                ('profile', 'postgres-first'),
            ]
            for key, value in mutations:
                changed = copy.deepcopy(pin)
                changed[key] = value
                pin_path.write_text(json.dumps(changed))
                with self.assertRaisesRegex(ValueError, 'identity'):
                    check(pin_path, source)
            changed = copy.deepcopy(pin)
            del changed['files']['crates/hawala-tigerbeetle-flow/src/lib.rs']
            pin_path.write_text(json.dumps(changed))
            with self.assertRaisesRegex(ValueError, 'missing'):
                check(pin_path, source)
            for path in ['../outside', '/absolute', 'a/../outside', 'a\\outside']:
                changed = copy.deepcopy(pin)
                changed['files'][path] = '0' * 64
                pin_path.write_text(json.dumps(changed))
                with self.assertRaisesRegex(ValueError, 'unsafe'):
                    check(pin_path, source)


if __name__ == '__main__':
    unittest.main()
