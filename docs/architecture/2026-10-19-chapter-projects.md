# Administering every project of a chapter

Date: 2026-10-19. Status: **implemented**. Follows
[administration in the view](2026-10-19-administration.md), which left the
administrator acting only on the project its page was opened for.

## Decision

An administrator's key governs the **chapter**, so the Administration section
works across the chapter's projects, from any project's page:

- **Projects of this chapter** lists every project, its tasks and people,
  with a link to open each.
- **A person in this chapter** shows what someone holds in each project and
  revokes or offboards there, project by project.

Nothing new is signed. Each act is the same governance command as before,
naming the project it acts on, and the page still signs only a command whose
whole payload is exactly the one shown (`exact`). The ledger, the commands
and the authority are unchanged; the new read uses data the ledger already
holds.

## A chapter's projects

```
GET /api/v1/chapters/:chapter_id/projects
    → [{tenant_id, project_id, tasks: {state: count}, grants: n, people: [principal_id]}]
```

This is a signed read by a governance key of that chapter
(`Governance.Read`), like the list of administrators.
`Administrators.projects/1` builds it from the task projection:

| Field | What it is |
| --- | --- |
| a project | any `{tenant, project}` of the chapter with a task, or with a grant or delegation, active or not, so a project everyone left is still listed |
| `tasks` | its tasks counted by state |
| `grants` | its active grants and delegations, so any change in access changes the project ([live view](2026-10-19-live-view.md)) |
| `people` | who holds something there now, counted as offboarding counts it (`Projections.Tasks.held_by/3`): holders of active grants and of delegations, and delegators |

`held_by/3` and this list share one enumeration of authorities
(`Projections.Tasks.authorities/1`, `holders/1`), so an offboarded person
leaves the list exactly when offboarding ends everything they hold.

## The view

- **Projects of this chapter.** Each project shows its tasks in words
  (`taskSummary`: open, completed, cancelled) and its number of people. Other
  projects link to the same page for that project, with the query otherwise
  kept (`projectSearch`), so the sign-in provider carries over. The list
  follows the chapter's feed ([live view](2026-10-19-live-view.md)).
- **A person in this chapter.** The lookup (`GET /api/v1/principals/:id`)
  already answered for every chapter the key governs. The page now shows
  every project of this chapter in which the person holds something, the one
  open first (`projectsHeld`). Each project offers its own **Revoke** buttons
  and **Offboard from \<tenant\> / \<project\>**, and each command names that project.
- **Cancelling** a task in another project is done by opening that project
  from the list. The page then reads its feed as an administrator
  (`Feed.Access.for_administrator/3`) and offers **Cancel as administrator…**
  as before.

## Verification

- **`ChapterProjectsTest`:**
  - projects with a task or a grant are listed, with tasks by state and the
    people holding something;
  - an offboarded person leaves `people` but their project stays listed;
  - another chapter lists nothing.
- **`SpruceGoose.Web.AdministrationTest`:** the projects are listed for a
  governance key of the chapter, and refused unsigned or for a key that is
  not yet declared.
- **Node:**
  - `taskSummary` describes tasks in words;
  - `projectSearch` keeps the rest of the query;
  - `projectsHeld` keeps only this chapter's projects, with the open one
    first.
- **Browser (Chromium):** the reviewer also holds a grant in project-2. From
  project-1's page, the administrator:
  1. sees project-2 listed with its open task and a link to it;
  2. looks the reviewer up once;
  3. offboards them from project-2, then from project-1.

  The ledger holds both offboardings, each naming its project, both signed
  by the administrator's browser key, and the reviewer holds nothing left in
  the chapter.
- **Mutation:** if the page asks the server to prepare an offboarding for
  the project that is open rather than the one shown, the page refuses to
  sign and the browser test fails.

## Limits

- The counts now follow the chapter's feed, others' changes included
  ([live view](2026-10-19-live-view.md)).
- A project is known to the ledger only once it has a task or a grant.
  Creating an empty project is not a ledger act.
- Offboarding is still one command per project. Leaving a whole chapter
  means offboarding from each project it lists.
