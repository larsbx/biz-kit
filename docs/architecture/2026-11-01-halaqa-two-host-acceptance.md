# Halaqa relay and separate-host acceptance handoff

Date: 2026-11-01 (America/New_York).
Status: **Executable fixture runner; separate-host execution pending.**

The [delivery experiment](../../tools/halaqa_receipt_draft/README.md) now supports
a controlled HTTPS relay with normal certificate verification. Relay-only
endpoints have no direct-IP transports or bound UDP sockets. Success requires
Iroh's selected relay path, received stream frames and nonzero received bytes;
merely listing a relay URL cannot satisfy the test. Default direct tests remain
loopback-only. This is experimental operational custody, not production ingress,
canonical Halaqa admission, an ActivityPub gateway or a financial effect.

Seven relay/runner tests cover selected-path evidence, a mismatched CA, an
unconfigured endpoint, mixed direct/relay targets, outage/restart recovery and
the operator runner's one-host rehearsal with report-mutation controls. The
relay is allowlisted and its certificate chains to an explicit private CA.
Certificate verification remains enabled; no bypass is configured. Six Rust tests
and 51 Python checks pass locally. Hosted CI is separate evidence.

## Prerequisites and retained boundaries

Use two independently administered test hosts A and B, plus a controlled relay
reachable from both. No hosts or credentials have been configured or deployed
by this change. Run from clean checkouts of the same reviewed commit, with
Rust 1.99.1, Python 3.13, PostgreSQL 16 server/client binaries, Git and OpenSSL.
The exact Rust dependencies are locked. Each role creates and removes its own
disposable local PostgreSQL cluster; it never uses an existing user database.

Use only the supplied disclosed synthetic actor fixture. Its clock/revocation
values are TEST assertions, not current real-world governing evidence. Native
endpoint keys are newly generated private files, distinct from that actor key.
The runner's transport and storage adapters are test harnesses. Do not connect
them to business writers, real permissions, private records or production keys.

On each host, check out the same commit and build:

```sh
git status --short
cargo build --locked --manifest-path tools/halaqa_iroh_draft_rs/Cargo.toml
```

`serve` and `send` require `--revision` to equal the actual Git HEAD and refuse
changed/untracked files in their complete source inventory. Both reports carry
SHA-256 values for those sources; comparison also checks them against the
reviewing checkout. This detects revision/source drift, not privileged forgery.
`--local-rehearsal` explicitly bypasses the clean-head requirement and labels
its result unverified. CI uses that flag only for its one-host rehearsal.

## Identities and controlled relay

On A initialize the sender; on B initialize the receiver:

```sh
# Host A
python3 tools/check_halaqa_two_hosts.py init sender /tmp/halaqa-sender
# Host B
python3 tools/check_halaqa_two_hosts.py init receiver /tmp/halaqa-receiver
```

Exchange only each bundle's `public.json`. Keep `endpoint.key` on its owning
host; the new bundle directory is private and the key mode is 0600. The init
command refuses an existing directory. Each role checks that its own public
descriptor matches its private key and that the remote descriptor has the
opposite role and a distinct endpoint ID. Host labels are operator descriptions,
not endpoint pins or proof of separate hardware.

Configure an Iroh 1.4.1 HTTPS relay, allowlisting exactly the two endpoint IDs.
Supply the actual relay trust-root DER certificate to both hosts. The URL must
be an explicit HTTPS IP address with root path and no credentials, query or
fragment. Both roles must use the same URL. DNS publication, public relay
defaults and direct-IP fallback are not enabled.

The native fixture binary also provides `relay-server` for a controlled local
relay. Its first stdin line is the following JSON shape; paths are local files:

```json
{"cert_file":"/absolute/relay-leaf.der","key_file":"/absolute/relay-key-pkcs8.der","allowed_endpoints":["SENDER_ENDPOINT_ID","RECEIVER_ENDPOINT_ID"]}
```

