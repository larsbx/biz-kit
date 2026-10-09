defmodule Dispatch.Access.Checks.OwnRecords do
  @moduledoc """
  Filters a read to records about the acting participant.

  The read-side counterpart to `ActingOnSelf`. A simple check can only say yes
  or no to a whole query; Section 4.1 gives a driver their own status history
  and Section 6.3 their own trip history, which is a filter rather than a
  verdict.

  Expressed as a filter so the restriction happens in SQL. A post-filter would
  mean the database returning rows the actor may not see and the application
  discarding them — which leaks through row counts, pagination and timing even
  when the rows themselves never render.
  """

  use Ash.Policy.FilterCheck

  alias Dispatch.Access.Actor

  @doc "Builds the check for the field naming the subject participant."
  @spec on(atom()) :: {module(), keyword()}
  def on(field) when is_atom(field), do: {__MODULE__, field: field}

  @impl Ash.Policy.Check
  def describe(opts), do: "#{opts[:field]} is the acting participant"

  @impl Ash.Policy.FilterCheck
  def filter(%Actor{principal_type: :PARTICIPANT} = actor, _context, opts) do
    field = Keyword.fetch!(opts, :field)
    [{field, actor.principal_id}]
  end

  # A service principal has no "own" records; Section 23.2 keeps self-service
  # capabilities away from one entirely.
  def filter(_actor, _context, _opts), do: expr(false)
end
