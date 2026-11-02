#!/usr/bin/env python3
"""Check a pinned, test-only Halaqa format oracle and its exact-byte corpus.

No network calls, production imports or Halaqa admission. The signed experiment
checks Ed25519 against explicit TEST pins, never production identity or authority.
The reviewed pin is source selection; hashes do not prove owner adoption.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import sys
import types

SOURCE_PATHS = {
    "halaqa_federation_draft.py": "scripts/halaqa_federation_draft.py",
    "vectors.json": ".polyglot/halaqa-federation-draft-0/vectors.json",
    "halaqa_federation_signed_draft.py": "scripts/halaqa_federation_signed_draft.py",
    "signed-vectors.json": ".polyglot/halaqa-federation-signed-draft-2/vectors.json",
}


def _unique(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate pin field")
        value[key] = item
    return value


def load_snapshot(root: Path):
    """Load captured hash-verified modules for offline fixture consumers only."""
    directory = root / "tools/halaqa_federation_draft"
    pin = json.loads((directory / "source-pin.json").read_text(), object_pairs_hook=_unique)
    if type(pin) is not dict or set(pin) != {
        "schema", "repository", "revision", "source_review", "scope", "files",
    }:
        raise ValueError("invalid source pin fields")
    if (pin["schema"] != "bizkit-halaqa-federation-draft-pin/1"
            or pin["repository"] != "larsbx/halaqa"
            or pin["scope"] != "offline-format-and-signed-test-only"
            or type(pin["revision"]) is not str
            or re.fullmatch(r"[0-9a-f]{40}", pin["revision"]) is None
            or pin["source_review"] != "https://github.com/larsbx/halaqa/pull/9"
            or type(pin["files"]) is not dict
            or set(pin["files"]) != set(SOURCE_PATHS)):
        raise ValueError("invalid source pin")
    # Fixed local/source paths: no paths from pin data are followed.
    verified = {}
    for local, upstream in SOURCE_PATHS.items():
        entry = pin["files"][local]
        if (type(entry) is not dict
                or set(entry) != {"source_path", "sha256", "git_blob_sha"}
                or entry["source_path"] != upstream):
            raise ValueError("invalid source file entry")
        data = (directory / local).read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        blob = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
        if digest != entry["sha256"] or blob != entry["git_blob_sha"]:
            raise ValueError(f"pinned source mismatch: {local}")
        verified[local] = data
    # Execute the captured verified bytes, never an unpinned .pyc or second read.
    module = types.ModuleType("pinned_halaqa_federation_draft")
    exec(compile(verified["halaqa_federation_draft.py"],
                 str(directory / "halaqa_federation_draft.py"), "exec"), module.__dict__)
    previous = sys.modules.get("halaqa_federation_draft")
    sys.modules["halaqa_federation_draft"] = module
    try:
        signed = types.ModuleType("pinned_halaqa_federation_signed_draft")
        exec(compile(verified["halaqa_federation_signed_draft.py"],
                     str(directory / "halaqa_federation_signed_draft.py"), "exec"),
             signed.__dict__)
    finally:
        if previous is None:
            sys.modules.pop("halaqa_federation_draft", None)
        else:
            sys.modules["halaqa_federation_draft"] = previous
    return pin, directory, module, signed


def check(root: Path):
    pin, directory, module, signed = load_snapshot(root)
    result = module.check_corpus(directory / "vectors.json")
    signed_result = signed.check_corpus(directory / "signed-vectors.json")
    return {**result, "signed_experiment": signed_result,
            "source_revision": pin["revision"], "production_receiver": False}


if __name__ == "__main__":
    print(json.dumps(check(Path(__file__).resolve().parents[1]), sort_keys=True))
