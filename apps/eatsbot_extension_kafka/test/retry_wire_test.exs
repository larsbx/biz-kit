defmodule Eatsbot.Extensions.Kafka.RetryWireTest do
  use ExUnit.Case, async: false

  alias Eatsbot.Extensions.Kafka.Driver

  # Real KafkaEx.Client request/retry callbacks and real TCP/Kayrock encoding.
  # Only initial discovery is bypassed, using a known one-broker cluster.
  defmodule Client do
    use GenServer
    alias KafkaEx.Client.State
    alias KafkaEx.Cluster.{Broker, ClusterMetadata, Topic}

    def start_link(port), do: GenServer.start_link(__MODULE__, port, name: :kafka_ex)

    def init(port) do
      socket = KafkaEx.Network.NetworkClient.create_socket("localhost", port)
      broker = %Broker{node_id: 1, host: "localhost", port: port, socket: socket}

      {:ok,
       %State{
         api_versions: %{0 => {3, 3}, 3 => {1, 1}},
         correlation_id: 1,
         metadata_update_interval: 60_000,
         tracked_topics: MapSet.new(["events"]),
         cluster_metadata: %ClusterMetadata{
           brokers: %{1 => broker},
           topics: %{"events" => %Topic{name: "events", partition_leaders: %{0 => 1}}}
         }
       }}
    end

    def handle_call(message, from, state), do: KafkaEx.Client.handle_call(message, from, state)
    def handle_info(message, state), do: KafkaEx.Client.handle_info(message, state)
    def terminate(reason, state), do: KafkaEx.Client.terminate(reason, state)
  end

  defp broker(errors) do
    owner = self()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: 4, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)

    task =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        serve(socket, port, owner, errors)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.exit(task, :kill)
    end)

    start_supervised!({Client, port})
  end

  # Fixed Kafka Produce v3 and Metadata v1 wire responses, independently encoded.
  defp serve(socket, port, owner, errors) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok,
       <<api::16, version::16, correlation::32, size::16, _client::binary-size(size),
         body::binary>>} ->
        case {api, version} do
          {0, 3} ->
            <<-1::signed-16, acks::signed-16, _::binary>> = body
            send(owner, {:produce_on_wire, acks})
            [error | remaining] = errors

            response = [
              <<correlation::32, 1::32>>,
              string("events"),
              <<1::32, 0::32, error::16, 9::64, -1::signed-64, 0::32>>
            ]

            :ok = :gen_tcp.send(socket, response)
            serve(socket, port, owner, if(remaining == [], do: [error], else: remaining))

          {3, 1} ->
            send(owner, :metadata_on_wire)

            response = [
              <<correlation::32, 1::32, 1::32>>,
              string("localhost"),
              <<port::32, -1::signed-16, 1::32, 1::32, 0::16>>,
              string("events"),
              <<0::8, 1::32, 0::16, 0::32, 1::32, 1::32, 1::32, 1::32, 1::32>>
            ]

            :ok = :gen_tcp.send(socket, response)
            serve(socket, port, owner, errors)
        end

      {:error, :closed} ->
        :ok
    end
  end

  defp string(value), do: <<byte_size(value)::16, value::binary>>

  test "leadership rejection refreshes metadata and retries successfully" do
    broker([6, 0])
    assert :ok = Driver.produce("events", "value")
    assert_received {:produce_on_wire, 1}
    assert_received :metadata_on_wire
    assert_received {:produce_on_wire, 1}
    refute_received {:produce_on_wire, _}
  end

  test "persistent leadership rejection stops at the upstream three-attempt budget" do
    broker([6])
    assert {:error, :not_leader_for_partition} = Driver.produce("events", "value")
    for _ <- 1..3, do: assert_received({:produce_on_wire, 1})
    refute_received {:produce_on_wire, _}
  end

  test "broker timeout is ambiguous and does not resend" do
    broker([7])
    assert {:error, :request_timed_out} = Driver.produce("events", "value")
    assert_received {:produce_on_wire, 1}
    refute_received {:produce_on_wire, _}
    refute_received :metadata_on_wire
  end

  test "authorization rejection is terminal" do
    broker([29])
    assert {:error, :topic_authorization_failed} = Driver.produce("events", "value")
    assert_received {:produce_on_wire, 1}
    refute_received {:produce_on_wire, _}
    refute_received :metadata_on_wire
  end
end
