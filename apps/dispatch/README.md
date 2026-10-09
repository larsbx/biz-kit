# Central service

The Ash/Phoenix OTP release. Section 21.1 makes this the sole domain
implementation: it owns durable state, authorization, provider ingress
validation, the machine API, and the server-rendered portal.

## Local commands

```sh
mix setup                    # fetch dependencies, create and migrate the database
mix phx.server               # run (or `iex -S mix phx.server`)
mix test                     # unit tests; no database required
mix test.integration         # requires PostgreSQL/PostGIS
mix format                   # apply formatting
mix credo --strict           # lint
mix dialyzer                 # typecheck
mix openapi.generate         # rewrite ../contracts/openapi.json
mix openapi.check            # fail if it has drifted
mix ash_postgres.generate_migrations --check
```

From the repository root, `make` wraps each of these so they run in the Compose
network.

## Configuration

Every value comes from the environment at runtime (§31); nothing is embedded in
an image. `.env.example` at the repository root lists every name with safe
development defaults.

`Dispatch.Config` validates the configuration in `Dispatch.Application.start/2`
and raises rather than binding a port. It checks that each port names a compiled
module implementing its behaviour, that a development-only adapter is not
selected in production, that a required secret for the selected adapter is
present, that `BREAKGLASS_MAX_TTL_SECONDS` is within 60–3600 and
`FACE_CHALLENGE_TTL_SECONDS` within 30–120, that the production single-user
break-glass flow is off, and that requester and approver entitlements differ.

Adapter selection is per port and independent (§§27, 28, 29): messaging, voice
control, voice media, geocoder, router, map presentation, agent runtime, and
agent streaming runtime each choose their own module.

## Health checks

| Endpoint | Asserts |
| --- | --- |
| `GET /health/live` | The process is running. Nothing else. |
| `GET /health/ready` | Database reachable and no migration pending. No outbound provider call (§32). |
| `GET /health/dependencies` | Adapter selection and redacted secret presence. Requires `Authorization: Bearer $DIAGNOSTICS_TOKEN`. |

## Failure modes

| Symptom | Cause |
| --- | --- |
| `Invalid configuration; refusing to start` | A Section 31 rule is violated; the message names the stable code and the key |
| `/health/ready` → 503 `migrations_pending` | Section 22 forbids auto-migration on boot; apply them deliberately |
| `/health/ready` → 503 `database_unreachable` | PostgreSQL is down or `DATABASE_URL` is wrong |
| `/health/dependencies` → 401 | `DIAGNOSTICS_TOKEN` unset or shorter than 32 bytes; it fails closed |
| `mix openapi.check` fails | A route or schema changed without regenerating `contracts/openapi.json` |
| Integration tests fail on `postgis_version()` | The database was created without PostGIS |

## Layout

```
lib/dispatch/          domains (§21.2), provider ports and adapters (§§27–29)
lib/dispatch_web/      transport only (§21.1): controllers, components, Datastar, plugs
priv/repo/migrations/  reviewed SQL (§22); production never auto-migrates
priv/static/vendor/    the pinned Datastar bundle (§26.1); see VENDOR.md
priv/static/js/maps/   the only first-party portal JavaScript (§26.1)
```
