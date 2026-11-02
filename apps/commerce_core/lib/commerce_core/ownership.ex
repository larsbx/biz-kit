defmodule CommerceCore.Ownership do
  @moduledoc """
  Home + merchant ownership checks for trusted candidate projections.

  A host must resolve these identifiers from current authority and persisted
  ownership, never from request parameters. This module does not authenticate a
  principal, validate a grant, fence a writer or enforce PostgreSQL isolation.
  Binary merchant-only projections remain compatibility candidates, not homes.
  """

  def valid?(%{home_id: home, merchant: merchant}), do: id?(home) and id?(merchant)
  def valid?(_), do: false

  def id?(id), do: is_binary(id) and byte_size(id) in 1..128

  @doc "Fail closed on omitted, foreign or mixed home/merchant context."
  def check(%{home_id: home, merchant: merchant} = owner, context) do
    if valid?(owner) and is_map(context) and
         Map.get(context, :home_id) === home and Map.get(context, :merchant) === merchant,
       do: :ok,
       else: {:error, :forbidden}
  end

  # Never downgrade a home projection to merchant-only compatibility semantics.
  def check(%{home_id: _}, _), do: {:error, :forbidden}
  def check(%{merchant: merchant}, merchant) when is_binary(merchant), do: :ok
  def check(_, _), do: {:error, :forbidden}

  def stamp(%{home_id: home, merchant: merchant}, record),
    do: Map.merge(record, %{home_id: home, merchant: merchant})

  def stamp(_, record), do: record
end
