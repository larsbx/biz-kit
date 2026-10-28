defmodule DispatchWeb.SettingsHTML do
  @moduledoc "Templates for `/settings` (Section 4.3's ADMIN surface)."

  use Phoenix.Component

  alias DispatchWeb.Components.{Layouts, Settings}

  attr :view, :map, required: true
  attr :actor, :any, required: true
  attr :message, :string, default: nil
  attr :step_up_seconds, :integer, required: true

  @doc "People and role assignments."
  @spec users(map()) :: Phoenix.LiveView.Rendered.t()
  def users(assigns) do
    ~H"""
    <Layouts.root page_title="Users and roles" actor={@actor}>
      <Settings.users_page
        view={@view}
        actor={@actor}
        message={@message}
        step_up_seconds={@step_up_seconds}
      />
    </Layouts.root>
    """
  end
end
