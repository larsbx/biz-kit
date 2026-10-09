defmodule Dispatch.Operations.Validations.StatusDeclaration do
  @moduledoc """
  The declaration rules of Section 24.1.

  Three of them, each guarding something a reader of the status would otherwise
  be misled by:

  - `occurred_at` may not exceed server time by more than five minutes. A device
    with a wrong clock would otherwise post a declaration that sorts ahead of
    everything real and becomes a permanently "current" status nothing can
    supersede.
  - `DELAYED` and `BREAKDOWN` require a nonblank note. Both describe a situation
    someone else must act on, and Section 5.1 says the reason and revised
    estimate are requested; a bare code tells a dispatcher nothing actionable.
  - The status must belong to the canonical vocabulary. The attribute constraint
    already enforces this, and checking here too means the profile's own
    `validate_status_transition/3` receives a status it can reason about.
  """

  use Ash.Resource.Validation

  alias Dispatch.Operations.Status

  # Section 24.1: occurred_at cannot exceed server time by more than five
  # minutes. Generous enough for ordinary clock drift, tight enough that a
  # wrong clock cannot pin a status to the future.
  #
  # Compared in milliseconds. `DateTime.diff/3` truncates, so a value 301
  # seconds ahead measured a few milliseconds later reads as exactly 300 and
  # passes a `> 300` test — the boundary would hold or not depending on how long
  # the request took to reach this line.
  @max_clock_skew_ms 300_000

  @impl Ash.Resource.Validation
  def validate(changeset, _opts, _context) do
    status = Ash.Changeset.get_attribute(changeset, :status)
    occurred_at = Ash.Changeset.get_attribute(changeset, :occurred_at)
    note = Ash.Changeset.get_attribute(changeset, :note)

    with :ok <- validate_status(status),
         :ok <- validate_clock(occurred_at),
         :ok <- validate_note(status, note) do
      :ok
    end
  end

  @impl Ash.Resource.Validation
  def atomic(changeset, opts, context),
    do: {:not_atomic, inspect(validate(changeset, opts, context))}

  defp validate_status(status) do
    if Status.known?(status) do
      :ok
    else
      {:error, field: :status, message: "is not a canonical participant status"}
    end
  end

  defp validate_clock(nil), do: :ok

  defp validate_clock(%DateTime{} = occurred_at) do
    if DateTime.diff(occurred_at, DateTime.utc_now(), :millisecond) > @max_clock_skew_ms do
      {:error,
       field: :occurred_at,
       message: "must not be more than #{div(@max_clock_skew_ms, 1000)} seconds in the future"}
    else
      :ok
    end
  end

  defp validate_note(status, note) do
    if Status.requires_note?(status) and blank?(note) do
      {:error, field: :note, message: "is required when declaring #{status}"}
    else
      :ok
    end
  end

  defp blank?(nil), do: true
  defp blank?(note) when is_binary(note), do: String.trim(note) == ""
  defp blank?(_note), do: false
end
