defmodule DispatchWeb.ViewModels.FactSummary do
  @moduledoc """
  One fact, carrying where it came from and how old it is (Sections 1, 26.3).

  Section 1 separates four kinds of information — a participant's declaration, an
  observed fact, an external notice, and an AI inference — and Section 4.3
  requires partner summaries to "retain source and freshness labels". A value
  that has lost its source has lost the distinction the whole system is built
  on: "at pickup" declared by a driver and "arrival likely" inferred from a
  geofence are not the same claim, and a page that renders them identically has
  told the reader something false.

  So `source` and `occurred_at` are enforced keys. There is no way to construct
  a summary that does not say what it is.

  `is_estimate` exists for the same reason Section 26.3 forbids rendering an ETA
  without it: an estimate presented as a fact is the most expensive kind of
  wrong in dispatch, because someone schedules against it.
  """

  @enforce_keys [:value, :source, :occurred_at]
  defstruct [:value, :source, :occurred_at, :received_at, is_estimate: false, computed_at: nil]

  @typedoc "Where a fact came from. Section 1's four kinds, named."
  @type source :: :PARTICIPANT | :OBSERVED | :EXTERNAL | :INFERRED

  @type t :: %__MODULE__{
          value: term(),
          source: source(),
          occurred_at: DateTime.t(),
          received_at: DateTime.t() | nil,
          is_estimate: boolean(),
          computed_at: DateTime.t() | nil
        }

  @doc """
  Builds a summary.

  An estimate must say when it was computed. Section 26.3 prohibits rendering an
  ETA without `is_estimate` and `computed_at` together, and a struct that can
  hold one without the other leaves that to a template to remember.
  """
  @spec new(term(), source(), DateTime.t(), keyword()) :: t()
  def new(value, source, occurred_at, opts \\ []) do
    estimate? = Keyword.get(opts, :is_estimate, false)
    computed_at = Keyword.get(opts, :computed_at)

    if estimate? and is_nil(computed_at) do
      raise ArgumentError, "an estimate must carry computed_at (Section 26.3)"
    end

    %__MODULE__{
      value: value,
      source: source,
      occurred_at: occurred_at,
      received_at: Keyword.get(opts, :received_at),
      is_estimate: estimate?,
      computed_at: computed_at
    }
  end

  @doc """
  How stale this fact is at `at`, in seconds.

  Section 26.6 sets display thresholds from age, and Section 4.2 shows
  declaration time and age side by side. Age is computed from `occurred_at`, not
  from arrival: an event created offline at 09:00 and uploaded at 11:00 is two
  hours old, however fresh its delivery was.
  """
  @spec age_seconds(t(), DateTime.t()) :: integer()
  def age_seconds(%__MODULE__{occurred_at: occurred_at}, at \\ DateTime.utc_now()) do
    DateTime.diff(at, occurred_at, :second)
  end
end
