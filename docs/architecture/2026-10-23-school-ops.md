# School operations within the biz-kit umbrella

Date: 2026-10-23. Status: **content integration, not school runtime cutover**.
Source: [larsbx/school-ops](https://github.com/larsbx/school-ops)
at commit `ccacc596d63a7b04d33d62bc77636fd93de9f995`.

## Decision

School operations belongs within `biz-kit`, as `apps/school_ops`. Its existing
K–12 Trivium/Quadrivium course, assessment, resource, review and planning
records are imported intact as versioned authoring **content** under
`apps/school_ops/priv/content/`. Stable IDs and relative links are retained.
The imported `SchoolOps.read/1` surface only exposes checked-in public
materials. It is not a new school information system.
Keep the original pedagogical decisions (including excluding music), entry
assessment criteria, and separate draft/ready/retired material statuses.

## Boundaries

- **Curricular truth:** reviewed versioned Git artifacts with source commit and
  per-file blob evidence, plus future explicit approval. No learner mastery
  or schedule may be inferred from a file being marked ready.
- **Workflows:** use existing `task_core` blueprints and `coop_substrate`
  signed task admission for later authenticated assignments, instructor reviews
  and scheduling. No competing task writer or unreviewed Git-to-ledger path.
- **Identity and private records:** learner names, scores, accommodations and
  class-specific assignment links must not enter this public repository,
  artifact package or logs. Future student records require a separate
  privacy/access-control, retention and audit specification. This app stores
  **none**.
- **Release/runtime:** the app is packaged into both umbrella releases, but
  has no external deps, supervisor, migrations, jobs, credentials, routes or
  side effects. Only public curriculum and a read-only local file API.
- **Rights/provenance:** external educational materials stay references and
  metadata. Do not assume redistribution rights. Preserve source IDs.

## Source synchronization and cutover gates

1. Snapshot every tracked regular file in upstream `main` from the pinned
   commit, mapped to `priv/content/<path>`. Original SHA-1 Git blob IDs in
   `source-manifest.tsv` permit content comparison. Original Git history
   stays upstream; this is **not** a `git subtree` history import.
2. Verify imported paths, relative links, content-reader tests, compilation
   and absence of private learner data. CI must pass before merge. No claim
   of completed CI acceptance is made by this document.
3. Resolve upstream open PRs (notably school-ops #8) and active curriculum
   work before selecting the editorial cutover commit. Importing `main`
   does not include unmerged changes.
4. Choose one editorial authority. At cutover either make biz-kit authoritative
   and redirect/freeze upstream, or maintain a documented one-way vendor
   import process with source commit and manifest. Avoid divergent writing.
5. Migrate open issues and PR references deliberately; issues/PR history does
   not transfer. Do not archive upstream in this PR.

This slice has no student enrollment, lesson scheduling, gradebook, UI or school
operation writer. Those need explicit security and acceptance tests.
