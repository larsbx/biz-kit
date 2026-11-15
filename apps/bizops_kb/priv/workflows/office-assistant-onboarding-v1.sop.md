# Office assistant onboarding: retained SOP bundle

Bundle format: bizops-kb-sop/1
Workflow: office-assistant-onboarding-v1
SOP version: 1.0.0
Source repository: larsbx/bizops-kb
Source commit: 8749d8db1abd3145b22c6a27da2cc49a41c303fe
Source tree: 79f146858c5d9d850df69b67294cb3fabf131bd1

This bundle preserves both original procedures below, including their original
product names and historical assumptions. Owner Part A must confirm the current
engagement, approved stack, scope, data handling and responsible people before
setup. Companion procedures are references to review for that engagement.
Reading this bundle or adopting its workflow does not authorize deployment.
Completion requires evidence and the existing signed task review process.

## Source 24.12: Hermes assistant on-site deployment

Original path: 20-29 Products, suppliers, equipment, processes, & inventory/24 Processes & procedures 📋/24.12 Hermes assistant on-site deployment.md
SHA-256: 0803f0b19737eae54b6df585fac4e5136d7fbadb151873b90aa6227e7df20c34
Git blob: 5ef018022c8d5e26c13efd6c013784c70e398fdf
Original bytes: 7296

<!-- BEGIN ORIGINAL SOURCE 24.12 -->
# Hermes assistant on-site deployment

## Decision

Deploy a Hermes assistant to a client office in two days on site: day 1
discovers and stands up the office zone, day 2 enrolls, trains, and hands off.
**Buzz is the hub.** Every inbound message and document funnels through it:

```text
Telegram ─────────────┐
WhatsApp / SMS ───────┤
Upload links ─────────┼──► Buzz hub ──► Hermes agents
Posts in Buzz ────────┘        │
                               └──────► librarian ──► J.D index, by tier
```

- **Buzz** is the single intake and the record of it: everything lands there
  first, then is routed to the right agent, and documents are handed to the
  librarian for filing. Team threads and hand-offs between people and agents
  live there too. Every employee has a Buzz account.
- **Telegram** is the private line: each employee talks one-to-one with their
  own Hermes agent through the Telegram bot. It is a spoke into Buzz, not a
  separate system.
- **WhatsApp** (Baileys bridge) and **SMS** are optional extra private lines
  for people who need them, never a replacement for Telegram.
- **Restricted documents** go straight to the encrypted vault through the
  restricted upload link; Buzz records that one arrived, never its content.
- **Office files** sync per department: open, internal, restricted (anchors
  only), and intake (from Buzz to the librarian), per [[24.12f Hermes assistant office file plane]].

Companion notes:

- [[24.12a Hermes assistant admin runbook]]
- [[24.12b Hermes assistant quick cards]]
- [[24.12c Hermes assistant training session]]
- [[24.12d Hermes assistant owner sign-off]]
- [[24.12e Hermes assistant hosting model]]: we host one isolated stack per company
- [[24.12f Hermes assistant office file plane]]: department folders and who holds them
- [[24.13 Hermes assistant channel topology tests]]: decides the primary channel; Telegram is provisional until then

This note records the procedure. It does **not** authorize a deployment;
each engagement starts with a signed Part A in [[24.12d Hermes assistant owner sign-off]].

## Done when

- [ ] Every employee has passed the round-trip and upload tests
- [ ] A restore has succeeded
- [ ] The internal admin has completed the client-side steps for one add and one revoke using the runbook and the standard support round trip

## Before you arrive

- [ ] Staff roster collected (table below)
- [ ] Cloud zone live: this company's own stack (Buzz hub, Hermes gateway with its own Telegram bot, base profile) per [[24.12e Hermes assistant hosting model]]
- [ ] Tailscale tailnet + ACLs drafted for cloud ↔ office
- [ ] Windows installer built, signed, tested on a clean machine
- [ ] Johnny.Decimal draft index for this company
- [ ] Wiki host decided; Copyparty quiet/headless config ready
- [ ] Owner sign-off on scope, restricted-document list, and who holds vault keys

| Name | Job role | Department(s) | Buzz account | Telegram account | Extra channel | Machine role | Syncthing ID |
| --- | --- | --- | --- | --- | --- | --- | --- |
|  |  |  |  |  |  |  |  |
|  |  |  |  |  |  |  |  |
|  |  |  |  |  |  |  |  |

