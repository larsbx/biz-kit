# Biz-Kit plugin

The repository marketplace installs four skills for domain routing, operational
suggestions, commercial-clearing analysis, and evidence-backed repository changes.
Select **Biz-Kit repository** in a supported client, install **Biz-Kit**, and
start a new conversation. The marketplace entry lives at
`.agents/plugins/marketplace.json`.

## Authenticated application bridge

TaskHost serves the optional stateless Streamable HTTP MCP endpoint at `/mcp`.
The connection belongs to the target installation. The repository package
contains skills and documentation. Live tool results stay in the authenticated
channel, and the MCP server exposes no resource or prompt collections.

| Tool | Result and source |
| --- | --- |
| `get_operations_view` | Paged task summaries from one configured workspace, with task event IDs and a SHA-256 revision of the sorted workspace task summaries. |
| `search_business_knowledge` | Matches from the pinned BizOps reference catalog, with source commit, tree, URL, and document digest. Catalog reference material has its own source and carries no project approval. |
| `get_approved_task_knowledge` | Recommendations for an existing task, with task revision, source event IDs, source fingerprint, and governance approval event. Only current approved items with available sources qualify. |
| `get_task_evidence` | Current task evidence submission ID, criterion digests, and custody receipt IDs under the existing operator/reviewer ACL. Evidence bodies and submitter identities stay in TaskHost. |
| `preview_task_due_date` | An unsigned, unheld preview for an operator with the exact task source event ID. The preview carries the task and timing versions and creates no command or ledger event. |

Every tool takes a `workspace_id` that must appear in both the Operations
configuration and the bridge allowlist. The server derives chapter, tenant, and
project from it and checks the existing project ACL. Each tool call checks its OAuth credential
and applicable authority again before disclosure. An intervening ledger append or a changing knowledge source
can return `stale_source`. Refresh the view before retrying. There is no API for
pending knowledge, commercial obligations, artifact bytes, or command submission.

## Installation-specific configuration

Use a dedicated OAuth test tenant with a synthetic Operations workspace for
the first connection. Configure the following TaskHost environment variables.
Missing or malformed configuration disables the bridge.

| Variable | Value |
| --- | --- |
| `BIZKIT_PLUGIN_MCP_RESOURCE` | Exact public HTTPS audience ending in `/mcp`, for example `https://ops.example.test/mcp`. |
| `BIZKIT_PLUGIN_OAUTH_ISSUER` | Canonical HTTPS authorization-server issuer. |
| `BIZKIT_PLUGIN_INTROSPECTION_URL` | The issuer's HTTPS RFC 7662 introspection endpoint. |
| `BIZKIT_PLUGIN_INTROSPECTION_CLIENT_ID` | Resource server's confidential introspection client ID. |
| `BIZKIT_PLUGIN_INTROSPECTION_CLIENT_SECRET` | Introspection secret, injected by the host's secret mechanism. |
| `BIZKIT_IDENTITY_BINDINGS` | Existing administrator-managed identity bindings for the issuer's verified subjects. |
| `BIZKIT_PLUGIN_WORKSPACE_IDS` | Comma-separated Operations workspace IDs explicitly approved for the bridge. |
| `TASK_HOST_OPERATIONS_CONFIG` | Operations configuration defining each approved workspace and its project scope. |

Configure the issuer for authorization code with PKCE and resource-bound access
tokens, request scope `bizkit.plugin.read`, and register the client's redirect
URI and client identity using one of the supported registration methods. Publish
the issuer's OAuth/OIDC metadata. The authorized introspection response must
include `active`, `iss`, `sub`, `aud`, `exp`, `scope`, and bearer
`token_type`. If present, `nbf` also applies. Configure Basic client
authentication for introspection and ensure it reports revocation immediately.
Bind the issuer and subject to the existing principal and administer its
project grants through the existing Biz-Kit workflow.

Route `/mcp` and `/.well-known/oauth-protected-resource/mcp` to the rate-limited
TaskHost behind TLS. Keep authorization headers and request/response bodies out
of proxy logs and disable response caching. The endpoint accepts requests with
no `Origin` or with the origin of the configured HTTPS resource. It responds
with JSON to POST and returns HTTP 405 for GET at `/mcp` because it has no SSE
stream. Keep the connection private to the approved client or workspace.

## Verification and client installation

Repository validation with PostgreSQL and the pinned BEAM toolchain:

```sh
export MIX_ENV=test
mix deps.get --check-locked
(cd apps/coop_substrate && mix event_store.create --quiet && mix event_store.init --quiet)
(cd apps/task_host && mix ecto.create && mix ecto.migrate)
(cd apps/task_host && mix test test/task_host/web/plugin_bridge_test.exs test/task_host/web/execution_test.exs --seed 0)
python3 tools/validate_biz_kit_plugin.py
```

The tests exercise the real TaskHost endpoint and signed ledger with fixtures
for the OAuth issuer. To verify an installed client after connection approval:

1. Test the authorized HTTPS endpoint with MCP Inspector. Confirm OAuth
   discovery, sign-in, initialization, and the five advertised tools.
2. In ChatGPT Plugins select **Add custom MCP server**, enter the approved
   URL, configure OAuth, and verify tool discovery. For local Codex, add
   the server separately and then sign in.

   ```sh
   codex mcp add biz-kit --url https://ops.example.test/mcp
   codex mcp login biz-kit
   ```
3. In a new conversation, verify a permitted read and its source pins, a
   foreign-workspace refusal, and an unsigned due-date preview. Revoke the
   token and the project grant in separate trials and confirm each refusal.
   Record the exact deployed revision, client, issuer, and the result of each
   trial. If packaging a ChatGPT connection with the repository's skills,
   use the technical ID assigned when that connection is created.

[OpenAI connection and installation guide](https://developers.openai.com/plugins/deploy/connect-chatgpt)
· [OpenAI OAuth requirements](https://developers.openai.com/plugins/build/auth)
· [MCP authorization specification](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)
