defmodule DispatchWeb.Components.Layouts do
  @moduledoc """
  The portal's root document (Sections 26.1, 26.3).

  Section 26.1 pins the Datastar bundle to this origin — `scripts/check-invariants.sh`
  fails a CDN reference — and prohibits inline scripts, which is why the CSP
  below names no `unsafe-inline`.

  Section 4.3 puts the role switcher here rather than on each page: a user
  holding several assignments acts under exactly one, and the switcher is how
  they say which. Changing it reloads authorized server-rendered state; it does
  not merge anything client-side, because there is nothing client-side to merge.
  """

  use Phoenix.Component

  attr :page_title, :string, required: true
  attr :actor, :any, required: true
  attr :assignments, :list, default: []
  slot :inner_block, required: true

  @doc "The complete accessible document Section 24.5 requires of a navigation response."
  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{@page_title}</title>
        <!-- Section 26.1: self-hosted, never a CDN. -->
        <script type="module" src="/static/vendor/datastar.js">
        </script>
        <link rel="stylesheet" href="/static/css/app.css" />
      </head>
      <body>
        <header id="portal-header">
          <nav aria-label="Primary">
            <span class="portal-role">{role_label(@actor)}</span>
            <.role_switcher actor={@actor} assignments={@assignments} />
          </nav>
        </header>
        <main>
          {render_slot(@inner_block)}
        </main>
        <div id="portal-toast-region" role="status" aria-live="polite"></div>
      </body>
    </html>
    """
  end

  attr :actor, :any, required: true
  attr :assignments, :list, required: true

  @doc """
  The explicit role/scope switcher of Section 4.3.

  Rendered only when there is a choice to make. A switcher offering one option
  is not a choice, and presenting it as one implies the user's authority is
  broader than it is.
  """
  @spec role_switcher(map()) :: Phoenix.LiveView.Rendered.t()
  def role_switcher(assigns) do
    ~H"""
    <form :if={length(@assignments) > 1} id="portal-role-switcher" method="post" action="/select-role">
      <!-- Section 26.4: every action form carries CSRF protection. -->
      <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
      <label for="role-assignment">Acting as</label>
      <select id="role-assignment" name="role_assignment_id">
        <option
          :for={assignment <- @assignments}
          value={assignment.id}
          selected={assignment.id == @actor.role_assignment.id}
        >
          {assignment.label}
        </option>
      </select>
      <button type="submit">Switch</button>
    </form>
    """
  end

  defp role_label(actor), do: actor.role_assignment.role_definition.label
end
