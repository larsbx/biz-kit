defmodule DispatchWeb.ViewModels.PartnerStopView do
  @moduledoc """
  What a shipper or receiver page may show about one stop (Sections 4.3, 26.5).

  ## A struct, not a filter

  Section 4.3 states what these pages must never expose: "the full driver
  timeline, continuous route trace, unrelated stops, negotiated rate, internal
  carrier notes, or other parties' communications." That could be implemented by
  loading the stop and its load and then leaving those fields out — and it would
  work, until someone adds a field to `Load` and the page grows it by default.

  So this struct has nowhere to put them. It has no `rate`, no `route`, no
  `timeline`, no sibling stop. A leak is then a compile error in a component
  that asks for a field, rather than a policy decision nobody revisits. Section
  26.5's "plain immutable view-model structs created from already-authorized Ash
  results" is doing real work here: the narrowing happens once, on the way in.

  What it does carry is the load *identifier* and nothing else from the load.
  The partner needs to know which shipment their stop belongs to; they do not
  need its commodity, its rate, or its other stops.

  ## Existence is itself information

  Acceptance criterion 19 requires that an unrelated load "returns no
  existence-bearing metadata", and `build/2` takes that literally: a stop in
  another tenant, a stop this partner is not party to, and a stop that does not
  exist all return `{:error, :not_found}`. Distinguishing them would answer a
  question the caller is not entitled to ask — and it is the distinction a
  careful implementation makes by accident, because "forbidden" feels more
  honest than "missing".

  The party relationship is re-read on every build rather than trusted from the
  role assignment's scope, so ending it takes effect on the next request
  (Section 33.2).
  """

  alias Dispatch.Access.{Actor, Party}
  alias Dispatch.Identity.PrincipalResolution
  alias Dispatch.Fleet.{Stop, DocumentReference, ReferenceCipher}
  alias Dispatch.Operations.StopReadinessEvent
  alias Dispatch.Communications.ActionProposal
  alias Dispatch.Access.Checks.PartnerScope
  alias DispatchWeb.ViewModels.FactSummary

  require Ash.Query

  @enforce_keys [:stop_id, :load_id, :kind, :address_text]
  defstruct [
    :stop_id,
    :load_id,
    :kind,
    :address_text,
    :window_start,
    :window_end,
    :contact_name,
    :readiness,
    :arrival_summary,
    :version,
    :latest_readiness_id,
    :readiness_summary,
    documents: [],
    proposals: [],
    can_report: false,
    can_reference: false,
    can_propose: false
  ]

  @type t :: %__MODULE__{
          stop_id: Ash.UUID.t(),
          load_id: Ash.UUID.t(),
          kind: :PICKUP | :DELIVERY,
          address_text: String.t(),
          window_start: DateTime.t() | nil,
          window_end: DateTime.t() | nil,
          contact_name: String.t() | nil,
          readiness: atom() | nil,
          arrival_summary: FactSummary.t() | nil
        }

  @doc """
  Builds the view for `stop_id`, or reports nothing.

  Returns `{:error, :not_found}` for every stop this actor may not see,
  whatever the reason — see the module documentation.
  """
  @spec build(Actor.t(), Ash.UUID.t()) :: {:ok, t()} | {:error, :not_found}
  def build(%Actor{} = actor, stop_id) when is_binary(stop_id) do
    with {:ok, actor} <- PrincipalResolution.revalidate(actor),
         {:ok, stop} <- fetch(actor, stop_id),
         true <- permitted?(actor, stop) do
      {:ok, from(stop, actor)}
    else
      _nothing_to_report -> {:error, :not_found}
    end
  end

  def build(_actor, _stop_id), do: {:error, :not_found}

  # Tenant-scoped, so a stop elsewhere is not found rather than refused. The
  # query is the same one either way, which is what keeps the two outcomes
  # indistinguishable without a branch that has to remember to be.
  defp fetch(actor, stop_id) do
    Stop
    |> Ash.Query.for_read(:partner)
    |> Ash.Query.filter(id == ^stop_id)
    |> Ash.read_one(actor: actor, tenant: actor.tenant_id)
    |> case do
      {:ok, %Stop{} = stop} -> {:ok, stop}
      _absent_or_refused -> :error
    end
  end

  # Section 22.2 requires a party row *in addition to* a role assignment, and
  # re-reading it here is what makes Section 33.2's "immediately" true: the
  # assignment's scope says which stop was granted, not whether the grant still
  # stands.

  # Three conditions, and `Party.permits?/4` is the one place that holds all
  # three together: the capability, the assignment's *scope* covering this stop,
  # and a live party row.
  #
  # An earlier version checked the capability and the party row by hand and left
  # the scope out. That reads as sufficient — a shipper organization party to
  # this stop, holding `stop.read` — and it is not. When the same organization
  # is party to two stops, being party stops distinguishing them and only the
  # scope does. Acceptance criterion 17 says a shipper sees its pickup stop and
  # not the delivery stop on the same load, which is exactly the case a
  # hand-rolled conjunction loses.
  defp permitted?(actor, stop) do
    # The resource's Ash policy has already constrained the read. This page
    # remains a stop-scoped surface; a broker uses its load view instead.
    actor.role_assignment.scope_type == :STOP and
      Party.permits?(actor.role_assignment, "stop.read", {:STOP, stop.id}, at: actor.at)
  end

  defp from(%Stop{} = stop, actor) do
    readiness =
      StopReadinessEvent
      |> Ash.Query.filter(stop_id == ^stop.id)
      |> Ash.Query.sort(occurred_at: :desc, recorded_at: :desc, id: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(actor: actor, tenant: actor.tenant_id)

    latest =
      StopReadinessEvent
      |> Ash.Query.filter(stop_id == ^stop.id)
      |> Ash.Query.sort(recorded_at: :desc, id: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(actor: actor, tenant: actor.tenant_id)

    writable = PartnerScope.stop_kind?(actor, stop)

    %__MODULE__{
      stop_id: stop.id,
      # The identifier only. Everything else about the load stays on the other
      # side of this boundary.
      load_id: stop.load_id,
      kind: stop.kind,
      address_text: stop.address_text,
      window_start: stop.window_start,
      window_end: stop.window_end,
      contact_name: stop.contact_name,
      version: stop.version,
      readiness: if(readiness, do: readiness.state),
      latest_readiness_id: if(latest, do: latest.id),
      readiness_summary:
        if(readiness,
          do:
            FactSummary.new(readiness.state, readiness.source, readiness.occurred_at,
              received_at: readiness.recorded_at
            )
        ),
      documents: documents(actor, stop.id),
      proposals: proposals(actor, stop),
      can_report: writable and Actor.can?(actor, "stop.update.readiness"),
      can_reference: writable and Actor.can?(actor, "document_reference.add"),
      can_propose:
        writable and Actor.can?(actor, "proposal.create") and
          (Actor.can?(actor, "appointment.propose") or Actor.can?(actor, "instruction.propose")),
      arrival_summary: nil
    }
  end

  def documents(actor, stop_id) do
    if Actor.can?(actor, "document_reference.read") do
      DocumentReference
      |> Ash.Query.filter(stop_id == ^stop_id)
      |> Ash.Query.sort(created_at: :desc)
      |> Ash.Query.limit(100)
      |> Ash.read!(actor: actor, tenant: actor.tenant_id)
      |> Enum.map(fn doc ->
        reference =
          case ReferenceCipher.decrypt(doc.object_reference_ciphertext) do
            {:ok, value} -> value
            _ -> "Reference unavailable"
          end

        %{
          id: doc.id,
          category: doc.category,
          label: doc.label,
          reference: reference,
          source: doc.source,
          occurred_at: doc.occurred_at,
          recorded_at: doc.recorded_at,
          scan_state: doc.scan_state
        }
      end)
    else
      []
    end
  end

  def proposals(actor, stop) do
    if Actor.can?(actor, "proposal.create") do
      ActionProposal
      |> Ash.Query.filter(stop_id == ^stop.id)
      |> Ash.Query.sort(recorded_at: :desc)
      |> Ash.Query.limit(100)
      |> Ash.read!(actor: actor, tenant: actor.tenant_id)
      |> Enum.map(fn proposal ->
        state =
          cond do
            DateTime.compare(proposal.expires_at, actor.at) != :gt -> :EXPIRED
            proposal.basis_version != stop.version -> :STALE
            true -> :PROPOSED
          end

        %{
          id: proposal.id,
          kind: proposal.kind,
          state: state,
          window_start: proposal.window_start,
          window_end: proposal.window_end,
          instructions: proposal.instructions,
          source: proposal.source,
          occurred_at: proposal.occurred_at,
          recorded_at: proposal.recorded_at,
          expires_at: proposal.expires_at,
          payload_sha256: proposal.payload_sha256
        }
      end)
    else
      []
    end
  end
end
