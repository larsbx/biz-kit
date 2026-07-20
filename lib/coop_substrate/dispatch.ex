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

  @doc """
  Per-stop tracking times and dwell minutes for a load (8B), purely from
  the log — no clock reads; every time is a signed payload's.
  """
  def dwell(chapter_id, load_id) do
    with {:ok, state} <- Log.replay(Membership) do
      case state.loads[{chapter_id, load_id}] do
        nil ->
          {:error, {:unknown_load, load_id}}

        load ->
          {:ok,
           Map.new(load.stops, fn {stop, times} ->
             {stop, Map.put(times, :dwell_minutes, dwell_minutes(times))}
           end)}
      end
    end
  end

  defp dwell_minutes(%{arrived_ms: arrived, departed_ms: departed}),
    do: div(departed - arrived, 60_000)

  defp dwell_minutes(_incomplete), do: nil

  @doc """
  The invoice as a pure function of custody events + declared terms (8C;
  07 §6): linehaul from the accepted tender's parse, one detention line
  per stop from `max(0, departed − max(arrived, appointment) − free_time)`
  at the declared rate, under the member's current terms version. The
  append gate recomputes this on `InvoiceIssued` — a differing invoice is
  unrepresentable.
  """
  def compute_invoice(chapter_id, load_id) do
    with {:ok, state} <- Log.replay(Membership) do
      invoice_for(state, chapter_id, load_id)
    end
  end

  @doc "The pure core of `compute_invoice/2`, over caller-supplied fold state."
  def invoice_for(state, chapter_id, load_id) do
    with {:ok, load} <- fetch_load(state, chapter_id, load_id),
         :ok <- complete?(load),
         {:ok, terms} <- fetch_terms(state, chapter_id, load) do
      params = terms.versions[terms.current]
      tender = state.tenders[{chapter_id, load.tender_id}]
      linehaul = tender.parse.fields["rate_minor"]

      detention =
        for stop <- ["pickup", "delivery"],
            times = load.stops[stop],
            minutes = detention_minutes(times, params["free_time_minutes"]),
            minutes > 0 do
          %{
            "kind" => "detention",
            "stop" => stop,
            "minutes" => minutes,
            "amount_minor" => div(minutes * params["detention_rate_minor_per_hour"], 60)
          }
        end

      lines = [%{"kind" => "linehaul", "amount_minor" => linehaul} | detention]

      {:ok,
       %{
         terms_version: terms.current,
         lines: lines,
         amount_minor: lines |> Enum.map(& &1["amount_minor"]) |> Enum.sum()
       }}
    end
  end

  defp fetch_load(state, chapter_id, load_id) do
    case state.loads[{chapter_id, load_id}] do
      nil -> {:error, {:unknown_load, load_id}}
      load -> {:ok, load}
    end
  end

  defp complete?(load) do
    if Enum.all?(["pickup", "delivery"], &Map.has_key?(load.stops[&1] || %{}, :departed_ms)) do
      :ok
    else
      {:error, :load_incomplete}
    end
  end

  defp fetch_terms(state, chapter_id, load) do
    case state.rate_terms[{chapter_id, load.member_id, load.entity_id}] do
      nil -> {:error, :no_rate_terms}
      terms -> {:ok, terms}
    end
  end

  defp detention_minutes(times, free_minutes) do
    start = max(times.arrived_ms, Map.get(times, :appointment_ms, times.arrived_ms))
    max(0, div(times.departed_ms - start, 60_000) - free_minutes)
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
