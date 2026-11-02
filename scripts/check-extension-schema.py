"""Validate exported host descriptors and wire-shape refusals (no runtime authority)."""
import copy
import json
from pathlib import Path
import sys

from jsonschema import Draft202012Validator

schema_path = Path(__file__).resolve().parents[1] / "docs/contracts/biz-kit-extension-v1.schema.json"
schema = json.loads(schema_path.read_text())
Draft202012Validator.check_schema(schema)
validator = Draft202012Validator(schema)
manifests = json.loads(Path(sys.argv[1]).read_text())
assert {m["id"] for m in manifests} == {"dispatch", "school_ops"}

checks = 0
for manifest in manifests:
    validator.validate(manifest)
    checks += 1
    invalid = [
        {**manifest, "extra": True},
        {k: v for k, v in manifest.items() if k != "health"},
        {**manifest, "contract_version": 2},
        {**manifest, "id": manifest["id"] + "\n"},
        {**manifest, "version": "1.0.0\n"},
        {**manifest, "capabilities": ["example.read\n"]},
        {**manifest, "capabilities": ["example.read", "example.read"]},
        {**manifest, "activation": "automatic"},
        {**manifest, "deployment": "unknown"},
        {**manifest, "health": "extension"},
        {**manifest, "dependencies": [{"id": "example", "min_version": "latest"}]},
        {**manifest, "commands": [{"name": "example.write", "writer": "example"}]},
    ]
    for candidate in invalid:
        assert not validator.is_valid(candidate), candidate
        checks += 1

    # Schema validates shape only. Ownership/grants/dependency graph checks are
    # deliberately enforced by Manifest/Catalog, not represented as permissions.
    foreign_writer = copy.deepcopy(manifest)
    foreign_writer["commands"] = [{
        "name": "foreign.write", "writer": "foreign", "required_grants": []
    }]
    validator.validate(foreign_writer)
    checks += 1

print(f"ExtensionV1 wire schema: {checks} checks passed; host policy remains required")
