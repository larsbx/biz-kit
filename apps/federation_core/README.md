# FederationCore

Portable, dependency-free **public marketplace federation contract**, not a
deployed ActivityPub server. `FederationCore.Marketplace` generates and parses
a deliberately small ActivityStreams profile for public advertisements.

A biz-kit installation is independently operated. Its own signed ledger
authorizes its own business facts. Another installation's remote public
announcement may become a cached discovery candidate, **never** a local
command, signed grant, reserved stock, completed service or payment proof.

The module has no HTTP routes, key storage, signature verification, networking,
delivery queue, discovery, purchase execution, moderation persistence or
database writer. `decode_verified/2` requires that the caller has already
verified the actor through an authenticated federation transport; it does NOT
perform that verification. Wire-level URL shape checks are NOT an SSRF defense.

Use the design decision in
[`docs/architecture/2026-10-24-federated-marketplace.md`](../../docs/architecture/2026-10-24-federated-marketplace.md)
before deploying this contract. Run `mix test` in this directory.
