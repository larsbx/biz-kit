defmodule CoopSubstrate.Protocol.Validity do
  @moduledoc """
  Log-dependent validity (Phase 1B) — the realization of the 1A registry
  hook (09 gated-N): whether an envelope is acceptable can depend on prior
  log events. Checked at the append gate, before persistence, against the
  gate state (a `CoopSubstrate.Projections.Membership` fold of the log
  prefix, plus earlier events in the same batch), so illegal facts never
  enter the eternal log.

  Checks per type:

    * `EntityRegistered` — known class, id not already registered.
    * `MemberRegistered` — id not already registered; self-certifying: the
      declared `member`-role signer must be exactly the registered
      (pubkey, key_id).
    * Membership lifecycle events — member and entity registered; transition
      legal per `Membership.Lifecycle`; invited class matches the entity's;
      and every `member`-role signature must come from the member's
      *currently registered* key (steward keys have no registry yet — 1D).
    * `AccrualRuleActivated` — rule known to the code registry, params valid.
    * `PatronageRecorded` — active membership (PLACEHOLDER: probationary
      counts), an active accrual rule for the chapter, positive amount.
    * `RedemptionScheduleOpened` — membership in a terminal (redeemable)
      state; no schedule already open; positive years/cap; known method.
    * `RedemptionPaid` (7A) — schedule open; positive amount; amount within
      the remaining balance (the gate's own accrual fold — exit without
      forfeiture, never overdraw); `year_index` inside the schedule and the
      year's cumulative payments within `annual_cap_minor`.
    * `SinkingFundContributed` — entity registered; positive amount.
    * `NettingExecuted` (9A) — pair sorted and dual-signed; the cited
      report must EQUAL the recomputed `Finance.compute/3` set-off; the
      residual travels all-or-nothing and matches the net; zero set-off
      nets nothing. `ObligationRecorded`/`ObligationAssigned` additionally
      respect declared exposure caps (05 P7, bootstrap-then-enforce).
    * Dispatch rail (8A, docs/phase8a_plan.md) — `EnvelopeDeclared` only by
      the member's own current key, scope known, params exact, versions
      strictly monotonic; `EnvelopeRevoked` in any membership state;
      `TenderReceived` unique on an active membership; `TenderParsed`
      attests the exact raw artifact with a known grade and sane fields;
      `TenderAccepted`/`TenderDeclined` must EQUAL the recomputed pure
      decision (out-of-envelope and low-grade routes are unrepresentable —
      only the R rail's `EscalationRaised` carries them).
    * `ThroughputRuleActivated` / `FloorRuleActivated` (1C) — rule known to
      the code registry, params valid.
    * `ThroughputRecorded` (1C) — active membership; component in the closed
      set; positive units and occurred_ms; an active throughput rule.
    * `FloorEvaluationRecorded` (1C, tightened 10A) — membership exists, not
      in hardship (hardship suspends the floor); rule_id is the chapter's
      active floor rule; evaluation_id unique; sane window/instant/value.
    * Floor transitions (10A) — lifecycle legality first, then evidence:
      cure starts on a failing evaluation (its at_ms anchors the cure),
      clears on a passing one after the anchor, and `MembershipFloorExited`
      needs a failing evaluation at or beyond the declared
      `floor/cure_window_ms` (fails closed undeclared).
    * Obligation rail (1C, corpus 05 §1.2) — parties registered and distinct,
      signing with their *current* keys; obligation ids unique; assignment
      and discharge only on open obligations; discharge-once. No event
      represents fund movement (05 P11) — settlement is attestation only.
    * Role-key registry (1D) — bootstrap-then-enforce: once a chapter has
      ever declared keys for a role, every signature in that role must match
      a currently declared key (`check_role_keys/2`, runs before every
      per-type check). Genesis (the first governance key) is trust-on-first-
      use, self-certified; later declarations/revocations are governance-
      signed; revoking the last governance key is unrepresentable.
    * `KeyRotated` (1D) — self-rotation: for a REGISTERED member, the
      rotation must be signed by the member's current key and `old_key_id`
      must match it (rotations chain). Rotations for unregistered ids stay
      inert-and-ungated (1A compatibility; ChapterStats still records them).
      Governance-recovery rotation (lost key) is flagged open (08 §10.3).
      Everything else: no log-dependent constraints.
  """

  alias CoopSubstrate.Capital.AccrualRules
  alias CoopSubstrate.Constants
  alias CoopSubstrate.Dispatch
  alias CoopSubstrate.Finance
  alias CoopSubstrate.Floor
  alias CoopSubstrate.Membership.Lifecycle
  alias CoopSubstrate.Projections.Membership
  alias CoopSubstrate.Protocol.Envelope
  alias CoopSubstrate.Throughput

  @spec check(Envelope.t(), map()) :: :ok | {:error, term()}
  def check(%Envelope{} = env, gate) do
    with :ok <- CoopSubstrate.CommercialAdmission.fence(env, gate),
         :ok <- check_role_keys(env, gate) do
      type_check(env, gate)
    end
  end

  # Bootstrap-then-enforce (Phase 1D, docs/phase1d_plan.md P4): once a chapter
  # has EVER declared keys for a role, every signature in that role must match
  # a currently declared key. Roles never declared are unchecked (bootstrap
  # mode — the pre-1D behavior, now named). `member` is never in this
  # registry; member keys are checked against the member registry as before.
  defp check_role_keys(%Envelope{signers: signers, chapter_id: ch}, gate) do
    Enum.find_value(signers, :ok, fn signer ->
      case gate.role_keys[{ch, signer.role}] do
        nil ->
          nil

        keys ->
          unless Map.get(keys, signer.key_id) == signer.pubkey do
            {:error, {:role_key_not_declared, signer.role, signer.key_id}}
          end
      end
    end)
  end

  # -- Phase 1D: the role-key registry itself ----------------------------------

  # Every registered task type routes to the task gate; deriving the list from
  # the registration keeps a new type from being registered but left unchecked.
  @task_types Map.keys(TaskCore.Admission.event_types())
  @restaurant_types Map.keys(RestaurantCore.Admission.event_types())
  @dispatch_types Map.keys(DispatchCore.Admission.event_types())

  @group_buy_types Map.keys(CoopSubstrate.GroupBuys.event_types())
  @federation_types Map.keys(CoopSubstrate.FederationAuthority.event_types())
  @commercial_types Map.keys(CoopSubstrate.CommercialAdmission.event_types())
  @writer_fence_types Map.keys(CoopSubstrate.WriterFence.event_types())

  defp type_check(%Envelope{type: type} = env, gate) when type in @commercial_types do
    CoopSubstrate.CommercialAdmission.check(env, gate)
  end

  defp type_check(%Envelope{type: type} = env, gate) when type in @writer_fence_types do
    CoopSubstrate.WriterFence.check(env, gate)