Start the binary interactively with `relay-server`, supply that one-line config,
and keep stdin open. It reports its HTTPS URL and accepts `{"op":"stop"}` on
owned local stdin for cleanup. Its HTTP/captive-probe and HTTPS listeners bind
only loopback. The automated test certificate helper generates a private CA,
an IP-SAN leaf certificate and PKCS#8 key without disabling TLS verification.

For separate hosts, an operator can provide controlled TCP forwarding to that
loopback relay, preserving the same verified URL on both hosts, or use a
separately operated allowlisted relay with the correct IP-SAN certificate. The
fixture does not publish a public listener or provision forwarding. Relay
infrastructure uses HTTPS/WebSockets; the peers' application protocol uses
end-to-end Iroh QUIC and requires no application HTTPS endpoint.

## Execute receiver and sender roles

Assume the public descriptors and trusted CA DER have been placed locally at
the example paths. Replace the relay URL and labels with the actual test values.
Run the receiver on B first and leave it running while A sends:

```sh
HALAQA_PG_BIN=/usr/lib/postgresql/16/bin \
python3 tools/check_halaqa_two_hosts.py serve \
  --identity-dir /tmp/halaqa-receiver \
  --peer-public /tmp/sender-public.json \
  --relay-url https://127.0.0.1:4443/ --ca-file /tmp/relay-ca.der \
  --revision "$(git rev-parse HEAD)" --host-label host-B \
  --report /tmp/receiver-report.json --duration 120
```

After B prints `receiver_ready`, run on A:

```sh
HALAQA_PG_BIN=/usr/lib/postgresql/16/bin \
python3 tools/check_halaqa_two_hosts.py send \
  --identity-dir /tmp/halaqa-sender \
  --peer-public /tmp/receiver-public.json \
  --relay-url https://127.0.0.1:4443/ --ca-file /tmp/relay-ca.der \
  --revision "$(git rev-parse HEAD)" --host-label host-A \
  --report /tmp/sender-report.json
```

The receiver deliberately loses the first post-commit delivery reply, restarts
only its native sidecar with the original endpoint key, and changes its TEST
policy to expired/revoked. The sender must first observe `UNKNOWN`, then confirm
the original retained receipt using fresh status requests. It never changes the
message ID, re-signs the candidate or submits a second delivery. The receiver
retains its PostgreSQL cluster across that native restart.

Once A finishes, let B's duration finish or press Ctrl-C on B to export its
report and clean up owned processes. Do not use an ungraceful kill as the normal
report-export step. If the scenario fails, retain diagnostics; no successful
receipt or separate-host acceptance should be inferred.

## Compare evidence and record actual host provenance

Copy the two public reports to a clean reviewing checkout of that revision:

```sh
python3 tools/check_halaqa_two_hosts.py compare \
  --sender /tmp/sender-report.json --receiver /tmp/receiver-report.json \
  --revision "$(git rev-parse HEAD)"
```

Comparison requires cross-matching endpoint pins, revision and source hashes,
relay-only path evidence on both sides with zero IP sockets, the same original
wire/candidate hashes and receiver receipt, exactly one delivery, receiver
restart, sender unknown-to-confirmed recovery and false authority flags.
Changed revisions, endpoints, bytes or duplicate delivery counts are refused.

The result is deliberately
`PAIR_CONSISTENT_HOST_PROVENANCE_UNVERIFIED`, with
`separate_hosts_verified=false`. Different keys, processes, databases or labels
cannot prove different hosts. Record the actual host/administration provenance,
relay configuration, source revision, operator observations and path reports
with the acceptance review. This repository currently has a local rehearsal,
not that independently witnessed run. No remote attestation or hardware
power-loss/failover claim is made.

F3 still needs the actual independently administered execution and its retained
evidence. Production identity/revocation/disclosure sources, envelope refresh,
supervised Elixir adapters and domain admission remain separate F2/F4 obligations.
