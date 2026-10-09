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
  alias Dispatch.Fleet.Stop
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
    :arrival_summary
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
      {:ok, from(stop)}
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
    Party.permits?(actor.role_assignment, "stop.read", {:STOP, stop.id}, at: actor.at)
  end

  defp from(%Stop{} = stop) do
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
      readiness: nil,
      arrival_summary: nil
    }
  end
end
