defmodule CoopSubstrate.Dispatch do
  @moduledoc """
  The tender-accept decision (Phase 8A, docs/phase8a_plan.md; corpus 10
  §0–§5): a pure function of the carrier's declared envelope and the
  latest graded parse. The append gate recomputes it on every
  `TenderAccepted`/`TenderDeclined` — a decision event that disagrees with
  the function is unrepresentable, so "out-of-envelope never acts" and
  "low-grade demotes to R" are structure, not policy.

  Decision table (scope `tender_accept`; envelope params: `lanes`,
  `equipment`, `rate_floor_minor`):

    * no active envelope, or a parse graded `"machine"` (08 §7: parses are
      never authoritative) → `{:escalate, reason}` — only the 5A R rail
      (`EscalationRaised`) may carry it forward;
    * lane and equipment inside the envelope, rate ≥ floor → accept;
    * lane and equipment inside the envelope, rate < floor → decline (the
      declared floor IS the carrier's declared answer);
    * anything outside the declared lanes/equipment → escalate.
  """

  alias CoopSubstrate.Log
  alias CoopSubstrate.Projections.Membership

  @doc """
  The pure decision: `envelope` is the projection's envelope record
  (`%{version, params, active}` or nil), `parse` the projection's latest
  parse record (`%{grade, fields}` or nil).

  Returns `{:accept, version, basis}` | `{:decline, version, basis}` |
  `{:escalate, reason}`.
  """
  def decide(envelope, parse)

  def decide(nil, _parse), do: {:escalate, :no_envelope}
  def decide(%{active: false}, _parse), do: {:escalate, :no_envelope}
  def decide(_envelope, nil), do: {:escalate, :no_parse}
  def decide(_envelope, %{grade: grade}) when grade != "human", do: {:escalate, :low_grade_parse}

  def decide(%{version: version, params: params}, %{fields: fields}) do
    cond do
      fields["lane"] not in params["lanes"] ->
        {:escalate, {:out_of_envelope, :lane}}

      fields["equipment"] not in params["equipment"] ->
        {:escalate, {:out_of_envelope, :equipment}}

      fields["rate_minor"] >= params["rate_floor_minor"] ->
        {:accept, version, "in-envelope lane and equipment, rate at or above declared floor"}

      true ->
        {:decline, version, "in-envelope lane and equipment, rate below declared floor"}
    end
  end

  @doc "The decision for a received tender, recomputed from the log."
  def route(chapter_id, tender_id) do
    with {:ok, state} <- Log.replay(Membership) do
      case state.tenders[{chapter_id, tender_id}] do
        nil ->
          {:error, {:unknown_tender, tender_id}}

        tender ->
          envelope =
            Membership.dispatch_envelope(
              state,
              chapter_id,
              tender.member_id,
              tender.entity_id,
              "tender_accept"
            )

          {:ok, decide(envelope, tender.parse)}
      end
    end
  end
end