Extra channel: none / WhatsApp / SMS. Machine role: anchor (every department and
the vault; record which anchor is the librarian), desktop, or laptop
(receive-only). Record each device's tailnet hostname beside its Syncthing ID.
Use one row per device when an employee has several machines.

## Day 1 AM: discovery

- [ ] Walk each role's daily workflow; pick 2–3 assistant use cases per role
- [ ] Inventory documents → assign tier (open / internal / restricted)
- [ ] Revise the J.D index with the owner; freeze v1
- [ ] Network/machine audit: OS versions, admin rights, disk space on anchors
- [ ] Departments mapped; anchors, the librarian anchor, and each anchor's vault location chosen

| Role | Use case 1 | Use case 2 | Use case 3 |
| --- | --- | --- | --- |
|  |  |  |  |
|  |  |  |  |

## Day 1 PM: office zone

- [ ] Copyparty, librarian, encrypted vault up; write-only upload links tested
- [ ] Syncthing: every device's ID recorded; generated configs installed per [[24.12f Hermes assistant office file plane]]; matrix reviewed with the owner
- [ ] Cross-zone backups running; one restore actually performed
- [ ] Ingress wired: Telegram, extra channels, and upload links all land in Buzz; Buzz routes messages to agents and documents to the librarian
- [ ] Pilot: 2 employees end to end: a Telegram message and a document each land in Buzz, reach the right agent, and get filed in the right tier

## Day 2 AM: enrollment

