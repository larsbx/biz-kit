defmodule DispatchWeb.SessionHTML do
  @moduledoc """
  Templates for sign-in and role selection (Sections 23.1, 4.3, 26.4).

  Every form carries the CSRF token Section 26.4 requires. `protect_from_forgery`
  only *checks* one, so a form without it fails for the legitimate user rather
  than for an attacker — which is how this requirement usually announces itself.
  """

  use Phoenix.Component

  attr :message, :string, default: nil

  @doc "The sign-in form."
  @spec login(map()) :: Phoenix.LiveView.Rendered.t()
  def login(assigns) do
    ~H"""
    <.document title="Sign in">
      <p :if={@message} role="alert">{@message}</p>
      <form method="post" action="/session">
        <.csrf_token />
        <label for="token">Access token</label>
        <input id="token" name="token" type="password" autocomplete="off" />
        <button type="submit">Sign in</button>
      </form>
    </.document>
    """
  end

  attr :assignments, :list, required: true
  attr :message, :string, default: nil

  @doc """
  The role/scope switcher of Section 4.3.

  Only assignments the principal holds are offered — and the server re-checks
  the submitted one regardless, because a form is a suggestion.
  """
  @spec select_role(map()) :: Phoenix.LiveView.Rendered.t()
  def select_role(assigns) do
    ~H"""
    <.document title="Select role">
      <p :if={@message} role="alert">{@message}</p>
      <form method="post" action="/select-role">
        <.csrf_token />
        <label for="role_assignment_id">Acting as</label>
        <select id="role_assignment_id" name="role_assignment_id">
          <option :for={assignment <- @assignments} value={assignment.id}>
            {assignment.label}
          </option>
        </select>
        <button type="submit">Continue</button>
      </form>
    </.document>
    """
  end

  attr :to, :string, required: true

  @doc "The body of a redirect, for clients that render one."
  @spec redirect(map()) :: Phoenix.LiveView.Rendered.t()
  def redirect(assigns) do
    ~H"""
    <.document title="Continue">
      <p><a href={@to}>Continue</a></p>
    </.document>
    """
  end

  attr :title, :string, required: true
  slot :inner_block, required: true

  defp document(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{@title}</title>
        <link rel="stylesheet" href="/static/css/app.css" />
      </head>
      <body>
        {render_slot(@inner_block)}
      </body>
    </html>
    """
  end

  defp csrf_token(assigns) do
    assigns = assign(assigns, :value, Plug.CSRFProtection.get_csrf_token())

    ~H"""
    <input type="hidden" name="_csrf_token" value={@value} />
    """
  end
end
