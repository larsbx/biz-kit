defmodule CommerceCore.OrderSafetyTest do
  use ExUnit.Case, async: true
  alias CommerceCore.OrderLifecycle, as: Order

  setup_all do
    Code.ensure_loaded!(Order)
    :ok
  end

  @fixtures Path.expand("fixtures/eatsbot_characterization", __DIR__)
  @pins %{
    "order_transitions" =>
      {192, "ab0005bbb716b2b9eee626e90128099e3ff5d9d2e562123cd6f85f0c72e328de"},
    "order_lifecycle" => {38, "0845114f2021f0d12879a822477af452f1d965517d9a9473abe21e96d0174240"},
    "order_actions" => {714, "c739be36e2c6136077a6e3dd81d242ed2d7fd7189705a4fbcfac680e9e935d26"}
  }
  @targets %{
    "accept" => :accepted,
    "start_preparing" => :preparing,
    "mark_ready" => :ready,
    "dispatch" => :dispatched,
    "complete" => :completed,
    "fail" => :failed,
    "cancel" => :cancelled
  }
  @roles %{
    "accept" => ~w(admin staff),
    "start_preparing" => ~w(admin staff),
    "mark_ready" => ~w(admin staff),
    "dispatch" => ~w(admin system),
    "complete" => ~w(admin staff system),
    "fail" => ~w(admin system),
    "cancel" => ~w(admin staff)
  }

  defp records(name) do
    bytes = File.read!(Path.join(@fixtures, name <> ".jsonl"))
    {count, hash} = Map.fetch!(@pins, name)
    assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == hash
    records = bytes |> String.split("\n", trim: true) |> Enum.map(&:json.decode/1)
    assert length(records) == count
    records
  end

  defp atom(value), do: String.to_existing_atom(value)

  defp trusted(actor),
    do: %{merchant: "shop", order_id: "order", principal: "person", actor: actor, granted: true}

  defp command(action, n \\ 0),
    do: %{id: "event-#{n}", expected_version: n, action: action, reason: "characterization"}

  test "all 192 legal and illegal edges match the pinned relation" do
    for r <- records("order_transitions") do
      assert Order.legal?(atom(r["fulfillment"]), atom(r["from"]), atom(r["to"])) == r["legal"]
    end

    refute Order.legal?(:unknown, :ready, :completed)
  end

  test "all 38 lifecycle records including replay refusals match" do
    for r <- records("order_lifecycle") do
      case r["kind"] do
        "initial" ->
          assert Atom.to_string(Order.initial_state()) == r["state"]
          assert Enum.map(Order.terminal_states(), &Atom.to_string/1) == r["terminal"]

        "next_states" ->
          assert Enum.map(
                   Order.next_states(atom(r["fulfillment"]), atom(r["from"])),
                   &Atom.to_string/1
                 ) == r["next"]

          assert Order.terminal?(atom(r["from"])) == r["terminal"]

        "replay" ->
          history = Enum.map(r["history"], fn [f, t] -> {atom(f), atom(t)} end)
          assert encode(Order.replay(atom(r["fulfillment"]), history)) == r["result"]
      end
    end
  end

  test "714 action cases preserve successes and refuse unsafe legacy observations" do
    results =
      for r <- records("order_actions") do
        {:ok, initial} = Order.new("shop", "order", atom(r["fulfillment"]))

        state =
          Enum.reduce(Enum.with_index(r["path"]), initial, fn {action, i}, state ->
            {:ok, updated, :accepted} =
              Order.apply(state, trusted(:admin), command(atom(action), i))

            updated
          end)

        assert Atom.to_string(state.state) == r["from"]
        ctx = trusted(atom(r["actor"]))
        actual = Order.apply(state, ctx, command(atom(r["action"]), state.version))
        allowed = r["actor"] in Map.fetch!(@roles, r["action"])

        cond do
          not allowed ->
            assert actual == {:error, :forbidden}
            # Historical state validation must never outrun authorization.
            assert Order.apply(:unreadable, ctx, command(atom(r["action"]))) ==
                     {:error, :forbidden}

            :unauthorized

          Map.has_key?(r["result"], "ok") ->
            assert {:ok, updated, :accepted} = actual
            assert Atom.to_string(updated.state) == r["result"]["ok"]["to"]
            assert updated.version == state.version + 1
            assert atom(r["result"]["ok"]["recorded"]["from"]) == state.state
            :success

          true ->
            target = Map.fetch!(@targets, r["action"])

            expected =
              if Order.legal?(state.fulfillment, state.state, target),
                do: :delivery_owned,
                else: :invalid_transition

            assert actual == {:error, expected}
            :refused
        end
      end

    assert Enum.frequencies(results) == %{success: 48, unauthorized: 459, refused: 207}
  end

  test "unauthorized observation is independent of every state, action, revision and history" do
    for actor <- [:none, :public, :private],
        fulfillment <- [:pickup, :delivery, :dine_in],
        from <- Order.states(),
        action <- Map.keys(@roles) do
      {:ok, state} = Order.new("shop", "order", fulfillment)

      assert Order.apply(
               %{state | state: from, seen: :protected},
               trusted(actor),
               command(atom(action), 999)
             ) == {:error, :forbidden}
    end

    {:ok, state} = Order.new("shop", "order", :pickup)

    for ctx <- [
          nil,
          %{trusted(:admin) | granted: false},
          %{trusted(:admin) | merchant: "other"},
          %{trusted(:admin) | order_id: "other"}
        ] do
      assert Order.apply(state, ctx, command(:accept)) == {:error, :forbidden}
    end
  end

  test "retries bind full payload and principal and require a current grant" do
    {:ok, initial} = Order.new("shop", "order", :pickup)
    cmd = command(:accept)
    {:ok, state, :accepted} = Order.apply(initial, trusted(:admin), cmd)
    assert {:ok, ^state, :duplicate} = Order.apply(state, trusted(:admin), cmd)

    assert Order.apply(state, trusted(:admin), %{cmd | action: :cancel}) ==
             {:error, :idempotency_conflict}

    assert Order.apply(state, %{trusted(:admin) | principal: "other"}, cmd) ==
             {:error, :idempotency_conflict}

    assert Order.apply(state, %{trusted(:admin) | granted: false}, cmd) == {:error, :forbidden}

    assert Order.apply(state, trusted(:admin), %{command(:cancel, 1) | expected_version: 0}) ==
             {:error, :stale_order_version}

    assert Order.apply(state, trusted(:admin), %{command(:cancel, 1) | reason: ""}) ==
             {:error, :reason_required}

    {:ok, cancelled, :accepted} = Order.apply(state, trusted(:admin), command(:cancel, 1))

    assert Order.apply(cancelled, trusted(:admin), command(:accept, 2)) ==
             {:error, :invalid_transition}

    assert {:ok, ^cancelled, :duplicate} = Order.apply(cancelled, trusted(:admin), cmd)
  end

  test "lifecycle commands preserve immutable commercial fields" do
    {:ok, initial} = Order.new("shop", "order", :pickup)
    initial = Map.merge(initial, %{lines: [:priced_snapshot], total: 3900})

    cmd =
      Map.merge(command(:accept), %{lines: [:replacement], total: 0, financial_status: :settled})

    {:ok, updated, :accepted} = Order.apply(initial, trusted(:admin), cmd)
    assert updated.lines == initial.lines
    assert updated.total == initial.total
    refute Map.has_key?(updated, :financial_status)
  end

  defp encode(x) when is_tuple(x), do: x |> Tuple.to_list() |> Enum.map(&encode/1)
  defp encode(x) when is_atom(x), do: Atom.to_string(x)
  defp encode(x), do: x
end
