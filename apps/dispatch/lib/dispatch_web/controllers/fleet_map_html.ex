defmodule DispatchWeb.FleetMapHTML do
  @moduledoc "The fleet globe's document, without the standalone GEV application."

  use Phoenix.Component

  attr :actor, :any, required: true
  attr :scope_key, :string, required: true

  def index(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Dispatch map</title>
        <link rel="stylesheet" href="/static/vendor/cesium/Widgets/widgets.css" />
        <link rel="stylesheet" href="/static/css/dispatch-map.css" />
        <script type="module" src="/static/js/maps/dispatch-map.js">
        </script>
      </head>
      <body>
        <header>
          <nav aria-label="Primary">
            <a href="/operations">Dispatch</a>
            <span>{@actor.role_assignment.role_definition.label}</span>
            <a href="/select-role">Switch role</a>
          </nav>
        </header>
        <main>
          <section id="dispatch-map" data-scope-key={@scope_key} aria-labelledby="dispatch-map-title">
            <h1 id="dispatch-map-title">Dispatch map</h1>
            <p id="dispatch-map-status" role="status" aria-live="polite">Connecting…</p>
            <div class="dispatch-map-controls">
              <button id="dispatch-map-fit" type="button">Fit locations</button>
              <label>
                Filter participants
                <input id="dispatch-map-filter" type="search" maxlength="120" autocomplete="off" />
              </label>
              <label>
                Location filter
                <select id="dispatch-map-location-filter">
                  <option value="all">All participants</option>
                  <option value="observed">Visible observations</option>
                  <option value="missing">No visible observation</option>
                  <option value="stale">Stale observations</option>
                </select>
              </label>
            </div>
            <p id="dispatch-map-coverage" role="status" aria-live="polite"></p>
            <form id="dispatch-map-search-form" class="dispatch-map-controls">
              <label>
                Go to coordinates
                <input
                  id="dispatch-map-search"
                  type="text"
                  maxlength="160"
                  autocomplete="off"
                  placeholder="Latitude, longitude or geo: URI"
                  aria-describedby="dispatch-map-search-status"
                />
              </label>
              <button type="submit">Go</button>
            </form>
            <p id="dispatch-map-search-status" role="status" aria-live="polite">
              Coordinate search runs locally. Place-name search is not configured.
            </p>
            <div id="dispatch-map-globe" aria-label="Observed participant locations"></div>
            <div id="dispatch-map-credits"></div>
            <section id="dispatch-map-selection" aria-labelledby="dispatch-map-selection-title" hidden>
              <h2 id="dispatch-map-selection-title">Selected observation</h2>
              <p id="dispatch-map-selected-name"></p>
              <p id="dispatch-map-selected-observation"></p>
              <p id="dispatch-map-selected-position"></p>
              <p id="dispatch-map-selected-source"></p>
              <div class="dispatch-map-controls">
                <a id="dispatch-map-selected-record">Open participant record</a>
                <button id="dispatch-map-follow" type="button" aria-pressed="false">Follow observation</button>
                <button id="dispatch-map-clear" type="button">Clear selection</button>
              </div>
              <h3>Work linked to this observation</h3>
              <p id="dispatch-map-work-status" role="status" aria-live="polite"></p>
              <div id="dispatch-map-work"></div>
            </section>
            <ul id="dispatch-map-participants" aria-label="Participants"></ul>
          </section>
          <noscript>Enable JavaScript to view shared locations.</noscript>
        </main>
      </body>
    </html>
    """
  end
end
