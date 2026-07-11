defmodule CoopSubstrate.Protocol.TypeRegistry do
  @moduledoc """
  Minimal event-type registry for Phase 1A (phase1a_plan step 4).

  Per type: payload schema, required signer roles, stream assignment, and
  disclosure class (08 §5 — carried as data now, enforced by later phases).

  Type specs are pure data (no functions) so the registry can later be
  extended or gated by prior log events (09 gated-N) without rework:
  `validity_check/2` is that hook — it receives the envelope and a log
  reader and is a no-op in 1A.

  Bootstrap types only; everything else arrives with its phase. Extension
  types can be injected through the `:extra_event_types` application env
  (tests use this; production registration workflow is a later phase).
  """

  import Bitwise

  @type disclosure_class :: :commons | :telemetry | :edges | :bilateral

  # Field checkers: :string | :int | :bytes | :hash | :pubkey | :bool | :any
  # Stream spec: {:chapter_scoped, prefix} => "<chapter_id>/<prefix>"
  #              {:payload_field, prefix, field} => "<chapter_id>/<prefix>/<payload[field]>"
  #              {:payload_fields, prefix, fields} => "<chapter_id>/<prefix>/<f1>/<f2>/..."
  #
  # Signer roles on the 1B types are PLACEHOLDER governance semantics — who
  # MAY author each type is the Phase 1D validity workflow; the roles here fix
  # the signature-set shape only (docs/phase1b_plan.md).
  @membership_payload %{
    required: %{"member_id" => :string, "entity_id" => :string},
    optional: %{}
  }

  @builtin_types %{
    "TestProjectionEvent" => %{
      required_roles: ["author"],
      disclosure_class: :commons,
      stream: {:chapter_scoped, "test"},
      payload: %{
        required: %{"note" => :string, "amount_minor" => :int},
        optional: %{}
      }
    },
    "CorrectionRecorded" => %{
      required_roles: ["author"],
      disclosure_class: :commons,
      stream: {:chapter_scoped, "corrections"},
      payload: %{
        required: %{"target_event_hash" => :hash, "reason" => :string},
        optional: %{}
      }
    },
    "KeyRotated" => %{
      required_roles: ["author"],
      disclosure_class: :commons,
      stream: {:payload_field, "keys", "member_id"},
      payload: %{
        required: %{
          "member_id" => :string,
          "old_key_id" => :string,
          "new_key_id" => :string,
          "new_pubkey" => :pubkey
        },
        optional: %{}
      }
    },
    "CharterConstantDeclared" => %{
      required_roles: ["author"],
      disclosure_class: :commons,
      stream: {:chapter_scoped, "charter"},
      payload: %{
        required: %{"name" => :string, "value" => :any},
        optional: %{"note" => :string}
      }
    },

    # -- Phase 1B: identity & entities (hand-off §2.2) ------------------------
    "EntityRegistered" => %{
      required_roles: ["steward"],
      disclosure_class: :commons,
      stream: {:payload_field, "entities", "entity_id"},
      payload: %{
        required: %{"entity_id" => :string, "class" => :string},
        optional: %{"name" => :string}
      }
    },
    "MemberRegistered" => %{
      required_roles: ["member"],
      disclosure_class: :commons,
      stream: {:payload_field, "members", "member_id"},
      payload: %{
        required: %{"member_id" => :string, "pubkey" => :pubkey, "key_id" => :string},
        optional: %{}
      }
    },

    # -- Phase 1B: membership lifecycle (one event per transition; the legal
    # matrix lives in CoopSubstrate.Membership.Lifecycle and is enforced at
    # the append gate) ---------------------------------------------------------
    "MembershipInvited" => %{
      required_roles: ["steward"],
      disclosure_class: :commons,
      stream: {:payload_fields, "memberships", ["member_id", "entity_id"]},
      payload: %{
        required: %{"member_id" => :string, "entity_id" => :string, "class" => :string},
        optional: %{}
      }
    },
    "MembershipProbationStarted" => %{
      required_roles: ["member"],
      disclosure_class: :commons,
      stream: {:payload_fields, "memberships", ["member_id", "entity_id"]},
      payload: @membership_payload
    },
    "MembershipConfirmed" => %{
      # Dual-signed: the member and the entity steward sign the same core
      # (the 1A multi-role envelope, exercised by a production type).
      required_roles: ["member", "steward"],
      disclosure_class: :commons,
      stream: {:payload_fields, "memberships", ["member_id", "entity_id"]},
      payload: @membership_payload
    },
    "MembershipDeparted" => %{
      required_roles: ["member"],
      disclosure_class: :commons,
      stream: {:payload_fields, "memberships", ["member_id", "entity_id"]},
      payload: %{
        required: %{"member_id" => :string, "entity_id" => :string},
        optional: %{"reason" => :string}
      }
    },
    "MembershipRetired" => %{
      required_roles: ["member"],
      disclosure_class: :commons,
      stream: {:payload_fields, "memberships", ["member_id", "entity_id"]},
      payload: @membership_payload
    },
    "MembershipFloorExited" => %{
      # 1C computes the floor; representable now. evaluation_ref will point at
      # the floor-evaluation event once that exists.
      required_roles: ["steward"],
      disclosure_class: :commons,
      stream: {:payload_fields, "memberships", ["member_id", "entity_id"]},
      payload: %{
        required: %{"member_id" => :string, "entity_id" => :string},
        optional: %{"evaluation_ref" => :hash}
      }
    },
    "MembershipDeceased" => %{
      required_roles: ["steward"],
      disclosure_class: :commons,
      stream: {:payload_fields, "memberships", ["member_id", "entity_id"]},
      payload: %{
        required: %{"member_id" => :string, "entity_id" => :string},
        optional: %{"estate_ref" => :string}
      }
    },

    # -- Phase 1B: capital accounts (hand-off §2.3) ----------------------------
    "AccrualRuleActivated" => %{
      required_roles: ["steward"],
      disclosure_class: :commons,
      stream: {:chapter_scoped, "accrual_rules"},
      payload: %{
        required: %{"rule_id" => :string, "params" => :any},
        optional: %{"note" => :string}
      }
    },
    "PatronageRecorded" => %{
      required_roles: ["steward"],
      disclosure_class: :commons,
      stream: {:payload_fields, "patronage", ["member_id", "entity_id"]},
      payload: %{
        required: %{
          "member_id" => :string,
          "entity_id" => :string,
          "kind" => :string,
          "amount_minor" => :int
        },
        optional: %{"source_ref" => :hash}
      }
    },

    # -- Phase 1B: redemption structures (data now, workflow later) ------------
    "RedemptionScheduleOpened" => %{
      required_roles: ["steward"],
      disclosure_class: :commons,
      stream: {:payload_fields, "redemptions", ["member_id", "entity_id"]},
      payload: %{
        required: %{
          "member_id" => :string,
          "entity_id" => :string,
          "years" => :int,
          "annual_cap_minor" => :int,
          "method" => :string
        },
        optional: %{}
      }
    },
    "RedemptionPaid" => %{
      required_roles: ["steward"],
      disclosure_class: :commons,
      stream: {:payload_fields, "redemptions", ["member_id", "entity_id"]},
      payload: %{
        required: %{"member_id" => :string, "entity_id" => :string, "amount_minor" => :int},
        optional: %{"note" => :string}
      }
    },
    "SinkingFundContributed" => %{
      required_roles: ["steward"],
      disclosure_class: :commons,
      stream: {:payload_field, "sinking_fund", "entity_id"},
      payload: %{
        required: %{"entity_id" => :string, "amount_minor" => :int},
        optional: %{}
      }
    },

    # -- Phase 1C: floor lifecycle (transitions in Membership.Lifecycle,
    # enforced at the gate like every lifecycle event) -------------------------
    "FloorCureStarted" => %{
      required_roles: ["steward"],
      disclosure_class: :commons,
      stream: {:payload_fields, "memberships", ["member_id", "entity_id"]},
      payload: %{
        required: %{"member_id" => :string, "entity_id" => :string},
        optional: %{"evaluation_ref" => :hash}
      }
    },
    "FloorCureCleared" => %{
      required_roles: ["steward"],
      disclosure_class: :commons,
      stream: {:payload_fields, "memberships", ["member_id", "entity_id"]},
      payload: %{
        required: %{"member_id" => :string, "entity_id" => :string},
        optional: %{"evaluation_ref" => :hash}
      }
    },
    "HardshipDeclared" => %{
      required_roles: ["member"],
      disclosure_class: :commons,
      stream: {:payload_fields, "memberships", ["member_id", "entity_id"]},
      payload: @membership_payload
    },
    "HardshipEnded" => %{
      required_roles: ["member"],
      disclosure_class: :commons,
      stream: {:payload_fields, "memberships", ["member_id", "entity_id"]},
      payload: @membership_payload
    },

    # -- Phase 1C: throughput & floor compute (docs/phase1c_plan.md) -----------
    # ThroughputRecorded is the G0-claim carrier (08 §4): the `settlement`
    # component is NOT recordable here — it derives from obligation-rail
    # discharges. Component set + gate checks: Phase 1C step 4/5.
    "ThroughputRecorded" => %{
      required_roles: ["steward"],
      disclosure_class: :telemetry,
      stream: {:payload_fields, "throughput", ["member_id", "entity_id"]},
      payload: %{
        required: %{
          "member_id" => :string,
          "entity_id" => :string,
          "component" => :string,
          "units" => :int,
          "occurred_ms" => :int
        },
        optional: %{"source_ref" => :hash}
      }
    },
    "ThroughputRuleActivated" => %{
      required_roles: ["steward"],
      disclosure_class: :commons,
      stream: {:chapter_scoped, "throughput_rules"},
      payload: %{
        required: %{"rule_id" => :string, "params" => :any},
        optional: %{"note" => :string}
      }
    },
    "FloorRuleActivated" => %{
      required_roles: ["steward"],
      disclosure_class: :commons,
      stream: {:chapter_scoped, "floor_rules"},
      payload: %{
        required: %{"rule_id" => :string, "params" => :any},
        optional: %{"note" => :string}
      }
    },
    "FloorEvaluationRecorded" => %{
      required_roles: ["steward"],
      disclosure_class: :telemetry,
      stream: {:payload_fields, "floor", ["member_id", "entity_id"]},
      payload: %{
        required: %{
          "member_id" => :string,
          "entity_id" => :string,
          "cleared" => :bool,
          "rule_id" => :string,
          "window_ms" => :int,
          "value" => :int
        },
        optional: %{}
      }
    },

    # -- Phase 1C: the obligation-relationship rail (corpus 05 §1.2) -----------
    # Witnessed transaction relationships, NOT settlement: money movement
    # stays off-platform (05 P11 — no event type represents fund movement).
    # All three ride the obligation's own stream; every event is dual-signed
    # by the parties (signer-role semantics PLACEHOLDER like the 1B types;
    # key/party checks arrive with the step-4 gate).
    "ObligationRecorded" => %{
      required_roles: ["debtor", "creditor"],
      disclosure_class: :bilateral,
      stream: {:payload_field, "obligations", "obligation_id"},
      payload: %{
        required: %{
          "obligation_id" => :string,
          "debtor_id" => :string,
          "creditor_id" => :string,
          "amount_minor" => :int,
          "denomination" => :string
        },
        optional: %{}
      }
    },
    "ObligationAssigned" => %{
      required_roles: ["assignor", "assignee"],
      disclosure_class: :bilateral,
      stream: {:payload_field, "obligations", "obligation_id"},
      payload: %{
        required: %{"obligation_id" => :string, "new_debtor_id" => :string},
        optional: %{}
      }
    },
    "ObligationDischarged" => %{
      required_roles: ["debtor", "creditor"],
      disclosure_class: :bilateral,
      stream: {:payload_field, "obligations", "obligation_id"},
      payload: %{
        required: %{"obligation_id" => :string},
        optional: %{}
      }
    },

    # -- Phase 1D: role-key registry (docs/phase1d_plan.md; hand-off §4a).
    # Genesis (a chapter's first governance key) is trust-on-first-use,
    # self-certified; everything after is governance-signed. member_id is a
    # PLACEHOLDER binding of role → person (which member may act under a role
    # key is governance semantics, not enforced in 1D). ------------------------
    "RoleKeyDeclared" => %{
      required_roles: ["governance"],
      disclosure_class: :commons,
      stream: {:chapter_scoped, "governance"},
      payload: %{
        required: %{"role" => :string, "key_id" => :string, "pubkey" => :pubkey},
        optional: %{"member_id" => :string}
      }
    },
    "RoleKeyRevoked" => %{
      required_roles: ["governance"],
      disclosure_class: :commons,
      stream: {:chapter_scoped, "governance"},
      payload: %{
        required: %{"role" => :string, "key_id" => :string},
        optional: %{"reason" => :string}
      }
    },

    # -- Phase 2A: harness event substrate (docs/handoff_harness_d.md;
    # corpus 11). Interview content is the interviewee's data: consent is
    # the interviewee's own signature (self-certified, the MemberRegistered
    # pattern); revocation is terminal and its exclusion is computed by the
    # folds. Raw artifacts live OUTSIDE the log, hash-referenced. -------------
    "InterviewConsentGranted" => %{
      required_roles: ["interviewee"],
      disclosure_class: :bilateral,
      stream: {:payload_field, "consents", "interviewee_ref"},
      payload: %{
        required: %{
          "interviewee_ref" => :string,
          "pubkey" => :pubkey,
          "key_id" => :string,
          "classes" => :any,
          "recording" => :bool
        },
        optional: %{}
      }
    },
    "InterviewConsentRevoked" => %{
      required_roles: ["interviewee"],
      disclosure_class: :bilateral,
      stream: {:payload_field, "consents", "interviewee_ref"},
      payload: %{
        required: %{"interviewee_ref" => :string},
        optional: %{}
      }
    },
    "ResearchBriefFiled" => %{
      required_roles: ["steward"],
      disclosure_class: :commons,
      stream: {:payload_field, "harness", "section"},
      payload: %{
        required: %{"section" => :string, "artifact_hash" => :hash},
        optional: %{"citations" => :any}
      }
    },
    "InterviewConducted" => %{
      required_roles: ["steward"],
      disclosure_class: :bilateral,
      stream: {:payload_field, "interviews", "interview_id"},
      payload: %{
        required: %{
          "section" => :string,
          "interview_id" => :string,
          "interviewee_ref" => :string,
          "mode" => :string
        },
        optional: %{"instrument_version" => :int}
      }
    },
    "FindingExtracted" => %{
      # G2 by construction (attested practitioner experience, 08 §4) — no
      # grade field to forge; Corroborated promotes the claim to G3.
      required_roles: ["steward"],
      disclosure_class: :bilateral,
      stream: {:payload_field, "interviews", "interview_ref"},
      payload: %{
        required: %{
          "finding_id" => :string,
          "interview_ref" => :string,
          "kind" => :string,
          "body" => :string
        },
        optional: %{}
      }
    },
    "DocumentCollected" => %{
      required_roles: ["steward"],
      disclosure_class: :bilateral,
      stream: {:payload_field, "interviews", "interview_ref"},
      payload: %{
        required: %{
          "document_id" => :string,
          "interview_ref" => :string,
          "doc_kind" => :string,
          "artifact_hash" => :hash
        },
        optional: %{}
      }
    },
    "ConflictFlagged" => %{
      required_roles: ["steward"],
      disclosure_class: :commons,
      stream: {:payload_field, "claims", "claim_ref"},
      payload: %{
        required: %{"claim_ref" => :string, "finding_refs" => :any},
        optional: %{}
      }
    },
    "Corroborated" => %{
      required_roles: ["steward"],
      disclosure_class: :commons,
      stream: {:payload_field, "claims", "claim_ref"},
      payload: %{
        required: %{"claim_ref" => :string, "finding_refs" => :any},
        optional: %{}
      }
    },
    "InstrumentVersionPublished" => %{
      required_roles: ["steward"],
      disclosure_class: :commons,
      stream: {:payload_field, "harness", "section"},
      payload: %{
        required: %{"section" => :string, "version" => :int, "tree_hash" => :hash},
        optional: %{}
      }
    },
    "ProcessModelCompiled" => %{
      required_roles: ["steward"],
      disclosure_class: :commons,
      stream: {:payload_field, "harness", "section"},
      payload: %{
        required: %{"section" => :string, "artifact_hash" => :hash},
        optional: %{}
      }
    },
    "SpecAdopted" => %{
      # The section's ONE human signature (corpus 11 §1.4) — H2-shaped, so
      # governance-signed; the 1D registry enforces it post-bootstrap.
      required_roles: ["governance"],
      disclosure_class: :commons,
      stream: {:payload_field, "harness", "section"},
      payload: %{
        required: %{
          "section" => :string,
          "spec_hash" => :hash,
          "envelope_defaults_hash" => :hash
        },
        optional: %{}
      }
    },
    "FixtureSetPublished" => %{
      required_roles: ["steward"],
      disclosure_class: :commons,
      stream: {:payload_field, "harness", "section"},
      payload: %{
        required: %{"section" => :string, "fixture_hash" => :hash, "source_refs" => :any},
        optional: %{}
      }
    },
    "HonorariumAccrued" => %{
      # Representable now; the payout workflow is [LEGAL]-gated
      # (docs/handoff_harness_d.md §1).
      required_roles: ["steward"],
      disclosure_class: :bilateral,
      stream: {:payload_field, "consents", "interviewee_ref"},
      payload: %{
        required: %{"interviewee_ref" => :string, "amount_minor" => :int},
        optional: %{}
      }
    },
    "FrontierModelUseDeclared" => %{
      # 08 §7: bounded necessity with a DATED migration trigger, normative.
      required_roles: ["governance"],
      disclosure_class: :commons,
      stream: {:chapter_scoped, "governance"},
      payload: %{
        required: %{
          "purpose" => :string,
          "metric" => :string,
          "threshold" => :int,
          "date" => :string
        },
        optional: %{}
      }
    },
    "BuildStarted" => %{
      # The marker gate(section) protects: unrepresentable until the harness
      # gate is true (corpus 11 P6).
      required_roles: ["steward"],
      disclosure_class: :commons,
      stream: {:payload_field, "harness", "section"},
      payload: %{
        required: %{"section" => :string},
        optional: %{"ref" => :string}
      }
    }
  }

  @spec spec(String.t()) :: {:ok, map()} | {:error, :unknown_type}
  def spec(type) when is_binary(type) do
    case Map.fetch(all_types(), type) do
      {:ok, spec} -> {:ok, spec}
      :error -> {:error, :unknown_type}
    end
  end

  @spec registered?(String.t()) :: boolean()
  def registered?(type), do: match?({:ok, _}, spec(type))

  @spec types() :: [String.t()]
  def types, do: all_types() |> Map.keys() |> Enum.sort()

  @doc """
  Stream identity, derivable from `type` + `payload` + `chapter_id` alone
  (08 §1, 07 P7) — signers bind to the stream implicitly by signing the core.
  """
  @spec stream_id(String.t(), String.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def stream_id(type, chapter_id, payload) do
    with {:ok, spec} <- spec(type) do
      case spec.stream do
        {:chapter_scoped, prefix} ->
          {:ok, chapter_id <> "/" <> prefix}

        {:payload_field, prefix, field} ->
          case payload do
            %{^field => value} when is_binary(value) ->
              {:ok, chapter_id <> "/" <> prefix <> "/" <> value}

            _ ->
              {:error, {:stream_field_missing, field}}
          end

        {:payload_fields, prefix, fields} ->
          fields
          |> Enum.reduce_while({:ok, [prefix, chapter_id]}, fn field, {:ok, acc} ->
            case payload do
              %{^field => value} when is_binary(value) -> {:cont, {:ok, [value | acc]}}
              _ -> {:halt, {:error, {:stream_field_missing, field}}}
            end
          end)
          |> case do
            {:ok, parts} -> {:ok, parts |> Enum.reverse() |> Enum.join("/")}
            error -> error
          end
      end
    end
  end

  @doc "Every required field present and typed; unknown fields rejected (§1.3)."
  @spec validate_payload(String.t(), term()) :: :ok | {:error, term()}
  def validate_payload(type, payload) do
    with {:ok, spec} <- spec(type) do
      %{required: required, optional: optional} = spec.payload

      cond do
        not is_map(payload) ->
          {:error, {:payload_invalid, :not_a_map}}

        (missing = Map.keys(required) -- Map.keys(payload)) != [] ->
          {:error, {:payload_invalid, {:missing_fields, Enum.sort(missing)}}}

        (unknown = Map.keys(payload) -- (Map.keys(required) ++ Map.keys(optional))) != [] ->
          {:error, {:payload_invalid, {:unknown_fields, Enum.sort(unknown)}}}

        true ->
          checkers = Map.merge(optional, required)

          Enum.find_value(payload, :ok, fn {field, value} ->
            unless field_valid?(Map.fetch!(checkers, field), value) do
              {:error, {:payload_invalid, {:bad_field, field}}}
            end
          end)
      end
    end
  end

  @doc """
  Hook for log-dependent validity (09 gated-N): a type's acceptance may
  depend on prior log events. Realized in Phase 1B by
  `CoopSubstrate.Protocol.Validity`, checked against the append gate's fold
  state (`CoopSubstrate.Projections.Membership`).
  """
  @spec validity_check(struct(), term()) :: :ok | {:error, term()}
  defdelegate validity_check(envelope, gate), to: CoopSubstrate.Protocol.Validity, as: :check

  defp field_valid?(:string, v), do: is_binary(v) and String.valid?(v)

  defp field_valid?(:int, v),
    do: is_integer(v) and v >= -(1 <<< 63) and v < 1 <<< 63

  defp field_valid?(:bytes, v), do: match?({:bytes, b} when is_binary(b), v)
  defp field_valid?(:hash, v), do: match?({:bytes, <<_::256>>}, v)
  defp field_valid?(:pubkey, v), do: match?({:bytes, <<_::256>>}, v)
  defp field_valid?(:bool, v), do: is_boolean(v)
  defp field_valid?(:any, _v), do: true

  defp all_types do
    Map.merge(@builtin_types, Application.get_env(:coop_substrate, :extra_event_types, %{}))
  end
end
