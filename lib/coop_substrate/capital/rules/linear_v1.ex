defmodule CoopSubstrate.Capital.Rules.LinearV1 do
  @moduledoc """
  `capital-accrual-v1` — the illustrative linear accrual rule.

  The formula, the weights, and the very shape of this rule are implemented
  such that the versioning machinery is real.

      credited = floor(amount_minor * weight_bp(kind) / 10_000)

  Params (all integer basis points; floats are forbidden by the canonical
  profile):

      %{"weights_bp" => %{<kind> => bp, ...},      # optional
        "default_weight_bp" => bp}                 # optional; falls back to
                                                   # Constants.default_accrual_weight_bp/0
  """

  @behaviour CoopSubstrate.Capital.AccrualRule

  alias CoopSubstrate.Constants

  @impl true
  def credit(params, kind, amount_minor) do
    div(amount_minor * weight_bp(params, kind), 10_000)
  end

  @impl true
  def validate_params(params) when is_map(params) do
    weights = Map.get(params, "weights_bp", %{})
    default = Map.get(params, "default_weight_bp", Constants.default_accrual_weight_bp())
    unknown = Map.keys(params) -- ["weights_bp", "default_weight_bp"]

    cond do
      unknown != [] -> {:error, {:unknown_params, Enum.sort(unknown)}}
      not valid_bp?(default) -> {:error, :bad_default_weight}
      not (is_map(weights) and Enum.all?(weights, &valid_weight?/1)) -> {:error, :bad_weights}
      true -> :ok
    end
  end

  def validate_params(_), do: {:error, :params_must_be_a_map}

  defp weight_bp(params, kind) do
    params
    |> Map.get("weights_bp", %{})
    |> Map.get(kind, Map.get(params, "default_weight_bp", Constants.default_accrual_weight_bp()))
  end

  defp valid_weight?({kind, bp}), do: is_binary(kind) and valid_bp?(bp)
  defp valid_bp?(bp), do: is_integer(bp) and bp >= 0
end
