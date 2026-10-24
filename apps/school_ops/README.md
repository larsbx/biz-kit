# SchoolOps — K–12 curriculum in biz-kit

This dependency-free Mix app packages the public, reviewed authoring records
from [larsbx/school-ops](https://github.com/larsbx/school-ops) at
`ccacc596d63a7b04d33d62bc77636fd93de9f995`. Its original source entrypoint is
[priv/content/README.md](priv/content/README.md), with
[Grade 2 mathematics](priv/content/curriculum/mathematics/grade-2/README.md),
[assessments](priv/content/assessments/README.md),
[resource reviews](priv/content/resources/README.md), and
[curriculum rules](priv/content/docs/curriculum-model.md).

```elixir
{:ok, source} = SchoolOps.read("curriculum/mathematics/grade-2/README.md")
```

`SchoolOps.read/1` only reads files bundled under `priv/content`; it does not
store student data, log mastery, enroll learners, grant permissions, dispatch
assessments or expose an HTTP endpoint. Treat `draft` and `ready` as *material*
statuses, not learner achievement. Stable curriculum and resource IDs survive
this path move. All original relative links within the snapshot are retained.

Use `mix test` in this directory to check its reader.
The [upstream file manifest](source-manifest.tsv) gives the original Git blob
for each imported path. The upstream commit is preserved as provenance; this
is a content snapshot, **not a Git subtree history import**. Git log/blame for
older curricular edits remain in the upstream repository.

Continue source-repository pull requests, including source-archiver PR #8, there
until a reviewed editorial cutover; do not fork two authoritative curriculum
branches. The [integration boundary](../../docs/architecture/2026-10-23-school-ops.md)
sets conditions for future operations and non-public learner records.
