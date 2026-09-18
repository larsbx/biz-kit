defmodule Dispatch.Fleet.Validations.WindowOrder do
  @moduledoc """
  An appointment window must not end before it starts.

  An inverted window is never satisfiable, so an ETA computed against it would
  always read as late — and Section 4.2's exception panel would show a
  permanent, uncorrectable late-risk warning that no driver action could clear.
  """

  use Ash.Resource.Validation

  @impl Ash.Resource.Validation
  def validate(changeset, _opts, _context) do
    window_start = Ash.Changeset.get_attribute(changeset, :window_start)
    window_end = Ash.Changeset.get_attribute(changeset, :window_end)

    if is_nil(window_start) or is_nil(window_end) or
         DateTime.compare(window_start, window_end) != :gt do
      :ok
    else
      {:error, field: :window_end, message: "must not be earlier than window_start"}
    end
  end

  @impl Ash.Resource.Validation
  def atomic(changeset, opts, context),
    do: {:not_atomic, inspect(validate(changeset, opts, context))}
end
