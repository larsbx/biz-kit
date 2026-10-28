defmodule Eatsbot.Extensions.Kafka.DriverTest do
  use ExUnit.Case, async: false

  alias Eatsbot.Extensions.Kafka.Driver
  alias KafkaEx.Messages.RecordMetadata

  # Exercise the real KafkaEx.API call/reply boundary without a broker.
  defmodule Client do
    use GenServer

    def start_link({owner, reply}),
      do: GenServer.start_link(__MODULE__, {owner, reply}, name: :kafka_ex)

    def init(state), do: {:ok, state}

    def handle_call(request, _from, {owner, reply} = state) do
      send(owner, {:request, request})
      {:reply, reply, state}
    end
  end

  defp client(reply), do: start_supervised!({Client, {self(), reply}})

  defp acknowledgment(overrides \\ []) do
    struct!(
      RecordMetadata,
      Keyword.merge([topic: "events", partition: 0, base_offset: 7], overrides)
    )
  end

  test "release metadata includes KafkaEx without automatically starting a default worker" do
    assert :kafka_ex in Application.spec(:eatsbot_extension_kafka, :included_applications)
    refute List.keymember?(Application.started_applications(), :kafka_ex, 0)
    assert Process.whereis(KafkaEx.Supervisor) == nil

    release_config =
      Keyword.put(Mix.Project.config(), :releases,
        kafka_probe: [applications: [eatsbot_extension_kafka: :load]]
      )

    release = Mix.Release.from_config!(:kafka_probe, release_config, [])
    assert release.applications.kafka_ex[:mode] == :included
    assert Map.has_key?(release.applications, :kayrock)
    assert Map.has_key?(release.applications, :crc32cer)
  end

  test "publishes the exact binary and maps a leader acknowledgment to :ok" do
    client({:ok, acknowledgment()})
    payload = <<0, 255, 1>>
    assert :ok = Driver.produce("events", payload)
    assert_received {:request, {:produce, "events", 0, [%{value: ^payload}], [acks: 1]}}
    refute_received {:request, _}
  end

  test "empty payloads are valid Kafka values and offset zero is an acknowledgment" do
    client({:ok, acknowledgment(base_offset: 0)})
    assert :ok = Driver.produce("events", "")
  end

  test "legacy options cannot silently weaken acknowledgments or change partitions" do
    client({:ok, acknowledgment()})
    assert :ok = Driver.produce("events", "v", acks: 0, required_acks: 0, partition: 9)
    assert_received {:request, {:produce, "events", 0, [%{value: "v"}], [acks: 1]}}
  end

  test "broker rejection and exhausted leadership retries remain errors without adapter resends" do
    for reason <- [:topic_authorization_failed, :message_too_large, :not_leader_for_partition] do
      pid = client({:error, %{error: reason}})
      assert {:error, ^reason} = Driver.produce("events", "v")
      assert_received {:request, {:produce, _, _, _, _}}
      refute_received {:request, _}
      stop_supervised!(Client)
      refute Process.alive?(pid)
    end
  end

  test "ambiguous timeouts and transport failures are never retried by the adapter" do
    for reason <- [:request_timed_out, :timeout, :closed, :econnrefused] do
      client({:error, reason})
      assert {:error, ^reason} = Driver.produce("events", "v")
      assert_received {:request, _}
      refute_received {:request, _}
      stop_supervised!(Client)
    end
  end

  test "unacknowledged or mismatched metadata is not success" do
    for metadata <- [
          acknowledgment(base_offset: nil),
          acknowledgment(base_offset: -1),
          acknowledgment(topic: "other"),
          acknowledgment(partition: 1)
        ] do
      client({:ok, metadata})

      assert {:error, {:unexpected_produce_response, {:ok, ^metadata}}} =
               Driver.produce("events", "v")

      stop_supervised!(Client)
    end
  end

  test "malformed payloads and topics are rejected before contacting the client" do
    client({:ok, acknowledgment()})

    for payload <- [nil, 1, [:bad], %{not_encoded: true}, self()] do
      assert {:error, :invalid_payload} = Driver.produce("events", payload)
    end

    for topic <- [nil, "", :events] do
      assert {:error, :invalid_topic} = Driver.produce(topic, "v")
    end

    refute_received {:request, _}
  end

  test "a stopped client is an error, not a successful publication" do
    assert {:error, {:kafka_client_exit, {:noproc, _}}} = Driver.produce("events", "v")
  end

  test "the existing core interface JSON-encodes maps before publication" do
    previous = Application.fetch_env(:eatsbot, :kafka_driver)
    Application.put_env(:eatsbot, :kafka_driver, Driver)

    on_exit(fn ->
      case previous do
        {:ok, driver} -> Application.put_env(:eatsbot, :kafka_driver, driver)
        :error -> Application.delete_env(:eatsbot, :kafka_driver)
      end
    end)

    client({:ok, acknowledgment()})
    assert :ok = EatsbotCore.Kafka.produce("events", %{event: "ready", quantity: 2})
    assert_received {:request, {:produce, "events", 0, [%{value: json}], [acks: 1]}}
    assert Jason.decode!(json) == %{"event" => "ready", "quantity" => 2}
    # Preserve the core's existing encode! contract for values without a JSON encoding.
    assert_raise Protocol.UndefinedError, fn ->
      EatsbotCore.Kafka.produce("events", %{bad: self()})
    end

    refute_received {:request, _}
  end
end
