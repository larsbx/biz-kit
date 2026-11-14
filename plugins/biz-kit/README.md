# Biz-Kit plugin

An installable ChatGPT and Codex plugin for working with the Biz-Kit repository
without bypassing its authority boundaries.

## Included workflows

- `biz-kit-route`: classify requests and route them to the correct platform core.
- `biz-kit-operations`: turn knowledge and operational signals into reviewable suggestions.
- `biz-kit-commercial-clearing`: analyze and prepare source-bound commercial setoff proposals.
- `biz-kit-verified-change`: implement repository changes with exact-revision evidence.

This first version contains skills only. It does **not** expose a write-capable MCP
server and does not confer business authority. Operational effects must continue
through Biz-Kit's authenticated principals, scoped grants, signed command admission,
canonical event ledger, and applicable review gates.

## Local testing

The repository marketplace is defined at `.agents/plugins/marketplace.json`.
Restart a supported ChatGPT/Codex client, select the **Biz-Kit repository**
marketplace, install **Biz-Kit**, and test it in a new chat.

## Future MCP increment

Add an MCP server only after a stable, authenticated Biz-Kit service boundary exists.
The initial tool set should separate reads from proposals and effects:

- read: `search_business_knowledge`, `get_operations_view`, `inspect_obligation`
- proposal: `draft_task_proposal`, `draft_procurement_request`,
  `draft_setoff_intent`
- effect: `submit_signed_command` only with authenticated principal, exact scope,
  idempotency key, source revision, and explicit confirmation

Tool results must return the admitted event or refusal, its canonical identifier,
source revision, and verification evidence. A tool response must never describe an
unadmitted proposal as completed business state.
