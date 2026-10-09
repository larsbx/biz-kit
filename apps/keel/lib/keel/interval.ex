defmodule Keel.Interval do
  @moduledoc "Half-open validity interval `[from, to)` over `Date`s; a `nil` bound is unbounded."

  defstruct from: nil, to: nil
  @type t :: %__MODULE__{from: Date.t() | nil, to: Date.t() | nil}

  def always, do: %__MODULE__{}
  def new(from, to \\ nil), do: %__MODULE__{from: from, to: to}

  def contains?(%__MODULE__{from: f, to: u}, t),
    do: (is_nil(f) or Date.compare(f, t) != :gt) and (is_nil(u) or Date.compare(t, u) == :lt)

  def well_formed?(%__MODULE__{from: f, to: u}),
    do: is_nil(f) or is_nil(u) or Date.compare(f, u) == :lt

  @doc "The finite bounds — the only instants at which a snapshot can change."
  def bounds(%__MODULE__{from: f, to: u}), do: Enum.reject([f, u], &is_nil/1)
end
