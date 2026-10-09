defmodule CoopSubstrate.Throughput.Rules.WeightedSumV1 do
  @moduledoc """
  `throughput-weighted-v1` — the illustrative weighted-sum throughput rule.

  **PLACEHOLDER — awaiting charter declaration** (and the absent
  throughput_and_floor spec, docs/phase1c_plan.md). The shape mirrors
  `Capital.Rules.LinearV1`:

      credited = floor(units * weight_bp(component) / 10_000)

  Params (integer basis points; floats forbidden by the canonical profile):

      %{"default_weight_bp" => bp,                    # REQUIRED — declared in
                                                      # the activation, no code
                                                      # fallback (00 Art. IV.2)
        "weights_bp" => %{<component> => bp, ...}}    # optional overrides

  `settlement` may carry a weight even though it is never recordable as a
  claim — the step-5 fold credits it from obligation-rail discharges.
  """

  @behaviour CoopSubstrate.Throughput.Rule

  @impl true
  def credit(params, component, units) do
    div(units * weight_bp(params, component), 10_000)
  end

  @impl true
  def validate_params(params) when is_map(params) do
    weights = Map.get(params, "weights_bp", %{})
    unknown = Map.keys(params) -- ["weights_bp", "default_weight_bp"]

    cond do
      unknown != [] -> {:error, {:unknown_params, Enum.sort(unknown)}}
      not valid_bp?(Map.get(params, "default_weight_bp")) -> {:error, :bad_default_weight}
      not (is_map(weights) and Enum.all?(weights, &valid_weight?/1)) -> {:error, :bad_weights}
      true -> :ok
    end
  end

  def validate_params(_), do: {:error, :params_must_be_a_map}

  defp weight_bp(params, component) do
    params
    |> Map.get("weights_bp", %{})
    |> Map.get(component, Map.fetch!(params, "default_weight_bp"))
  end

  defp valid_weight?({component, bp}), do: is_binary(component) and valid_bp?(bp)
  defp valid_bp?(bp), do: is_integer(bp) and bp >= 0
end
