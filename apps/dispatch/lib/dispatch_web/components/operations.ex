defmodule DispatchWeb.Components.Operations do
  @moduledoc """
  The operations participant page (Sections 4.2, 4.3, 26.3).

  Fragment IDs come from Section 26.3's list, which calls them "public UI
  contracts": the same IDs appear in Datastar patches and Playwright tests, so
  renaming one is a change to three places at once.

  Every value arrives on `DispatchWeb.ViewModels.OperationsParticipantView`,
  which carries freshness rather than coordinates. There is no map shell here
  yet for that reason — Slice 2 owns consented location, and a map with nothing
  authorized to put in it would be a shell inviting someone to fill it.
  """

  use Phoenix.Component

  import DispatchWeb.Components.Facts

  attr :view, :any, required: true

  @doc "The participant page of Section 4.2."
  @spec participant_page(map()) :: Phoenix.LiveView.Rendered.t()
  def participant_page(assigns) do
    ~H"""
    <section id="participant-page">
      <header id="participant-header">
        <h1>{@view.public_name}</h1>
        <p class="participant-state">{@view.status}</p>
      </header>

      <section id="participant-status-card">
        <h2>Current status</h2>
        <p :if={@view.current_status}>
          <span class="status-value">{@view.current_status.value}</span>
          <.summary_badge summary={@view.current_status} />
        </p>
        <p :if={is_nil(@view.current_status)}>No status declared.</p>
      </section>

      <section id="participant-location-card">
        <h2>Location</h2>
        <p :if={@view.location_freshness}>
          Last reported <.summary_badge summary={@view.location_freshness} />
        </p>
        <!-- Section 23.2 makes precise location a separate capability that also
             requires active consent, so this card reports freshness only. -->
        <p :if={is_nil(@view.location_freshness)}>No location shared.</p>
      </section>
    </section>
    """
  end

  attr :view, :any, required: true

  @doc "The carrier-scoped operations overview of Sections 4.4 and 26.3."
  @spec operations_page(map()) :: Phoenix.LiveView.Rendered.t()
  def operations_page(assigns) do
    ~H"""
    <main id="operations-page">
      <h1>Operations</h1>
      <.operations_roster view={@view} />
    </main>
    """
  end

  attr :view, :any, required: true

  @doc "The independently patchable operations roster."
  @spec operations_roster(map()) :: Phoenix.LiveView.Rendered.t()
  def operations_roster(assigns) do
    ~H"""
    <section id="operations-roster" aria-live="polite">
      <h2>Operational participants</h2>
      <p :if={@view.participants == []}>No operational participants.</p>
      <ul :if={@view.participants != []}>
        <li
          :for={participant <- @view.participants}
          id={"operations-participant-#{participant.participant_id}"}
        >
          <a href={"/operations/participants/#{participant.participant_id}"}>
            {participant.public_name}
          </a>
          <span class="participant-state">{participant.status}</span>
          <span :if={participant.current_status} class="participant-current-status">
            {participant.current_status.value}
            <.summary_badge summary={participant.current_status} />
          </span>
        </li>
      </ul>
    </section>
    """
  end
end
