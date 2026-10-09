defmodule CoopSubstrate.Floor.Rules.ThresholdV1 do
  @moduledoc """
  `floor-threshold-v1` — the illustrative per-class threshold floor rule.

  **PLACEHOLDER — awaiting charter declaration** (docs/phase1c_plan.md;
  hand-off §2.4: "per class, generous threshold, rolling window").

      cleared? = throughput value over the window ≥ threshold_minor(class)

  Params (all declared in the activation, no code fallbacks — 00 Art. IV.2):

      %{"window_ms" => pos_int,                        # REQUIRED rolling window
        "default_threshold_minor" => non_neg_int,      # REQUIRED
        "thresholds_minor" => %{<class> => non_neg_int}}  # optional overrides
  """

  @behaviour CoopSubstrate.Floor.Rule

  @impl true
  def cleared?(params, class, value_minor) do
    value_minor >= threshold(params, class)
  end

  @impl true
  def validate_params(params) when is_map(params) do
    thresholds = Map.get(params, "thresholds_minor", %{})

    unknown =
      Map.keys(params) -- ["window_ms", "default_threshold_minor", "thresholds_minor"]

    cond do
      unknown != [] -> {:error, {:unknown_params, Enum.sort(unknown)}}
      not pos_int?(Map.get(params, "window_ms")) -> {:error, :bad_window}
      not non_neg_int?(Map.get(params, "default_threshold_minor")) -> {:error, :bad_default_threshold}
      not (is_map(thresholds) and Enum.all?(thresholds, &valid_threshold?/1)) -> {:error, :bad_thresholds}
      true -> :ok
    end
  end

  def validate_params(_), do: {:error, :params_must_be_a_map}

  defp threshold(params, class) do
    params
    |> Map.get("thresholds_minor", %{})
    |> Map.get(class, Map.fetch!(params, "default_threshold_minor"))
  end

  defp valid_threshold?({class, t}), do: is_binary(class) and non_neg_int?(t)
  defp pos_int?(v), do: is_integer(v) and v > 0
  defp non_neg_int?(v), do: is_integer(v) and v >= 0
end
