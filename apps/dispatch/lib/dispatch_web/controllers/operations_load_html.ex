defmodule DispatchWeb.OperationsLoadHTML do
  @moduledoc "A read-only operator load page with no inferred progress or mutations."

  use Phoenix.Component

  alias DispatchWeb.Components.Layouts

  attr :actor, :any, required: true
  attr :view, :map, required: true

  def show(assigns) do
    ~H"""
    <Layouts.root page_title="Load" actor={@actor}>
      <section id="operations-load">
        <h1>Load {@view.load.external_reference || @view.load.ref.id}</h1>
        <p>Status: {@view.load.status} · Version {@view.load.version}</p>
        <p :if={@view.load.commodity_text}>{@view.load.commodity_text}</p>
        <p>Next stop is unknown: stop progression has not been recorded.</p>
        <h2>Ordered planned stops</h2>
        <p :if={!@view.stop_coverage.complete}>
          Showing {@view.stop_coverage.returned} of {@view.stop_coverage.total} stops.
        </p>
        <ol>
          <li :for={stop <- @view.stops} id={"stop-#{stop.ref.id}"}>
            <strong>{stop.sequence}. {stop.kind}</strong>
            — {stop.address_text}
            <p :if={stop.window_start || stop.window_end}>
              Window: {stop.window_start || "Unspecified"} to {stop.window_end || "Unspecified"}
            </p>
            <p :if={stop.position_status == "unresolved"}>Location is unresolved.</p>
          </li>
        </ol>
        <h2>Assignments</h2>
        <ul>
          <li :for={assignment <- @view.assignments}>
            {assignment.ref.id} — {assignment.status} · Version {assignment.version}
          </li>
        </ul>
        <p><a href="/operations">Back to operations</a></p>
      </section>
    </Layouts.root>
    """
  end
end
