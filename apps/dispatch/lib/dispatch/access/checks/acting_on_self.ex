defmodule Dispatch.Access.Checks.ActingOnSelf do
  @moduledoc """
  Passes when the record concerns the acting participant.

  Section 23.2 attaches the `self_only` constraint to every capability in the
  `DRIVER` bundle, and Section 5.2 permits only `source=PARTICIPANT` with
  `status.declare.self` to update the displayed self-declared status. A
  capability check alone would let any holder declare a status about anyone;
  this is what makes it a declaration about oneself.

  Reads the participant from a configurable field, since the column is
  `participant_id` on a status event but `operator_participant_id` on an
  assignment.
  """

  use Ash.Policy.SimpleCheck

  alias Dispatch.Access.Actor

  @doc "Builds the check for the field naming the subject participant."
  @spec on(atom()) :: {module(), keyword()}
  def on(field) when is_atom(field), do: {__MODULE__, field: field}

  @impl Ash.Policy.Check
  def describe(opts), do: "#{opts[:field]} is the acting participant"

  @impl Ash.Policy.SimpleCheck
  def match?(%Actor{} = actor, %{changeset: %Ash.Changeset{} = changeset}, opts) do
    field = Keyword.fetch!(opts, :field)
    Actor.self?(actor, Ash.Changeset.get_attribute(changeset, field))
  end

  def match?(%Actor{} = actor, %{subject: %Ash.Changeset{} = changeset}, opts) do
    field = Keyword.fetch!(opts, :field)
    Actor.self?(actor, Ash.Changeset.get_attribute(changeset, field))
  end

  def match?(_actor, _context, _opts), do: false
end
