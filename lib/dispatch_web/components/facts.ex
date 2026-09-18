defmodule DispatchWeb.Components.Facts do
  @moduledoc """
  Rendering a fact with its provenance (Sections 1, 26.3).

  Section 26.3 requires the `fact_badge` component and states the rule it
  exists to enforce: "It is prohibited to render an ETA without
  `is_estimate=true` and `computed_at`."

  Section 1's whole architecture rests on four kinds of information staying
  distinct — a participant's declaration, an observed fact, an external notice,
  an AI inference. A value rendered without its source collapses them, and the
  reader cannot tell "the driver says they have arrived" from "a geofence
  suggests they have". Those carry different weight and different liability, so
  the badge is not decoration.

  The guard is in the component rather than in a review checklist because a
  checklist cannot fail a build.
  """

  use Phoenix.Component

  alias DispatchWeb.ViewModels.FactSummary

  attr :source, :atom,
    required: true,
    doc: "Section 1's kind: PARTICIPANT, OBSERVED, EXTERNAL, INFERRED"

  attr :occurred_at, DateTime, required: true
  attr :received_at, DateTime, default: nil
  attr :is_estimate, :boolean, default: false
  attr :computed_at, DateTime, default: nil
  attr :now, DateTime, default: nil

  @doc """
  Renders a fact's provenance and freshness.

  Raises when asked to render an estimate without `computed_at`. Section 26.3
  states that prohibition; a component that quietly rendered a blank instead
  would satisfy the letter and lose the reader exactly the information the rule
  is protecting.
  """
  @spec fact_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def fact_badge(assigns) do
    if assigns.is_estimate and is_nil(assigns.computed_at) do
      raise ArgumentError,
            "Section 26.3 prohibits rendering an estimate without computed_at"
    end

    now = assigns.now || DateTime.utc_now()

    assigns =
      assigns
      |> assign(:age_seconds, DateTime.diff(now, assigns.occurred_at, :second))
      |> assign(:freshness, freshness(DateTime.diff(now, assigns.occurred_at, :second)))

    ~H"""
    <span class="fact-badge" data-source={@source} data-freshness={@freshness}>
      <span class="fact-badge-source">{label(@source)}</span>
      <time datetime={DateTime.to_iso8601(@occurred_at)} class="fact-badge-occurred">
        {relative(@age_seconds)}
      </time>
      <span :if={@is_estimate} class="fact-badge-estimate">
        estimate, computed {relative(DateTime.diff(DateTime.utc_now(), @computed_at, :second))}
      </span>
    </span>
    """
  end

  attr :summary, FactSummary, required: true
  attr :now, DateTime, default: nil

  @doc "Renders a `FactSummary`, which already carries everything the badge needs."
  @spec summary_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def summary_badge(assigns) do
    ~H"""
    <.fact_badge
      source={@summary.source}
      occurred_at={@summary.occurred_at}
      received_at={@summary.received_at}
      is_estimate={@summary.is_estimate}
      computed_at={@summary.computed_at}
      now={@now}
    />
    """
  end

  # Section 26.6 fixes these thresholds for the map and they are display
  # thresholds, not priority — a stale location is not an urgent one.
  defp freshness(age_seconds) when age_seconds > 300, do: "stale"
  defp freshness(age_seconds) when age_seconds > 120, do: "aging"
  defp freshness(_age_seconds), do: "fresh"

  # Section 1's distinction, in words a dispatcher reads rather than a code.
  defp label(:PARTICIPANT), do: "declared"
  defp label(:OBSERVED), do: "observed"
  defp label(:EXTERNAL), do: "reported"
  defp label(:INFERRED), do: "inferred"

  defp relative(seconds) when seconds < 60, do: "just now"
  defp relative(seconds) when seconds < 3_600, do: "#{div(seconds, 60)} min ago"
  defp relative(seconds), do: "#{div(seconds, 3_600)} h ago"
end
