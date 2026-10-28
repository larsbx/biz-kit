# First-unit authoring review — 2026-10-09

- Reviewed base: [main aa8a273](https://github.com/larsbx/school-ops/commit/aa8a2734779a88d0ea9dd020e0e990479f599372)
- Course: [C-MATH-001](../../curriculum/mathematics/grade-2/README.md)
- Unit: [U-MATH-001-01](../../curriculum/mathematics/grade-2/units/place-value/README.md)
- Worklist: [issue #2](https://github.com/larsbx/school-ops/issues/2)
- Review scope: original school-ops lesson tasks, teacher keys, prerequisite relationships, and first-unit assessment coverage
- Corrective follow-up: [PR #4 repairs and scope check](#pr-4-corrective-follow-up) address findings on the initial contribution

## Findings and corrections

| Finding | Correction |
| --- | --- |
| The unit check repeated the lesson-4 five-term count from 95 by fives | Core assessment forms use different examples; a previously seen prompt still requires a fresh keyed replacement before independent assessment |
| Two-digit teaching was allowed, but teachers had to improvise the assessment adaptation | PV2 supplies twelve actual tasks, a teacher key, and scope-specific evidence criteria |
| The 1,000 item was required in the representation rubric despite being an optional lesson extension | PV3 has a complete three-digit core; PVX separately checks the taught thousand grouping, representation, and counting boundary |
| A rubric requested a place-value model without asking for it in the matching representation task | Item 07 explicitly asks for the model and its connection to written places in each core form |
| Tasks and answers appeared together in the administration table | Learner task sheets and teacher keys are separate linked files |
| Smaller-range variants of the lesson path were only described generally | The unit records a concrete two-digit route and lists the later extensions that remain pending |
| Live status still described the already merged foundation as awaiting review | The roadmap identifies the merged foundation/readiness work and keeps teaching preparation open |

## Mathematical and instructional review

The six lessons develop naming and notation, an invariant or reason, and a spoken
or modeled explanation. Their recorded arithmetic examples and teacher keys are
consistent: regrouping preserves the counted amount, expanded forms match the
numerals, counting terms include the stated start, and comparisons use the first
differing place. The new keys follow those same relationships.

PV2 covers the taught ones/tens portion of outcomes 001–004. PV3 adds the hundreds
portion; PVX is the separate thousand extension for outcomes 001–003. Neither a
two-digit result nor a three-digit result establishes an untaught extension.
Numerical scopes are authoring choices, not observed learner readiness.

The core forms each provide twelve learner tasks matched to twelve teacher-key
entries; the optional extension has two matched tasks and keys. Arithmetic checks
confirm nine regrouping equation chains, eight counting sequences, six comparisons,
and six representation-conversion groups. The three alternative lesson stage
budgets each sum to the authored 25-minute estimate. These checks verify the
materials; they do not establish actual learner performance or delivery time.

Relative links and anchors, stable identifiers, Markdown sections, and diff
whitespace were checked. The K–12 scope decisions, readiness rules, resource
register, and unreviewed provider queue are unchanged.

All tasks here are original school-ops material. No provider exercise has been
retrieved, reviewed, assigned, or registered in this contribution. The existing
[Khan Academy queue](../../resources/second-grade-math-searches.md) remains pending.

## Readiness and remaining preparation

This is an authoring review, not a teaching run or approval of a learner's pace.
The course, unit, lessons, assessments, and supporting task sheets remain `draft`.
The proposed local criteria and new forms still need their applicable readiness
review before classroom use. The later-unit evidence plan remains an authoring
backlog. No learner results are recorded or inferred.

Before delivery, complete entry work privately, choose the taught scope, review
the relevant material against its own readiness requirements, confirm materials
and selected practice, and agree on teaching time and dates for a weekly plan.
After-week observations are recorded only after actual teaching.

## PR #4 corrective follow-up

The review of [PR #4](https://github.com/larsbx/school-ops/pull/4) at
`a684960c74c0b083ade3aa1bda6abf46108a30e6` identified learner links to the complete
teacher guide and a thousand route with no corresponding learner activity.
This follow-up corrects those gaps; the original authoring review above does not
establish that its initial thousand instruction or digital learner separation was
complete.

PV2, PV3, and PVX now carry the same non-clickable assessment identifier. The
teacher guide retains its internal links to each learner form and teaching route.
No teacher guide is reachable through links on any of the three learner sheets.
Administration uses a standalone learner copy/export, since repository navigation
also contains teacher material. Previously seen answers or full prompts still
require a fresh keyed application before independent evidence is sought.

Lesson 3 now has an optional thousand activity with prerequisite checks, worked
examples, concrete packing/unpacking, value-preservation reasoning, four-position
notation and zero explanations, three independent practice tasks with keys, and
an exit check. Lesson 4 teaches all three exchanges after adding one to 999.
Lesson 1 now explicitly unpacks a ten; lesson 2 unpacks a hundred and then a ten,
matching the reverse-exchange demands of the core checks. PVX-01 explicitly asks
for its preservation reason, and its key supplies that reason.

The fresh review of `115e39b9ffc345b685d06eac83277d3fe9024b22` identified one
additional criterion gap: core outcome 001 named composition but counted only
items 01–03, whose explicit exchange is unpacking. Item 04 already asks for the
taught forward boundary exchanges. The corrected guide and course evidence link
now include item 04's composition in outcome 001, separately from its counting
evidence for outcome 002. The task and key IDs are unchanged.

### Task, route, and criterion alignment

Outcome numbers below abbreviate `O-MATH-001-NNN`. Each criterion applies only
to the selected form and taught scope; all parts of each task are checked.

| Assessment tasks | Advertised teaching source | Outcome and matching evidence/key |
| --- | --- | --- |
| PV2-01, PV2-03 | [Lesson 1](../../curriculum/mathematics/grade-2/units/place-value/lessons/01-tens-and-ones.md), lesson 3's two-digit route | 001: unit, tens/ones models, digit amounts, and zero ones |
| PV2-02 | Lesson 1's supported unbundling | 001: exchange a ten for ten ones; model and explain the preserved amount |
| PV2-04–06 | [Lesson 4's two-digit route](../../curriculum/mathematics/grade-2/units/place-value/lessons/04-counting.md#two-digit-route) | 001: item 04 composes ten ones into one ten; 002: count by ones/fives/tens, include starting terms, explain the tens boundary and repeated step |
| PV2-07–09 | [Lesson 3's two-digit route](../../curriculum/mathematics/grade-2/units/place-value/lessons/03-number-forms.md#two-digit-route) | 003: names, numerals, place-value sums, and a matching model |
| PV2-10–12 | [Lesson 5's two-digit route](../../curriculum/mathematics/grade-2/units/place-value/lessons/05-comparison.md#two-digit-route) | 004: correct symbol, first differing tens place, or equality |
| PV3-01, PV3-03 | [Lesson 2](../../curriculum/mathematics/grade-2/units/place-value/lessons/02-hundreds.md) | 001: hundreds/tens/ones models and every zero position |
| PV3-02 | Lesson 2's supported unpacking | 001: unpack a hundred then a ten; explain preservation after both exchanges |
| PV3-04–06 | [Lesson 4's core activities](../../curriculum/mathematics/grade-2/units/place-value/lessons/04-counting.md#activities), supported by lesson 2's exchanges | 001: item 04 composes ten ones into one ten, then ten tens into one hundred; 002: complete counts, boundary explanation, and steps of five/ten/one hundred |
| PV3-07–09 | [Lesson 3's core activities](../../curriculum/mathematics/grade-2/units/place-value/lessons/03-number-forms.md#activities) | 003: three-digit names, numerals, sums, zero places, and a matching model |
| PV3-10–12 | [Lesson 5's core activities](../../curriculum/mathematics/grade-2/units/place-value/lessons/05-comparison.md#activities) | 004: first differing hundreds or tens place, or equality |
| PVX-01 | [Lesson 3's optional thousand activity](../../curriculum/mathematics/grade-2/units/place-value/lessons/03-number-forms.md#optional-thousand-extension) | 001/003 extension: ten hundreds as one thousand, preservation, numeral/name/sum, and four-position model |
| PVX-02 | [Lesson 4's optional boundary activity](../../curriculum/mathematics/grade-2/units/place-value/lessons/04-counting.md#optional-count-through-1000) after lesson 3's extension | 001/002 extension: five count terms and all three exchanges at 999 to 1,000 |

The [teacher guide](../../assessments/C-MATH-001/place-value-check.md#outcome-criteria)
contains the criteria and one key per task. PVX assesses only the taught grouping,
representation, and count through 1,000; it adds no further four-digit computation
or comparison. Core lesson examples and PV2/PV3 counting/regrouping applications
use different amounts; PVX's basic thousand relationship is intentionally taught,
while its count starts at a different value from lesson practice.

### Corrective validation and status

Checked all 46 Markdown files, relative links/anchors, nonempty sections, stable
record/outcome/task identifiers, unchanged draft statuses, and diff whitespace.
All 26 assessment tasks have exactly one key; the three new independent thousand
practice tasks also have matched keys. Recomputed numeric/grouped equation chains,
eight assessment sequences, both optional boundary practice sequences, six
assessment comparisons, six conversion groups, and the three carrying exchanges.
The two-digit stage budgets and optional lesson-3 activity each sum to 25 minutes.
The optional boundary teaching and PVX sitting have separate time estimates in
the unit roadmap; no agreed schedule or observed delivery time is asserted.

Use PR #4 for current-head automated review and merge evidence. These local checks
are an authoring review; the course, unit, lessons, assessments, and learner sheets
remain `draft`, with readiness review pending. No learner results or completed
extensions are inferred. Existing K–12 scope, classical framework, music exclusion,
resource register, and pending provider search queue are preserved.
