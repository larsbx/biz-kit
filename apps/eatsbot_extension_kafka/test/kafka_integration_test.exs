defmodule Eatsbot.Extensions.Kafka.IntegrationTest do
  use ExUnit.Case, async: false
  @moduletag :kafka_integration

  alias Eatsbot.Extensions.Kafka
  alias Eatsbot.Extensions.Kafka.Driver

  setup_all do
    {:ok, _} = Application.ensure_all_started(:ssl)
    {:ok, _} = Application.ensure_all_started(:telemetry)
    port = String.to_integer(System.get_env("KAFKA_PORT", "19092"))
    previous_brokers = Application.fetch_env(:kafka_ex, :brokers)
    previous_driver = Application.fetch_env(:eatsbot, :kafka_driver)
    Application.put_env(:kafka_ex, :brokers, [{"localhost", port}])

    on_exit(fn ->
      restore(:kafka_ex, :brokers, previous_brokers)
      restore(:eatsbot, :kafka_driver, previous_driver)
    end)

    :ok
  end

  setup do
    extension = start_supervised!({Kafka, []})
    assert extension == Process.whereis(Kafka)
    [{Kafka.Supervisor, supervisor, :supervisor, _}] = Supervisor.which_children(extension)
    [{:kafka_ex, client, :worker, _}] = Supervisor.which_children(supervisor)
    assert client == Process.whereis(:kafka_ex)
    topic = "eatsbot-acceptance-#{System.unique_integer([:positive])}"

    eventually(fn ->
      case KafkaEx.API.topics_metadata(:kafka_ex, [topic], true) do
        {:ok, [%{partition_leaders: leaders}]} -> map_size(leaders) > 0
        _ -> false
      end
    end)

    %{topic: topic, client: client, supervisor: supervisor}
  end

  test "binary and map payloads round-trip without duplicate records", %{topic: topic} do
    assert :ok = Driver.produce(topic, <<0, 255, 1>>)
    assert :ok = EatsbotCore.Kafka.produce(topic, %{event: "ready", quantity: 2})
    assert :ok = Driver.produce(topic, "")
    assert {:ok, 3} = KafkaEx.API.latest_offset(:kafka_ex, topic, 0)

    assert {:ok, %{records: [binary, json, empty]}} =
             KafkaEx.API.fetch(:kafka_ex, topic, 0, 0, max_wait_time: 100)

    assert binary.value == <<0, 255, 1>>
    assert Jason.decode!(json.value) == %{"event" => "ready", "quantity" => 2}
    assert empty.value == ""
    assert Enum.map([binary, json, empty], & &1.offset) == [0, 1, 2]
  end

  test "real broker rejects oversized records without changing the log", %{topic: topic} do
    assert {:error, :message_too_large} = Driver.produce(topic, :binary.copy("x", 2_000_000))
    assert {:ok, 0} = KafkaEx.API.latest_offset(:kafka_ex, topic, 0)
    assert :ok = Driver.produce(topic, "after-rejection")
    assert {:ok, 1} = KafkaEx.API.latest_offset(:kafka_ex, topic, 0)
  end

  test "malformed payloads do not publish or crash the producer", %{topic: topic, client: client} do
    assert {:error, :invalid_payload} = Driver.produce(topic, [:not, :binary])
    assert Process.alive?(client)
    assert {:ok, 0} = KafkaEx.API.latest_offset(:kafka_ex, topic, 0)
  end

  test "the supervised producer restarts and can publish again", %{
    topic: topic,
    client: client,
    supervisor: supervisor
  } do
    Process.exit(client, :kill)

    eventually(fn ->
      replacement = Process.whereis(:kafka_ex)
      is_pid(replacement) and replacement != client
    end)

    [{:kafka_ex, replacement, :worker, _}] = Supervisor.which_children(supervisor)
    assert replacement != client
    assert :ok = Driver.produce(topic, "after-restart")
    assert {:ok, 1} = KafkaEx.API.latest_offset(:kafka_ex, topic, 0)
  end

  defp eventually(fun, remaining \\ 100)
  defp eventually(_fun, 0), do: flunk("Kafka did not become ready")

  defp eventually(fun, remaining) do
    if fun.() do
      :ok
    else
      Process.sleep(100)
      eventually(fun, remaining - 1)
    end
  end

  defp restore(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore(app, key, :error), do: Application.delete_env(app, key)
end
