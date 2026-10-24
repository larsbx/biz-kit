# Resource register

Register materials once they are ready for their declared roles; consuming lessons
may be authored later. A resource may be a book, article, video, activity, exercise
set, or other teaching aid. Its record identifies the source, intended use, review,
and relevant outcomes.

| Resource ID | Provider or author | Title | Status | Resource record |
| --- | --- | --- | --- | --- |

| R-KHAN-001 | Khan Academy | Place value blocks within 1,000 | ready — optional practice | [Record](r-khan-001.md) |
| R-KHAN-002 | Khan Academy | Place value tables within 1,000 | ready — optional practice | [Record](r-khan-002.md) |
| R-KHAN-003 | Khan Academy | Write numbers in number and expanded form | ready — optional practice | [Record](r-khan-003.md) |
| R-KHAN-004 | Khan Academy | Compare 3-digit numbers | ready — optional practice | [Record](r-khan-004.md) |
| R-KHAN-005 | Khan Academy | Skip-count by 5s | ready — optional practice | [Record](r-khan-005.md) |
| R-KHAN-006 | Khan Academy | Skip-count by 10s | ready — optional practice | [Record](r-khan-006.md) |
| R-KHAN-007 | Khan Academy | Hundreds, tens, and ones | ready — optional practice | [Record](r-khan-007.md) |

The [second-grade mathematics search queue](second-grade-math-searches.md) lists
Khan Academy retrieval and review status for the first course. Seven resources
are reviewed for optional practice after hundreds; two-digit-only and thousand
coverage gaps remain. See the [dated route review](../docs/reviews/2026-10-11-khan-place-value.md).

## Review and register a resource

1. Find material for a stated outcome. Use the
   [Khan Academy workflow](../docs/khan-academy.md) for its mathematics exercises.
2. Copy the [resource template](../templates/resource.md) to
   `resources/<resource-id>.md` and assign a stable resource ID.
3. Record the actual source, metadata, review date, starting skills, access needs,
   and outcome fit. Review its contribution to the chosen art and Trivium work;
   provider curricular labels are provenance rather than the curriculum structure.
4. Apply the [resource-specific readiness checks](../docs/curriculum-model.md#resource-readiness).
   Keep the record `draft` until those checks pass; record the review date and
   supporting pull request, then mark it `ready` and add it to this register.
   Link consuming lessons when they are authored.
5. If a resource changes or becomes unavailable, revise its record, update affected
   lessons, and retain the ID. Record a replacement when retiring it.

Resources used only for instruction or practice need a source, intended role/audience,
access, and suitability review. They do not need a lesson sequence or assessment
criteria. For any assessment use, including combined roles, link a ready assessment
design containing the tasks, conditions, and criteria. Review that design under
the assessment requirements.

A resource can be ready while a consuming lesson is still draft. Preserve existing
register entries when their status changes, and recheck resource readiness after
changes to the source, access, or intended use.

Use source links and attribution. Record reuse rights before storing copies of
external material. Public records hold general sources; class-specific assignment
links belong in private planning.
