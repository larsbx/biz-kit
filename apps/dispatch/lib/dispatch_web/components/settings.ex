defmodule DispatchWeb.Components.Settings do
  @moduledoc """
  The administrator's people and roles page (Sections 4.3, 23.3).

  Every form carries the CSRF token (Section 26.4) and an idempotency key made
  when the page is drawn, so resubmitting the same form is one change. The
  page offers no one their own assignments to grant; the server refuses that
  regardless.
  """

  use Phoenix.Component

  attr :view, :map, required: true
  attr :actor, :any, required: true
  attr :message, :string, default: nil
  attr :step_up_seconds, :integer, required: true

  @doc "The organization's people, their roles, and the grant form."
  @spec users_page(map()) :: Phoenix.LiveView.Rendered.t()
  def users_page(assigns) do
    ~H"""
    <section id="settings-users">
      <h1>People and roles</h1>
      <p :if={@message} id="settings-message" role="alert">{@message}</p>
      <p class="settings-step-up">
        Role changes need a sign-in within the last {div(@step_up_seconds, 60)} minutes.
      </p>

      <ul id="settings-members">
        <li :for={member <- @view.members} id={"settings-member-#{member.participant.id}"}>
          <span class="member-name">{member.participant.public_name}</span>
          <ul class="member-assignments">
            <li
              :for={assignment <- member.assignments}
              id={"settings-assignment-#{assignment.id}"}
            >
              <span class="assignment-role">{assignment.role_definition.label}</span>
              <form method="post" action={"/settings/users/assignments/#{assignment.id}/revoke"}>
                <.form_keys />
                <input type="hidden" name="expected_version" value={assignment.version} />
                <button type="submit">Revoke</button>
              </form>
            </li>
          </ul>
        </li>
      </ul>

      <form id="settings-grant" method="post" action="/settings/users/assignments">
        <h2>Grant a role</h2>
        <.form_keys />
        <label for="participant_id">Person</label>
        <select id="participant_id" name="participant_id">
          <option
            :for={member <- @view.members}
            :if={member.participant.id != @actor.principal_id}
            value={member.participant.id}
          >
            {member.participant.public_name}
          </option>
        </select>
        <label for="role_definition_id">Role</label>
        <select id="role_definition_id" name="role_definition_id">
          <option :for={definition <- @view.grantable} value={definition.id}>
            {definition.label}
          </option>
        </select>
        <button type="submit">Grant</button>
      </form>
    </section>
    """
  end

  defp form_keys(assigns) do
    assigns =
      assign(assigns,
        csrf: Plug.CSRFProtection.get_csrf_token(),
        key: Ash.UUID.generate()
      )

    ~H"""
    <input type="hidden" name="_csrf_token" value={@csrf} />
    <input type="hidden" name="idempotency_key" value={@key} />
    """
  end
end
