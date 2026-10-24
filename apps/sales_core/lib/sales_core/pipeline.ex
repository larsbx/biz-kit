defmodule SalesCore.Pipeline do
  @moduledoc """
  Pure scoped lead/opportunity progression. No customer, billing or contact PII.

  Winning an opportunity requires an explicit quote reference, not a task
  completion. This is a projected rule, not a sales or finance writer.
  """

  @transitions %{
    lead: [:qualified, :lost],
    qualified: [:proposed, :lost],
    proposed: [:won, :lost],
    won: [],
    lost: []
  }

  def new(tenant) when is_binary(tenant) and byte_size(tenant) > 0,
    do: {:ok, %{tenant: tenant, version: 0, opportunities: %{}}}

  def new(_), do: {:error, :invalid_tenant}

  @doc "Add one lead with opaque party and opportunity references."
  def create(state, tenant, version, %{id: id, party_ref: party} = attrs) do
    with :ok <- scope(state, tenant),
         :ok <- revision(state, version),
         :ok <- identifier(id),
         :ok <- identifier(party),
         false <- Map.has_key?(state.opportunities, id) do
      opp = %{id: id, party_ref: party, state: :lead, quote_ref: nil,
              source: Map.get(attrs, :source, "unspecified")}

      {:ok,
       %{state | opportunities: Map.put(state.opportunities, id, opp),
                 version: version + 1}}
    else
      true -> {:error, :duplicate_opportunity}
      {:error, _} = error -> error
    end
  end

  def create(_, _, _, _), do: {:error, :invalid_opportunity}

  @doc "Advance an opportunity under expected-version admission."
  def advance(state, tenant, version, id, target, quote_ref \\ nil) do
    with :ok <- scope(state, tenant),
         :ok <- revision(state, version),
         {:ok, opp} <- fetch(state, tenant, id),
         true <- target in Map.get(@transitions, opp.state, []),
         :ok <- quote_for_win(target, quote_ref) do
      updated = %{opp | state: target,
                        quote_ref: if(target == :won, do: quote_ref, else: opp.quote_ref)}

      {:ok,
       %{state | opportunities: Map.put(state.opportunities, id, updated),
                 version: version + 1}}
    else
      false -> {:error, :invalid_pipeline_transition}
      {:error, _} = error -> error
    end
  end

  @doc "Read a scoped opportunity projection."
  def fetch(state, tenant, id) do
    with :ok <- scope(state, tenant) do
      case Map.fetch(state.opportunities, id) do
        {:ok, opportunity} -> {:ok, opportunity}
        :error -> {:error, :unknown_opportunity}
      end
    end
  end

  defp scope(%{tenant: t}, t), do: :ok
  defp scope(%{tenant: _}, _), do: {:error, :wrong_tenant}
  defp scope(_, _), do: {:error, :invalid_pipeline}

  defp revision(%{version: v}, v), do: :ok
  defp revision(_, _), do: {:error, :stale_pipeline_version}

  defp identifier(v) when is_binary(v) and byte_size(v) in 1..128, do: :ok
  defp identifier(_), do: {:error, :invalid_reference}

  defp quote_for_win(:won, ref), do: identifier(ref)
  defp quote_for_win(_, nil), do: :ok
  defp quote_for_win(_, _), do: {:error, :quote_only_on_win}
end
