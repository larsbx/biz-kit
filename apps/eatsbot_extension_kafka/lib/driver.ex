defmodule Eatsbot.Extensions.Kafka.Driver do
  @moduledoc """
  Synchronous Kafka producer for `EatsbotCore.Kafka`.

  Publishes binary payloads unchanged to partition 0 using the extension's
  supervised `:kafka_ex` client. Maps are JSON-encoded by `EatsbotCore.Kafka`.
  Success requires a leader acknowledgment (`acks: 1`) with an assigned offset.
  Options remain ignored, as in the original driver.

  KafkaEx owns leadership retries. This adapter never resends a failed call:
  a timeout or lost connection may follow a write whose acknowledgment was lost.
  """

  @behaviour EatsbotCore.Kafka

  alias KafkaEx.Messages.RecordMetadata

  @impl true
  @spec produce(String.t(), String.t(), term()) :: :ok | {:error, term()}
  def produce(topic, message, opts \\ [])

  def produce(topic, message, _opts)
      when is_binary(topic) and byte_size(topic) > 0 and is_binary(message) do
    case KafkaEx.API.produce(:kafka_ex, topic, 0, [%{value: message}], acks: 1) do
      {:ok, %RecordMetadata{topic: ^topic, partition: 0, base_offset: offset}}
      when is_integer(offset) and offset >= 0 ->
        :ok

      {:error, _reason} = error ->
        error

      other ->
        {:error, {:unexpected_produce_response, other}}
    end
  catch
    :exit, reason -> {:error, {:kafka_client_exit, reason}}
  end

  def produce(topic, _message, _opts) when not is_binary(topic) or topic == "",
    do: {:error, :invalid_topic}

  def produce(_topic, _message, _opts), do: {:error, :invalid_payload}
end
