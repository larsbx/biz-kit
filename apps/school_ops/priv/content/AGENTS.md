# Working in school-ops

- This repository develops a K–12 curriculum through the Trivium and Quadrivium.
  Read `docs/trivium-quadrivium.md` and follow the current course scope. Do not
  infer learner skills or schedules or introduce standards-based alignment.
- Music is excluded by user direction. Do not introduce musical activities,
  rhythm exercises, harmony lessons, or music resources.
- Include substantive grammar, logic, and rhetoric work in lessons. Identify
  the actual Quadrivium art and its mathematical content; do not merely rename
  conventional topics or reserve reasoning and explanation for older learners.
- Read `README.md`, `docs/curriculum-model.md`, and the relevant course before
  making curriculum changes. Preserve stable IDs and prerequisite relationships.
- Separate proposed curriculum, reviewed teaching material, and observed results.
  Apply `docs/curriculum-model.md` readiness requirements for the record's own type;
  unresolved required fields block `ready`, but missing optional metadata does not.
- Link course, unit, and lesson outcomes to evidence criteria. Assessments check
  those outcomes or named entry skills. Instruction/practice-only resources need
  source, access, and suitability review; any assessment use, including combined
  roles, links a ready assessment design. Resource availability and exercise
  completion alone do not establish mastery.
- Use the connected Khan Academy capability for requested mathematics exercise
  searches. Only apply grade or standard search limits explicitly supplied by
  the user. Do not use web search to retrieve Khan Academy exercises.
- Exercise-selection replies must follow the Khan Academy tool's rendering rules.
  Use a separate interaction for repository edits and curriculum discussion.
- Register only resource links and metadata actually returned or supplied.
  Leave unknown IDs, URLs, provider metadata, and source rights unresolved.
- Store external materials by reference and attribute sources. Do not assume
  permission to redistribute their content.
- Keep learner-specific records and class-specific assignment URLs out of this
  shared repository. Follow the private-records convention in `.gitignore`.
- Review relative links, index entries, ID references, and readiness fields before
  opening a pull request. Documentation-only changes do not require a new test suite.
- Use GitHub issues and pull requests for curriculum work. Do not assign people
  or notify external recipients unless the user asks.