- [ ] Installer on every machine; one Hermes profile per employee
- [ ] Every employee has a Buzz hub account and started the Telegram bot from their own account
- [ ] Gateway routes: catch-all route + per-profile allowlist (routing isn't deny-by-default)
- [ ] Per employee: Telegram round-trip; a document they send appears in Buzz and is filed in the correct tier
- [ ] Negative test: restricted doc sent via chat is refused/redirected to upload link
- [ ] Per non-anchor desktop/laptop: company-wide folders plus only its assigned departments' open/internal folders; desktops send + receive, laptops receive only
- [ ] Per anchor, including employee-used anchors: every department's open/internal/restricted folders and company-wide folders; restricted inside the vault, intake only on the librarian anchor, per [[24.12f Hermes assistant office file plane]]

Per-employee test log (initial each cell when it passes):

| Employee | Installer | Profile | Telegram round-trip | Message in Buzz | Doc → Buzz → tier | Restricted refused | Extra channel |
| --- | --- | --- | --- | --- | --- | --- | --- |
|  |  |  |  |  |  |  |  |
|  |  |  |  |  |  |  |  |
|  |  |  |  |  |  |  |  |

## Day 2 PM: training + handoff

- [ ] 30–45 min group session ([[24.12c Hermes assistant training session]])
- [ ] One-page quick card per channel ([[24.12b Hermes assistant quick cards]])
- [ ] Named internal admin: ________
- [ ] Runbook delivered ([[24.12a Hermes assistant admin runbook]])
- [ ] Admin performs the client-side steps for one add using the runbook; support regenerates configs and handles the cloud edge
- [ ] Offboarding test: admin performs the client-side profile/device revoke using [[24.12a Hermes assistant admin runbook]] and the standard support round trip; peer-side Syncthing cutoff verified before tailnet removal, and sync fails over both LAN and tailnet
- [ ] Support window agreed: ________
- [ ] 2-week check-in scheduled: ________

## Risks

The Baileys WhatsApp bridge is unofficial and can break or get the number
banned without notice. That is why Telegram, not WhatsApp, is everyone's
private line: WhatsApp is only ever an extra channel, and anyone using it falls
back to Telegram. If Telegram itself is down, staff reach their agents
directly in Buzz.

Buzz is the single intake: while it is down, nothing new is routed or filed.
Its status is in the admin's weekly checks, and restoring it is the support
contact's job.

- [ ] Owner acknowledged the WhatsApp risk, the Telegram default, and Buzz as the single intake
- [ ] Owner signed Part B of [[24.12d Hermes assistant owner sign-off]]

<!-- END ORIGINAL SOURCE 24.12 -->

## Source 24.12d: Hermes assistant owner sign-off

Original path: 20-29 Products, suppliers, equipment, processes, & inventory/24 Processes & procedures 📋/24.12d Hermes assistant owner sign-off.md
SHA-256: 7fa0018dee855d5a3dd6f542914ac0bb98fc1df83d1e189bc925826e66732d53
Git blob: b2c94dff2a29e45dd4aa06dc7ec92b65cbcd4495
Original bytes: 4897

<!-- BEGIN ORIGINAL SOURCE 24.12d -->
# Hermes assistant owner sign-off

The owner signs twice. Part A is signed before the on-site visit and fixes the
scope, the restricted list, and who holds the keys. Part B is signed at
handoff and confirms the system works and the internal admin can run it. Part
of [[24.12 Hermes assistant on-site deployment]].

**Company:** ________ · **Owner:** ________ · **Installer:** ________ · **On-site dates:** ________

## Part A: before arrival

**Scope: included**

- Cloud zone: Buzz hub (single intake for all messages and documents), Hermes
  gateway, Telegram bot, one assistant profile per employee, hosted by the
  installer as a stack isolated from every other client
- Office zone: Copyparty file drop, librarian, encrypted vault, Syncthing,
  cross-zone backups
- Tailscale network linking cloud and office
- Enrollment of ____ employees on the Buzz hub and Telegram; extra channels
  (WhatsApp / SMS) for: ________
- 45-minute staff training, quick cards, admin runbook
- Support window: ________; 2-week check-in

**Scope: not included**

- ________ (e.g. email migration, accounting system integration, hardware purchases)

**Restricted documents**: these never go through chat, only the vault via upload link:

| Document type | Example | Who may access |
| --- | --- | --- |
|  |  |  |
|  |  |  |
|  |  |  |

**Vault key holders** (at least two; the installer keeps no copy):

| Name | Role | Where the key is stored |
| --- | --- | --- |
|  |  |  |
|  |  |  |

**Hosting and data terms**

| Item | Value |
| --- | --- |
| Cloud zone hosted by | ________ (installer) |
| Hosting location | ________ |
| Data processing agreement signed | ________ (date) |
| Chat and document retention | ________ |
| Data returned and deleted on exit within | ________ days |

**Policies the owner decides**

| Question | Decision |
| --- | --- |
| Can management read employees' assistant chats? |  |
| How long are chats kept? |  |
| Named internal admin |  |
| Who approves adding or removing an employee? |  |

Owner signature: ________________ · Date: ________

## Risks acknowledged

The owner initials each risk to confirm it was explained and the mitigation
accepted.

| Risk | Mitigation | Initials |
| --- | --- | --- |
| WhatsApp runs on Baileys, an unofficial bridge; it can break or the number can be banned without notice | Telegram is everyone's main channel; WhatsApp is an optional extra only |  |
| Telegram is a third-party service; an outage cuts every private line at once | Staff reach their agents directly in Buzz; admin runbook escalation |  |
| Buzz is the single intake; while it is down nothing new is routed or filed | Status in the admin's weekly checks; support contact restores it |  |
| The assistant can give wrong answers | Staff trained to check anything sent to customers or tied to money |  |
| Lost vault keys mean restricted files cannot be recovered | Two named key holders; storage location recorded in Part A |  |
| Restricted data sent in chat by mistake | Refusal + redirect to upload link; report-without-blame rule; admin removes it |  |
| Single internal admin unavailable | Runbook written down; support contact covers the support window |  |

## Part B: handoff acceptance

The owner signs once every item is ticked, witnessed, or shown evidence for.

- [ ] Every employee passed the Telegram round-trip test
- [ ] Every employee has a Buzz hub account; their messages and documents arrive in Buzz
- [ ] Every employee passed the upload test (document went through Buzz and was filed in the correct tier)
- [ ] Restricted document sent in chat was refused and redirected
- [ ] Extra-channel users passed a round-trip on that channel too
- [ ] A restore from backup succeeded (file: ________, date: ________)
- [ ] Admin completed the client-side steps for one employee add using the runbook and the standard support round trip
- [ ] Admin completed the client-side profile/device revoke using the runbook and the standard support round trip; peer-side Syncthing cutoff verified before tailnet removal, and sync failed over both LAN and tailnet
- [ ] Training session held; quick cards handed out
- [ ] Runbook delivered to the admin
- [ ] Vault keys held by the people named in Part A
- [ ] Folder matrix reviewed: non-anchor desktops/laptops have company-wide folders plus only their assigned departments' open/internal folders, in the correct send/receive mode; employee-used anchors retain every department's replicas, restricted inside the vault, and intake is shared only by the librarian anchor and edge ([[24.12f Hermes assistant office file plane]])

**Open items carried past handoff** (with owner and due date):

| Item | Owner | Due |
| --- | --- | --- |
|  |  |  |

Support window ends: ________ · 2-week check-in: ________

Owner signature: ________________ · Date: ________

Installer signature: ________________ · Date: ________

<!-- END ORIGINAL SOURCE 24.12d -->
