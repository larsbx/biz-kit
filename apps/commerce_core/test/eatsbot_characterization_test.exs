defmodule CommerceCore.EatsbotCharacterizationTest do
  @moduledoc """
  `CommerceCore.Pricing` against the old eatsbot's recorded pricing behaviour: every
  basket in the characterization fixture must price to the same totals or be refused
  with the same error term (rebuild design, slice 1).

  The fixture is copied from larsbx/eatsbot at the commit below and pinned by its
  sha256; a changed copy fails here rather than silently moving the baseline.
  """
  use ExUnit.Case, async: true

  alias CommerceCore.Pricing

  @source "larsbx/eatsbot@15a201ee1279bffce09ab200609c2490f219af8c:eatsbot/test/fixtures/characterization/pricing.jsonl"
  @sha256 "f9fc2e50fe44d7afd20501dd4835c7eacb08bb2cc1ed9d1c16dac8639824b848"
  @path Path.expand("fixtures/eatsbot_characterization/pricing.jsonl", __DIR__)

  test "the fixture is the pinned copy from #{@source}" do
    assert :crypto.hash(:sha256, File.read!(@path)) |> Base.encode16(case: :lower) == @sha256
  end

  test "CommerceCore.Pricing reproduces every recorded basket, refusals included" do
    records = @path |> File.stream!() |> Enum.map(&:json.decode/1)
    assert length(records) == 314

    mismatches =
      for {%{"input" => input, "result" => recorded}, i} <- Enum.with_index(records),
          (actual = price(input)) != recorded,
          do: {i, recorded, actual}

    assert mismatches == []
  end

  defp price(%{"currency" => currency, "lines" => lines, "adjustments" => adjustments}) do
    result =
      Pricing.price(
        String.to_existing_atom(currency),
        Enum.map(lines, fn l ->
          %{
            unit_price: money(l["unit_price"]),
            quantity: l["quantity"],
            discount: money(l["discount"])
          }
        end),
        Map.new(adjustments, fn {k, v} -> {String.to_existing_atom(k), money(v)} end)
      )

    case result do
      {:ok, priced} ->
        %{
          "ok" => %{
            "lines" => Enum.map(priced.lines, &recorded_money(&1.subtotal)),
            "subtotal" => recorded_money(priced.subtotal),
            "total" => recorded_money(priced.total)
          }
        }

      {:error, reason} ->
        %{"error" => recorded_term(reason)}
    end
  end

  defp money([currency, minor]), do: Money.from_integer(minor, String.to_existing_atom(currency))

  defp recorded_money(money) do
    {currency, minor, _exp, _rem} = Money.to_integer_exp(money)
    %{"currency" => Atom.to_string(currency), "minor" => minor}
  end

  # The fixture's encoding: atoms as strings, tuples as arrays.
  defp recorded_term(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp recorded_term(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> recorded_term()
  defp recorded_term(list) when is_list(list), do: Enum.map(list, &recorded_term/1)
  defp recorded_term(other), do: other
end
