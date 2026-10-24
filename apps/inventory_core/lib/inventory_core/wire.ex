defmodule InventoryCore.Wire do
  @moduledoc """
  Versioned, untrusted JSON-object boundary for InventoryCore commands.

  Decoding is deliberately a syntactic operation, *not* authorization. The
  authenticated host must supply the expected merchant/item/unit scope,
  enforce role grants and append the command under a serialized version gate.

  Unknown keys and privileged operations are rejected. Neither user input
  nor an external JSON string is ever converted to a new atom.
  """

  @schema "bizkit.inventory.command.v1"
  @max_int 9_223_372_036_854_775_807
  @common ~w(schema op id expected_version merchant item unit)
  @fields %{
    "receive" => ~w(location quantity),
    "reserve" => ~w(location quantity reservation_id expires_at_ms),
    "commit" => ~w(reservation_id quantity),
    "release" => ~w(reservation_id),
    "transfer" => ~w(from to quantity)
  }
  @ops %{
    "receive" => :receive,
    "reserve" => :reserve,
    "commit" => :commit,
    "release" => :release,
    "transfer" => :transfer
  }
  @id_keys ~w(id merchant item unit location reservation_id from to)
  @int_keys ~w(expected_version quantity expires_at_ms)

  @doc """
  Validate an untrusted JSON map against authenticated scope.

  The caller supplies `%{"merchant" => ..., "item" => ..., "unit" => ...}`
  sourced from its *verified* principal/grant and resource binding. The
  returned map is suitable for `InventoryCore.apply/3` only after the host
  performs current-grant authorization and serialized append admission.
  """
  @spec decode(map(), map()) :: {:ok, map()} | {:error, atom()}
  def decode(wire, scope) when is_map(wire) and is_map(scope) do
    op = Map.get(wire, "op")

    with :ok <- exact_scope(wire, scope),
         :ok <- shape(wire, op),
         :ok <- values(wire),
         {:ok, known_op} <- known_operation(op) do
      command =
        @fields
        |> Map.fetch!(op)
        |> Kernel.++(["id", "expected_version"])
        |> Map.new(fn key -> {field(key), Map.fetch!(wire, key)} end)
        |> Map.put(:op, known_op)

      {:ok, command}
    end
  end

  def decode(_, _), do: {:error, :invalid_inventory_command}

  defp exact_scope(wire, scope) do
    keys = ~w(merchant item unit)

    if Enum.all?(keys, fn key ->
         identifier(Map.get(scope, key)) and Map.get(wire, key) === Map.get(scope, key)
       end) do
      :ok
    else
      {:error, :wrong_inventory_scope}
    end
  end

  defp shape(wire, op) do
    case Map.fetch(@fields, op) do
      {:ok, operation_keys} ->
        allowed = Enum.sort(@common ++ operation_keys)

        if Map.get(wire, "schema") == @schema and Enum.sort(Map.keys(wire)) == allowed,
          do: :ok,
          else: {:error, :invalid_inventory_shape}

      :error ->
        {:error, :unsupported_inventory_operation}
    end
  end

  defp values(wire) do
    valid_ids = Enum.all?(@id_keys, fn key ->
      not Map.has_key?(wire, key) or identifier(Map.get(wire, key))
    end)

    valid_ints =
      Enum.all?(@int_keys, fn key ->
        not Map.has_key?(wire, key) or number(key, Map.get(wire, key))
      end)

    if valid_ids and valid_ints, do: :ok, else: {:error, :invalid_inventory_value}
  end

  defp known_operation(op) do
    case Map.fetch(@ops, op) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, :unsupported_inventory_operation}
    end
  end

  # These atoms are compile-time literals only, never derived by String.to_atom.
  defp field("id"), do: :id
  defp field("expected_version"), do: :expected_version
  defp field("location"), do: :location
  defp field("quantity"), do: :quantity
  defp field("reservation_id"), do: :reservation_id
  defp field("expires_at_ms"), do: :expires_at_ms
  defp field("from"), do: :from
  defp field("to"), do: :to

  defp identifier(value), do: is_binary(value) and byte_size(value) in 1..128

  defp number("expected_version", value),
    do: is_integer(value) and value >= 0 and value <= @max_int

  defp number("expires_at_ms", value),
    do: is_integer(value) and value >= 0 and value <= @max_int

  defp number("quantity", value),
    do: is_integer(value) and value > 0 and value <= @max_int
end
