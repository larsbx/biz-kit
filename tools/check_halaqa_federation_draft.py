#!/usr/bin/env python3
"""Check a pinned, test-only Halaqa format oracle and its exact-byte corpus.

No network calls, production imports, Halaqa admission or signature verification.
The reviewed pin is the source selection; hashes do not prove owner adoption.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import re

SOURCE_PATHS = {
    "halaqa_federation_draft.py": "scripts/halaqa_federation_draft.py",
    "vectors.json": ".polyglot/halaqa-federation-draft-0/vectors.json",
}


def _unique(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate pin field")
        value[key] = item
    return value


def check(root: Path):
    directory = root / "tools/halaqa_federation_draft"
    pin = json.loads((directory / "source-pin.json").read_text(), object_pairs_hook=_unique)
    if type(pin) is not dict or set(pin) != {
        "schema", "repository", "revision", "source_review", "scope", "files",
    }:
        raise ValueError("invalid source pin fields")
    if (pin["schema"] != "bizkit-halaqa-federation-draft-pin/1"
            or pin["repository"] != "larsbx/halaqa"
            or pin["scope"] != "offline-format-only"
            or type(pin["revision"]) is not str
            or re.fullmatch(r"[0-9a-f]{40}", pin["revision"]) is None
            or pin["source_review"] != "https://github.com/larsbx/halaqa/pull/9"
            or type(pin["files"]) is not dict
            or set(pin["files"]) != set(SOURCE_PATHS)):
        raise ValueError("invalid source pin")
    # Fixed local/source paths: no paths from pin data are followed.
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
    spec = importlib.util.spec_from_file_location(
        "pinned_halaqa_federation_draft", directory / "halaqa_federation_draft.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    result = module.check_corpus(directory / "vectors.json")
    return {**result, "source_revision": pin["revision"], "production_receiver": False}


if __name__ == "__main__":
    print(json.dumps(check(Path(__file__).resolve().parents[1]), sort_keys=True))
