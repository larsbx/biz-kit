defmodule DispatchWeb.Components.Partner do
  @moduledoc """
  The shipper and receiver stop page (Sections 4.3, 26.3).

  Every value here comes from `DispatchWeb.ViewModels.PartnerStopView`, which
  has no field for the things Section 4.3 forbids. Section 26.5 prohibits a
  component from running an Ash query or reaching a raw schema, and this one
  could not usefully do so anyway: there is nothing in scope but the view model.

  That is the point of the arrangement. A component cannot leak what it was
  never handed.
  """

  use Phoenix.Component

  import DispatchWeb.Components.Facts

  attr :view, :any, required: true

  @doc "The partner stop page. Fragment IDs are the public contract of Section 26.3."
  @spec stop_page(map()) :: Phoenix.LiveView.Rendered.t()
  def stop_page(assigns) do
    ~H"""
    <section id="partner-stop-page">
      <h1>{kind_label(@view.kind)}</h1>

      <section id="partner-stop-card">
        <h2>Location</h2>
        <p class="stop-address">{@view.address_text}</p>
        <p :if={@view.contact_name} class="stop-contact">{@view.contact_name}</p>
      </section>

      <section id="partner-stop-window">
        <h2>Appointment window</h2>
        <p :if={@view.window_start}>
          <time datetime={DateTime.to_iso8601(@view.window_start)}>
            {format(@view.window_start)}
          </time>
          <span :if={@view.window_end}>
            &ndash;
            <time datetime={DateTime.to_iso8601(@view.window_end)}>{format(@view.window_end)}</time>
          </span>
        </p>
        <p :if={is_nil(@view.window_start)}>No window set.</p>
      </section>

      <section id="partner-stop-readiness">
        <h2>Readiness</h2>
        <p>{readiness_label(@view.readiness)}</p>
      </section>

      <section :if={@view.arrival_summary} id="partner-stop-arrival">
        <h2>Arrival</h2>
        <p>
          {@view.arrival_summary.value}
          <.summary_badge summary={@view.arrival_summary} />
        </p>
      </section>
    </section>
    """
  end

  defp kind_label(:PICKUP), do: "Pickup"
  defp kind_label(:DELIVERY), do: "Delivery"

  defp readiness_label(nil), do: "Not reported"
  defp readiness_label(state), do: state |> to_string() |> String.replace("_", " ")

  defp format(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
end
