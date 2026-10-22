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
        <p>
          {readiness_label(@view.readiness)}
          <.summary_badge :if={@view.readiness_summary} summary={@view.readiness_summary} />
        </p>
        <form
          :if={@view.can_report}
          id="partner-readiness-form"
          method="post"
          action={"/partner/stops/#{@view.stop_id}/readiness-events"}
        >
          <.form_context stop_id={@view.stop_id} version={@view.version} />
          <input type="hidden" name="expected_latest_id" value={@view.latest_readiness_id} />
          <label for="readiness-state">Readiness</label>
          <select id="readiness-state" name="state">
            <option :for={state <- ~w(NOT_READY READY CHECKED_IN BLOCKED)} value={state}>
              {readiness_label(state)}
            </option>
          </select>
          <label for="readiness-note">Note</label><textarea
            id="readiness-note"
            name="note"
            maxlength="2000"
          ></textarea>
          <button type="submit">Report readiness</button>
        </form>
      </section>

      <section id="partner-documents">
        <h2>Document and proof references</h2>
        <p>References only. Files have not been uploaded, scanned or verified here.</p>
        <ul>
          <li :for={doc <- @view.documents} id={"document-#{doc.id}"}>
            {doc.label}: <span class="document-reference">{doc.reference}</span>
            <.fact_badge
              source={doc.source}
              occurred_at={doc.occurred_at}
              received_at={doc.recorded_at}
            />
          </li>
        </ul>
        <form
          :if={@view.can_reference}
          id="partner-document-form"
          method="post"
          action={"/partner/stops/#{@view.stop_id}/document-references"}
        >
          <.form_context stop_id={@view.stop_id} version={@view.version} />
          <input
            type="hidden"
            name="category"
            value={if @view.kind == :DELIVERY, do: "PROOF_OF_DELIVERY", else: "PICKUP_DOCUMENT"}
          />
          <label for="document-label">Label</label><input
            id="document-label"
            name="label"
            required
            maxlength="200"
          />
          <label for="document-reference">Reference</label><input
            id="document-reference"
            name="reference"
            required
            maxlength="500"
          />
          <button type="submit">Add reference</button>
        </form>
      </section>
      <.proposals stop={@view} />

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

  attr :view, :any, required: true

  def load_page(assigns) do
    ~H"""
    <section id="partner-load-page">
      <h1>Contracted load {@view.external_reference}</h1>
      <section id="partner-load-status">
        <h2>Status</h2><p>{@view.status_summary.value}
          <.summary_badge summary={@view.status_summary} /></p>
      </section>
      <section id="partner-load-location">
        <h2>Location summary</h2><p>No authorized location summary available.</p>
      </section>
      <section id="partner-load-communications">
        <h2>Your communication threads</h2>
        <p :if={@view.communications == []}>No communication threads available.</p>
        <ul>
          <li :for={thread <- @view.communications} class="partner-thread">
            {thread.subject} — {thread.channel}, {thread.state}
            <.fact_badge source={thread.source} occurred_at={thread.occurred_at} />
          </li>
        </ul>
        <p>Message content and provider intake are not yet connected.</p>
      </section>
      <section :for={stop <- @view.stops} class="partner-load-stop">
        <h2>{kind_label(stop.kind)}</h2><p>{stop.address_text}</p>
        <p :if={stop.window_start}>
          Confirmed window: {format(stop.window_start)} – {format(stop.window_end)}
        </p>
        <.proposals stop={stop} />
      </section>
    </section>
    """
  end

  attr :stop, :any, required: true

  def proposals(assigns) do
    ~H"""
    <section id={"partner-proposals-#{@stop.stop_id}"} class="partner-proposals">
      <h2>Proposed changes</h2>
      <p>
        A proposal is not a confirmed appointment or instruction. Approval and execution are required before a commitment can change.
      </p>
      <ul>
        <li :for={proposal <- @stop.proposals} id={"proposal-#{proposal.id}"} class="partner-proposal">
          <strong>{proposal.state}</strong>
          — {proposal.kind}
          <span :if={proposal.window_start}>{format(proposal.window_start)} – {format(
            proposal.window_end
          )}</span>
          <span :if={proposal.instructions}>{proposal.instructions}</span>
          <.fact_badge
            source={proposal.source}
            occurred_at={proposal.occurred_at}
            received_at={proposal.recorded_at}
          />
          <span>Expires
          <time datetime={DateTime.to_iso8601(proposal.expires_at)}>{format(proposal.expires_at)}</time></span>
        </li>
      </ul>
      <form
        :if={@stop.can_propose}
        id={"partner-window-form-#{@stop.stop_id}"}
        class="partner-window-form"
        method="post"
        action={"/partner/stops/#{@stop.stop_id}/proposals"}
      >
        <.form_context stop_id={@stop.stop_id} version={@stop.version} />
        <input type="hidden" name="kind" value="APPOINTMENT" />
        <label>Proposed window start (UTC, ISO 8601)<input
          name="window_start"
          required
          placeholder="2026-10-23T09:00:00Z"
        /></label>
        <label>Proposed window end (UTC, ISO 8601)<input
          name="window_end"
          required
          placeholder="2026-10-23T10:00:00Z"
        /></label>
        <label>Proposal expires (UTC, within 24 hours)<input
          name="expires_at"
          required
          value={DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 3600))}
        /></label>
        <button type="submit">Propose window</button>
      </form>
      <form
        :if={@stop.can_propose}
        id={"partner-instruction-form-#{@stop.stop_id}"}
        class="partner-instruction-form"
        method="post"
        action={"/partner/stops/#{@stop.stop_id}/proposals"}
      >
        <.form_context stop_id={@stop.stop_id} version={@stop.version} />
        <input type="hidden" name="kind" value="INSTRUCTION" />
        <label>Proposed instructions<textarea name="instructions" required maxlength="2000"></textarea></label>
        <label>Proposal expires (UTC, within 24 hours)<input
          name="expires_at"
          required
          value={DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 3600))}
        /></label>
        <button type="submit">Propose instructions</button>
      </form>
    </section>
    """
  end

  attr :stop_id, :string, required: true
  attr :version, :integer, required: true

  def form_context(assigns) do
    ~H"""
    <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
    <input type="hidden" name="idempotency_key" value={Ash.UUID.generate()} />
    <input type="hidden" name="expected_version" value={@version} />
    """
  end

  # Section 22.2 permits three kinds. Handling two of them turns valid persisted
  # data into a 500 on a page a partner is entitled to see.
  defp kind_label(:PICKUP), do: "Pickup"
  defp kind_label(:DELIVERY), do: "Delivery"
  defp kind_label(:OTHER), do: "Stop"

  defp readiness_label(nil), do: "Not reported"
  defp readiness_label(state), do: state |> to_string() |> String.replace("_", " ")

  defp format(nil), do: "Not set"
  defp format(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
end
