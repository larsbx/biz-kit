defmodule DispatchWeb.FleetMapHTML do
  @moduledoc "The fleet globe's document, without the standalone GEV application."

  use Phoenix.Component

  attr :actor, :any, required: true

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
          <section id="dispatch-map" aria-labelledby="dispatch-map-title">
            <h1 id="dispatch-map-title">Dispatch map</h1>
            <p id="dispatch-map-status" role="status" aria-live="polite">Connecting…</p>
            <button id="dispatch-map-fit" type="button">Fit locations</button>
            <div id="dispatch-map-globe" aria-label="Observed participant locations"></div>
            <div id="dispatch-map-credits"></div>
            <ul id="dispatch-map-participants" aria-label="Participants"></ul>
          </section>
          <noscript>Enable JavaScript to view shared locations.</noscript>
        </main>
      </body>
    </html>
    """
  end
end
