"""Re-pin the Hawala architecture source to an exact hawala-core checkout.

Run after any paired change to ADR 0005 N1–N7 or G1–G11, or to a pinned
canonical file, then review the diff and run check_hawala_architecture_pin.py.
Uses the checker's own extractors, so the two cannot disagree. Pins only the
files already listed; adding a canonical file stays a reviewed manual edit.
"""
import argparse
import json
import subprocess
from pathlib import Path

import check_hawala_architecture_pin as checker


def repin(source, source_pr, pin_path=checker.PIN):
    pin = json.loads(Path(pin_path).read_text())
    commit = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    adr = (Path(source) / checker.ADR).read_text()
    pin.update(
        source_commit=commit,
        source_pr=source_pr,
        files={name: checker.sha((Path(source) / name).read_bytes()) for name in pin['files']},
        normative_sha256=checker.sha(checker.normative(adr)),
        gaps_sha256=checker.sha(checker.gaps(adr)),
    )
    Path(pin_path).write_text(json.dumps(pin, indent=2, ensure_ascii=False) + '\n')
    return pin


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True, help='hawala-core checkout at the commit to pin')
    parser.add_argument('--source-pr', required=True, help='URL of the hawala-core PR that produced it')
    args = parser.parse_args()
    result = repin(args.source, args.source_pr)
    print(f"pinned hawala-core@{result['source_commit']}; now run check_hawala_architecture_pin.py")
