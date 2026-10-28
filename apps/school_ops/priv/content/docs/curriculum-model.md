# Curriculum model

## Structure

A subject contains courses. A course contains ordered units; a unit contains
lessons. Each course, unit, and lesson names the learning outcomes it serves.
Assessments define how those outcomes will be demonstrated. Resource records
identify materials used to teach or practice them. Weekly plans schedule the work.

The [Trivium and Quadrivium](trivium-quadrivium.md) govern instructional design.
Course and lesson records name the relevant arts. Grammar, logic, and rhetoric
are practiced together at a level the learner can handle; arithmetic, geometry,
and astronomy supply the selected mathematical studies. Music is excluded.

Use `curriculum/<subject>/<course-slug>/` for a course, with a `README.md` course
record, `scope.md` brief, and `units/<unit-slug>/README.md` unit records. Lessons
live under their unit in `lessons/<lesson-slug>.md`.

Assessment designs live in `assessments/<course-id>/`. Shared resource records
live in `resources/<resource-id>.md`. Register courses as they are developed;
register resources only after they meet resource readiness. Draft resource records
may be authored before registration.

## Stable identifiers

| Record | Pattern | Example identifier |
| --- | --- | --- |
| Course | `C-<SUBJECT>-<NNN>` | `C-MATH-001` |
| Unit | `U-<SUBJECT>-<NNN>-<NN>` | `U-MATH-001-01` |
| Lesson | `L-<SUBJECT>-<NNN>-<NN>-<NN>` | `L-MATH-001-01-01` |
| Outcome | `O-<SUBJECT>-<NNN>-<NNN>` | `O-MATH-001-001` |
| Assessment | `A-<SUBJECT>-<NNN>-<NN>` | `A-MATH-001-01` |
| Resource | `R-<PROVIDER>-<NNN>` | `R-KHAN-001` |

These illustrate the naming convention; some are now used by the
[second-grade mathematics course](../curriculum/mathematics/grade-2/README.md).
The course and resource indexes identify actual records. Choose subject and
provider codes when adding records. IDs remain stable when titles or paths change;
update links after moves and do not reuse retired IDs.

Define outcomes once in the course outcome table. Units and lessons refer to those
IDs. An outcome describes observable work, such as a skill demonstrated under
stated conditions; the assessment supplies the evidence and success criterion.

## Prerequisites and the chosen arts

List prior outcome IDs with links, or describe an entry skill and how to check it.
Sequence units after their prerequisites. Resolve circular dependencies before
marking the course ready.

Grade level describes our intended starting audience. Establish actual starting
skills through entry work. Define mathematical goals within the chosen arts,
including the language, reasoning, and explanation each task develops. Numerical
ranges and local evidence criteria are curriculum choices to review after entry
work. Provider labels are resource provenance, not the organizing framework.

## Material status

| Status | Meaning |
| --- | --- |
| `draft` | Being developed; unresolved fields and questions remain visible |
| `ready` | Reviewed for its declared role and scope; meets its record-type requirements |
| `retired` | Retained for reference; replacement and reason are recorded |

## Readiness by record type

All ready records have an identified purpose and scope, checked references,
completed applicable fields, and a review date with a supporting pull request.
Assign a stable ID where the record type defines one. Resolve required-field
placeholders and review blockers. Optional metadata may remain `not reported`;
use `not applicable` with a reason for fields that do not apply. Future delivery
notes and replacement history need not be filled before the material is used.

Apply the additional requirements for the record's type:

| Record type | Required content for `ready` |
| --- | --- |
| Scope brief | Intended learners, entry skills and checks, goals, scope boundary, chosen arts, agreed teaching-time budget, calendar decision, and materials/access decisions |
| Course | Level, prerequisites, arts, stable outcomes, planned time, materials, ordered units, and outcome-specific assessment criteria or links to assessment designs containing them |
| Unit | Level, prerequisites and entry check, outcome references, time and materials, lesson sequence, assessment coverage and criteria, and a progression/review decision |
| Lesson | Level, prerequisites, outcomes, time and materials, usable activity sequence with Trivium work, an outcome-linked check with success criteria, and feedback/next steps |
| Assessment | Purpose, level, assessed outcomes or entry skills, actual tasks, administration conditions, time/materials/permitted support, evidence criteria, and a teacher key or model evidence appropriate to the task |
| Resource | Source, role, intended audience, access, and suitability review as defined in [resource readiness](#resource-readiness) |
| Weekly plan | Dates, agreed time budget, session order, prerequisite checks, available materials/resources, and links to the lessons and outcome checks to be used; planned time fits the budget |

Courses, units, and lessons require teaching sequences and assessment criteria.
Those criteria and materials may be supplied through explicit links rather than
duplicated. Assessments require their own tasks and evidence criteria, not a course
sequence. Scope briefs and weekly plans may reference these records without
repeating their rubrics.

A ready course or unit includes ready child teaching records. For ready courses,
units, and lessons, any required resource records or linked assessment designs must
also be ready. Check each dependency against its own record type. Weekly plans
likewise reference ready lessons, required resources, and assessment designs for
the sessions to be delivered. A ready resource does not make its consuming lesson,
unit, or course ready.

### Resource readiness

Before marking a resource `ready`, record and review:

- Its title, provider/author, and source locator: a checked general URL, full
  citation, or private-location reference sufficient to identify the material.
- Its role: instruction, practice, assessment, or a combination; its intended
  audience, relevant outcomes, and contribution to the chosen art and practice.
- Required access/materials and checked availability, plus suitability for that
  role and audience: starting skills, difficulty, notation, and accessibility.
- Whether it is referenced or copied. Verify reuse rights before including copies;
  reference-only use does not require permission to redistribute the content.
- A dated review and supporting pull request confirming these checks.

Resources used only for instruction or practice do not require a teaching sequence,
assessment design, or assessment criteria. They may be reviewed and registered
before a consuming lesson is authored. A time estimate is useful where applicable
but is not a required teaching plan. Missing provider-reported IDs, levels, or
curricular labels are non-blocking optional metadata when the source is otherwise
identified.

If any intended role includes assessment, including combined instruction/practice
and assessment use, link a ready assessment design specifying the relevant tasks,
conditions, and evidence/success criteria. Keep those criteria in the assessment
record; the resource record supplies the source and intended use. This additional
check applies only to assessment use.

Status describes teaching material. Learner mastery is a separate judgment based
on the stated assessment criteria; it cannot be inferred from material status or
exercise completion.
