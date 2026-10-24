# school-ops

Develop and organize our K–12 curriculum: learning goals, course sequences,
teaching materials, assessments, and weekly plans.

The [Trivium and Quadrivium](docs/trivium-quadrivium.md) organize the curriculum:
grammar, logic, and rhetoric guide inquiry across arithmetic, geometry,
and astronomy. Second grade identifies our starting learners; the course develops
understanding through concrete work, reasoning, and explanation.

This repository is the shared source of truth for curriculum development.
GitHub issues track work; pull requests review changes; the files hold the
current curriculum. Khan Academy is a source of assignable mathematics practice.

## Start here

Our first course is [Second-grade mathematics](curriculum/mathematics/grade-2/README.md).
Start with its [entry check](assessments/C-MATH-001/entry-check.md), then the draft
[place-value unit](curriculum/mathematics/grade-2/units/place-value/README.md).

1. Complete a [scope brief](templates/scope-brief.md) for the first course:
   intended learners, starting skills, chosen arts, goals, and available time.
2. Review the [subject map](curriculum/subject-map.md) and register the course in
   the [curriculum index](curriculum/README.md).
3. Use the [course](templates/course.md), [unit](templates/unit.md), and
   [lesson](templates/lesson.md) templates to connect outcomes, prerequisites,
   activities, and assessments.
4. Select materials through the [resource workflow](resources/README.md).
   For mathematics, follow the [Khan Academy workflow](docs/khan-academy.md).
5. Prepare a [weekly plan](templates/weekly-plan.md), teach the planned work,
   and use the review to update the next plan and curriculum backlog.

## Repository map

| Location | Purpose |
| --- | --- |
| [curriculum/](curriculum/README.md) | Subject map, course index, courses, units, and lessons |
| [resources/](resources/README.md) | Reviewed resource register and source records |
| [assessments/](assessments/README.md) | Assessment designs, rubrics, and completion criteria |
| [planning/](planning/README.md) | Weekly plans and curriculum review decisions |
| [templates/](templates/README.md) | Reusable briefs, course plans, and teaching documents |
| [docs/curriculum-model.md](docs/curriculum-model.md) | Identifiers, prerequisites, outcomes, and readiness rules |
| [docs/trivium-quadrivium.md](docs/trivium-quadrivium.md) | The seven arts and their application in lessons |
| [docs/roadmap.md](docs/roadmap.md) | Development milestones and acceptance criteria |
| [docs/decisions/](docs/decisions/0001-k12-scope.md) | Recorded curriculum decisions |

## Current state

The first subject and grade are selected: second-grade mathematics, `C-MATH-001`.
Its draft includes a course outline, outcomes, an entry check, and six first-unit
lessons with a place-value assessment. Other subject coverage remains open.

The first unit has a prepared two-digit route and separate learner tasks and
teacher keys for two-digit, three-digit, and optional 1,000 checks. Its
[authoring review](docs/reviews/2026-10-09-first-unit.md) records corrections;
teaching records remain draft pending their applicable readiness review.

The organizing framework is selected: the Trivium and Quadrivium. Teaching dates
and weekly time remain undecided.
Seven Khan Academy resources are reviewed for optional place-value practice after
hundreds. The [route review](docs/reviews/2026-10-11-khan-place-value.md) preserves
the two-digit route and records unresolved bounded-practice and thousand gaps.
No teaching results or class assignments have been recorded.
See the [roadmap](docs/roadmap.md) for the remaining development work.

## Working method

Use a curriculum proposal issue to agree on the learning goal and scope. Develop
the material on a branch, review its outcomes and assessment coverage in a pull
request, and merge the reviewed version. A draft may contain open questions;
material marked `ready` must satisfy the [readiness rules](docs/curriculum-model.md).

Keep shared curriculum and teaching plans here. Store learner names, individual
scores, accommodations, and assignment links exposing class details in a private
system. Weekly reviews in this repository record changes to teaching plans.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow.
