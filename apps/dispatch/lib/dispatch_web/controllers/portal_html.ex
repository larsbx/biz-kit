defmodule DispatchWeb.PortalHTML do
  @moduledoc """
  Templates for the role-scoped portal pages (Section 26.5).

  A rendered template rather than a string built in the controller. The
  difference is not style: HEEx escapes interpolated values by construction,
  and a controller concatenating HTML has to remember to. Section 26.5 keeps
  escaping enabled and permits `raw/1` only for reviewed repository-owned SVG,
  which is a rule that only means something if there is no second path that
  quietly bypasses it.
  """

  use Phoenix.Component

  alias DispatchWeb.Components.{Layouts, Operations, Partner}

  attr :view, :any, required: true
  attr :actor, :any, required: true
  attr :assignments, :list, default: []

  @doc "The carrier-scoped operations overview."
  @spec operations(map()) :: Phoenix.LiveView.Rendered.t()
  def operations(assigns) do
    ~H"""
    <Layouts.root page_title="Operations" actor={@actor} assignments={@assignments}>
      <Operations.operations_page view={@view} />
    </Layouts.root>
    """
  end

  attr :view, :any, required: true
  attr :actor, :any, required: true
  attr :assignments, :list, default: []

  @doc "A shipper's or receiver's stop page."
  @spec partner_stop(map()) :: Phoenix.LiveView.Rendered.t()
  def partner_stop(assigns) do
    ~H"""
    <Layouts.root page_title="Stop" actor={@actor} assignments={@assignments}>
      <Partner.stop_page view={@view} />
    </Layouts.root>
    """
  end

  attr :view, :any, required: true
  attr :actor, :any, required: true
  attr :assignments, :list, default: []

  @doc "An operations participant page."
  @spec operations_participant(map()) :: Phoenix.LiveView.Rendered.t()
  def operations_participant(assigns) do
    ~H"""
    <Layouts.root page_title="Participant" actor={@actor} assignments={@assignments}>
      <Operations.participant_page view={@view} />
    </Layouts.root>
    """
  end

  @doc """
  The response for anything this actor may not see.

  Deliberately says nothing beyond that. Acceptance criterion 19 requires an
  unrelated subject to bear no existence-bearing metadata, and a message naming
  what was asked for is exactly that metadata.
  """
  @spec not_found(map()) :: Phoenix.LiveView.Rendered.t()
  def not_found(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <title>Not found</title>
      </head>
      <body>
        <h1>Not found</h1>
      </body>
    </html>
    """
  end
end
