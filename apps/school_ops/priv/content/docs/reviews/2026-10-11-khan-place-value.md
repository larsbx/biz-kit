# Khan Academy place-value resource review

- Review date: 2026-10-11
- Supporting review: [PR #5](https://github.com/larsbx/school-ops/pull/5)
- Preparation obligation: [issue #2](https://github.com/larsbx/school-ops/issues/2)
- Base reviewed: `9f7a8c124a3ba7290539224b53fb769f7403918c` (merged PR #4)
- Role approved by this content review: optional practice only
- Teaching results and classroom assignments: none recorded

## Evidence and method

Used the connected Khan Academy mathematics capability, with the user-selected
`2nd` grade limit and no standards filter. Reviewed all returned pages of seven
distinct sets: 25 pages, 112 items. Actual returned titles and general source URLs
are in the records below; separate opaque exercise IDs and curricular labels
were not reported. URL slugs identify source locations without claiming an
unreported provider ID. No provider question banks, hints, answers, or images
are stored. Grade/standards URL labels remain attribution, not progression rules.

Availability means that the connected provider returned interactive content and
an exercise link on the review date. Website loading, authenticated assignment,
and device/screen-reader behavior were not tested. These limits are recorded in
every resource. Review inspected prompt scope, notation, widget types, and
available image descriptions. Some charts have inconsistent Markdown delimiters
and some standalone images lack descriptive alternatives. A session requires a
delivery check; local concrete/chart practice is the fallback. Resource readiness
covers optional practice with the stated prerequisites, not a guarantee of
universal digital accessibility.

## Outcome and lesson mapping

Outcome IDs below use prefix `O-MATH-001-`; lessons use `L-MATH-001-01-`.
See the [outcome definitions](../../curriculum/mathematics/grade-2/README.md#course-outcomes)
and [prepared routes](../../curriculum/mathematics/grade-2/units/place-value/README.md#choose-the-teaching-route).

| Resource | Actual returned title | Outcomes | Specific lesson use | Route and scope decision |
| --- | --- | --- | --- | --- |
| [R-KHAN-001](../../resources/r-khan-001.md) | Place value blocks within 1,000 | 001, 003 | 02, 03 | Hundreds route |
| [R-KHAN-002](../../resources/r-khan-002.md) | Place value tables within 1,000 | 001, 003 | 02, 03 | Hundreds route |
| [R-KHAN-003](../../resources/r-khan-003.md) | Write numbers in number and expanded form | 003 | 03 | Hundreds route |
| [R-KHAN-004](../../resources/r-khan-004.md) | Compare 3-digit numbers | 004 | 05 | Hundreds route, with addition prerequisite |
| [R-KHAN-005](../../resources/r-khan-005.md) | Skip-count by 5s | 002 | 04 | Mixed ones/tens and hundreds; whole set requires hundreds |
| [R-KHAN-006](../../resources/r-khan-006.md) | Skip-count by 10s | 002 | 04 | Mixed ones/tens and hundreds; whole set requires hundreds |
| [R-KHAN-007](../../resources/r-khan-007.md) | Hundreds, tens, and ones | 001 | 02 | Hundreds route, regrouping follow-up |

- **001 / grouped units:** R-KHAN-001/002 reinforce model/chart recognition
  after lesson 2; R-KHAN-007 supplies regrouping equivalences after concrete
  exchanges. They do not replace lesson 1's ones/tens exchange or a preservation reason.
- **003 / notation:** R-KHAN-003 practices standard/expanded forms after lesson 3;
  R-KHAN-001/002 connect models/charts to numerals. No number-name exercise was
  verified; retain spoken names and teach-back in lesson 3.
- **002 / equal steps:** R-KHAN-005 and 006 support lesson 4's fives/tens work.
  Neither establishes counting by ones or hundreds, or all boundary explanations.
- **004 / comparisons:** R-KHAN-004 supports lesson 5 after numeral/expanded
  expression reading and relevant addition. Keep the first-differing-place reason
  and aloud statement in the local lesson.

## Route boundaries and unresolved retrievals

| Route | Reviewed assignment decision | Remaining work |
| --- | --- | --- |
| Ones/tens (PV2 scope) | No whole returned exercise is verified as a two-digit-only assignment. Some small-number items occur inside larger-range sets; do not assign a whole set on that basis. | Keep lesson 1 and two-digit routes in lessons 3–5. Retrieve a genuinely bounded set or verify provider item/range selection before adding one. |
| Ones/tens/hundreds (PV3 scope) | Seven optional practice resources reviewed; use only after their stated prerequisites. | Teacher models, numeral names, count-by-ones/hundreds, and reasons remain local work. |
| Optional thousand (PVX scope) | No selected set was verified for the exact ten-hundreds exchange and 999-to-1,000 boundary. "Within 1,000" in a title is not proof of that coverage. | Retain lesson 3/4 extension and separate PVX; no extra four-digit requirements. |

Retrieval log beyond the seven selected sets:

- Broad "place value" with grade `2nd` returned "Place value blocks" at a
  fourth-grade URL with values above 1,000. Rejected for the prepared unit;
  a requested grade limit is not a verified content bound.
- "Compare 2-digit numbers" returned the same three-digit set, both with and
  without the grade limit. It was not registered as a second resource.
- "Compare two-digit numbers within 100" and "Number names within 100" with
  grade `2nd` returned no exercises. This is a retrieval limitation, not proof
  that Khan Academy lacks such catalogue exercises.
- "Tens and ones" returned "Hundreds, tens, and ones"; registered only for
  later regrouping after lesson 2.
- "Skip-count by 5s and 10s" returned fives only; tens was retrieved separately.

## Readiness and assessment separation

The seven resource records have checked provider locators, actual metadata,
dated scope/access/suitability reviews, explicit practice-only roles, intended
audiences and prerequisites, attribution, reference-only rights decisions, and
PR #5 as supporting review. They are registered `ready` for that bounded role
under [resource readiness](../curriculum-model.md#resource-readiness).
Unknown optional metadata is explicitly not reported.

Course, unit, lesson, and assessment records remain draft. No resource is
registered for assessment: the existing A-MATH-001-02 design is draft, so it
cannot satisfy the ready-assessment dependency. Provider correctness/hints can
guide supported practice, not independent outcome certification. Retain
PV2/PV3/PVX teacher-key separation and fresh local evidence conditions; any future
provider assessment role needs its own ready design and reviewed tasks/conditions.
Resource readiness neither authorizes a teaching schedule nor establishes learner mastery.

## Assignments, timed drills, and local tests

The connected capability supplies interactive questions, hints/correctness
structures, pagination, and a general assignable exercise URL. It returned no
classroom roster, due-date settings, progress-import feed, configurable timer,
download/export function, question generator, range restriction, or API for
constructing arbitrary tests. A general link is not evidence an assignment was
created. Do not publish class-specific links.

Locally generated timed drills or tests are a separate authoring obligation.
Before creating them, specify the taught range, relationship and item types,
original generation rules, verified answer keys, form/version or seed,
administration and permitted support, and outcome-specific evidence criteria.
If timing is desired, decide the time limit and how speed evidence is separated
from understanding; the current place-value assessment has no speed threshold.
No timing requirement or timer implementation is introduced here. Use original
school-ops items; do not scrape or republish Khan Academy's bank.

## Validation

Checked mapping against current course outcomes and lesson prerequisites, resource
readiness fields and statuses, stable IDs, actual returned titles/URLs, selected
pagination totals, registration and relative links. No teaching or assessment
record is promoted, no standards alignment is introduced, and no learner or
class-specific data is included. Documentation changes require no new test suite.
