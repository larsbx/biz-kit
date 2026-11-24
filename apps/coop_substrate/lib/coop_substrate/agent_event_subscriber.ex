defmodule CoopSubstrate.AgentEventSubscriber do
  @moduledoc """
  Opt-in staging adapter for EventStore's EXISTING persistent ledger subscription.
  EventStore owns catch-up, bounded buffering, checkpoint persistence and replay.
  This adapter owns only canonical validation and commit-before-ack ordering.

  One in-flight event is deliberate: ack(n) cannot acknowledge an unregistered
  earlier item in a larger batch. All mailbox payloads are untrusted hints;
  authoritative bytes are fetched from Log, not from the message. An unexpected
  ack cannot move the library checkpoint. Registered effects do not launch agents.
  """
  use GenServer
  alias CoopSubstrate.{AgentEventDelivery, AgentEventEffects, EventStore, Log}
  alias CoopSubstrate.Protocol.TypeRegistry
  alias Elixir.EventStore.RecordedEvent
  alias AgentOpsStore.EventRegistrations

  def start_link(opts) do
    host = Keyword.fetch!(opts, :host)

    if host.environment() == :staging,
      do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name])),
      else: {:error, :staging_only}
  end

  @impl true
  def init(opts) do
    conn = Keyword.fetch!(opts, :connection)
    name = Keyword.fetch!(opts, :subscription_name)

    if (is_pid(conn) or is_atom(conn)) and is_binary(name) and byte_size(name) in 1..128 do
      case EventStore.subscribe_to_stream("ledger", name, self(),
             start_from: :origin,
             transient: false,
             buffer_size: 1,
             concurrency_limit: 1,
             max_size: 100,
             checkpoint_threshold: 1
           ) do
        {:ok, subscription} ->
          monitor = Process.monitor(subscription)
          {:ok, %{connection: conn, name: name, subscription: subscription, monitor: monitor}}

        {:error, _} ->
          {:stop, :ledger_subscription_unavailable}
      end
    else
      {:stop, :invalid_event_subscriber_options}
    end
  end

  @impl true
  def handle_info(
        {:events, [%RecordedEvent{stream_uuid: "ledger", event_number: n, stream_version: n}]},
        state
      )
      when is_integer(n) and n > 0 do
    ports = %{
      read: &read/1,
      register: &EventRegistrations.register(state.connection, state.name, &1),
      ack: &EventStore.ack(state.subscription, &1)
    }

    case AgentEventDelivery.deliver(n, ports) do
      :ok -> {:noreply, state}
      {:error, :unexpected_ack} -> {:noreply, state}
      {:error, :uncommitted_event} -> {:noreply, state}
      _ -> {:stop, :event_registration_not_acknowledged, state}
    end
  rescue
    _ -> {:stop, :event_registration_not_acknowledged, state}
  catch
    :exit, _ -> {:stop, :event_registration_not_acknowledged, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _}, %{monitor: ref, subscription: pid} = state),
    do: {:stop, :ledger_subscription_unavailable, state}

  def handle_info(_, state), do: {:noreply, state}

  @doc false
  def read(n) do
    head = Log.head()

    with true <- n <= head.global_seq or {:error, :uncommitted_event},
         :ok <- Log.verify_chains(as_of: head.global_seq),
         {:ok, hash} <- Log.head_at(head.global_seq),
         true <- hash == head.global_hash or {:error, :ledger_head_mismatch},
         {:ok, [env]} <- Log.read_all(from: n, as_of: n),
         true <- env.global_seq == n or {:error, :event_position_mismatch},
         {:ok, bundle} <- AgentEventEffects.derive(env, TypeRegistry.types()),
         do: {:ok, bundle}
  end

  @impl true
  def format_status(status), do: Map.put(status, :state, :redacted_agent_subscription)
end
