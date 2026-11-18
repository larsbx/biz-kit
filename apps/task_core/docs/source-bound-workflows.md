# Source-bound workflow readiness

Schema-2 blueprints may give a workflow an optional `readiness_contract`.
The original schema-2 behavior is preserved when the field is absent.
Its complete version-1 shape is:

```json
{
  "schema_version": 1,
  "sop_digest": "<64 lowercase hexadecimal SHA-256 characters>",
  "sop_version": "1.0.0",
  "input_digests": {
    "source_24_12": "<64 lowercase hexadecimal SHA-256 characters>",
    "source_24_12d": "<64 lowercase hexadecimal SHA-256 characters>"
  },
  "manifest_input": "workflow_manifest"
}
```

The placeholders above are explanatory, not a valid runnable blueprint.
There must be 1–31 source inputs, with the same lowercase identifier alphabet
as blueprint task keys. `workflow_manifest` is reserved. Every task in that
workflow must require exactly the source input names and `workflow_manifest`.
The SOP version uses the existing bounded numeric `MAJOR.MINOR.PATCH` rule;
prerelease/build suffixes and leading zeros are not accepted. Missing and
unknown fields, malformed digests and input collisions refuse normalization.

`TaskBlueprintAppliedV1` still carries the normalized blueprint and the digest
of its exact retained bytes. Folding adoption resolves `workflow_manifest`
to that digest. Folding a run retains the bound contract on each task.
Ordinary `TaskReadinessDefinedV1` admission requires the exact SOP digest,
version and full input-digest map. A generic client cannot bypass this by
changing digests while preserving input names. Existing predecessor checks
remain in force.

The SOP bundle should contain the chosen source documents and provenance, but
not the blueprint's digest. This avoids a hash cycle: adoption supplies the
manifest identity, while the manifest independently pins its SOP and sources.
Later blueprint adoption governs future runs; it cannot replace the bindings
of an existing run. Both adoption bindings and task bindings replay from
accepted events without rereading source files.

Readiness definitions bind identities. Existing custody receipts, current
operator grants, device-specific SOP acknowledgement, predecessor completion,
evidence review and lifecycle admission still determine whether work can
advance. Input availability and digest integrity are checked at readiness and
start. The contract creates no external execution authority or adapter.

Source repository authenticity, byte retention, event signatures and
serialization are host obligations. A binding does not prove the contents of
a document are true or that a paper signature is authentic. The existing
governance path may still revise a task's Definition of Done; this contract
freezes the source/SOP inputs for the run, not every later governance decision.

Verification is in `test/readiness_contract_test.exs`: strict normalization,
ordinary-admission substitution refusals, exact adopted-manifest binding,
later-revision isolation, replay without source reads, custody/acknowledgement
and predecessor gates, and unchanged behavior without the optional contract.
These pure tests assume the host has verified event signatures; signed-ledger
acceptance belongs in the host's integration suite.
