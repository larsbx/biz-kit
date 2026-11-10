# Operations MVP on papa (test/dev)

A **development-mode** `orchestration` release serving the configurable
operations workspace (FO-01, [design](../../docs/architecture/2026-11-09-configurable-operations-mvp.md))
on papa, `127.0.0.1:4001`, as the user service `bizops-dev`. It is for
testing with made-up data, not a production installation.

## Why development mode

There is no WorkOS account, and the development identity provider is allowed
only in development builds. It signs in **anyone who can reach the port** as
the configured subject, including other local users on the host. Keep it on
loopback and never put real records in it.

The development build hardcodes `localhost:5432`, role `postgres` and the
`*_dev` databases. papa's cluster on 5432 already has `spruce_goose_dev`
(used by the accountabot dashboard) and `coop_substrate_eventstore_dev`, so
`config/runtime.exs` lets a development deployment name its own databases
(`EVENTSTORE_*`, `SPRUCE_GOOSE_DATABASE_URL`, `TASK_HOST_DATABASE_URL`,
`TASK_HOST_SECRET_KEY_BASE`, `LOG_LEVEL`), each only when set.

## Build and install

```sh
MIX_ENV=dev mix release orchestration --overwrite
tar -C _build/dev/rel/orchestration -czf orchestration-dev.tar.gz .
scp orchestration-dev.tar.gz deploy/papa-operations-dev/*.sh papa:
ssh papa 'bash install-bizops-dev.sh orchestration-dev.tar.gz'
```

`install-bizops-dev.sh` is idempotent. It creates role `bizops_dev` and
databases `bizops_dev_{eventstore,task_host,spruce_goose}`, writes
`~/ops/bizops-dev/env` once (generated secrets, 0600), swaps the release
(the previous one stays in `release.old`), and (re)starts the unit, which
migrates before every start.

| Path on papa | Holds |
| --- | --- |
| `~/ops/bizops-dev/env` | settings and generated secrets (0600) |
| `~/ops/bizops-dev/keys/` | genesis governance, steward and checkpoint seeds (0600) |
| `~/ops/bizops-dev/operations.json` | `TASK_HOST_OPERATIONS_CONFIG` |
| `~/ops/bizops-dev/state/` | working directory, artifacts, `genesis_checkpoint.bin` |

## Bootstrap (done 2026-11-10)

Genesis ran once with the service stopped: governance `k-3141779e` for
`chapter-genesis`. Run commands that need the env file through
`systemd-run --user --wait --pipe -p EnvironmentFile=…`, not `. env`: bash
strips the quotes from `BIZKIT_IDENTITY_BINDINGS`.

## Use

```sh
ssh -L 4001:127.0.0.1:4001 papa      # then open http://127.0.0.1:4001/app
```

1. Sign in (provider `lars`), open a project (for example `chapter-genesis`
   / `household` / `home`) and request **administrator** access. The page
   shows a code.
2. On papa: `~/ops/bizops-dev/approve.sh CODE` shows the request; add
   `--yes` to sign it with the genesis governance key. This bootstrap is the
   only CLI approval: later devices and people are approved in the view.
3. Add the project to `~/ops/bizops-dev/operations.json` and
   `systemctl --user restart bizops-dev`, then use `/operations`.
