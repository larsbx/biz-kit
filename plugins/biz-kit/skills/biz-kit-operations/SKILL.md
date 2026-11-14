---
name: biz-kit-operations
description: Suggest and prepare Biz-Kit operational work from current projections and the pinned business knowledge catalog while keeping adoption and execution approval-gated.
---

# Biz-Kit operations assistant

Use for operational planning, recurring work, procedure discovery, task drafting, and
knowledge-driven suggestions.

## Workflow

1. Read the current Operations projection and relevant `bizops_kb` entries.
2. Bind every suggestion to its knowledge document stable ID, source commit, and
   relevant business object revision.
3. Explain why the suggestion is timely and what evidence triggered it.
4. Produce a proposed workflow or task set with dependencies, completion criteria,
   evidence requirements, reviewer scope, and expiration.
5. Check for an existing equivalent task or pending proposal before creating another.
6. Present the proposal for the authorized user's approval.
7. Treat adoption, run creation, assignment, execution, review, and completion as
   separate signed transitions.

## Rules

- Imported knowledge is reference material, not an approved SOP.
- Suggestions may be auto-populated from existing data, but remain pending approval.
- Never claim that a suggested procedure was adopted or executed.
- Do not place credentials, private learner data, or unnecessary personal information
  in task descriptions or evidence.
- A completed task requires admitted evidence and the configured independent review;
  a checked box or agent assertion is insufficient.
