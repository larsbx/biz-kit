defmodule Eatsbot.Extensions.Kafka.Supervisor do
  @moduledoc """
  Owns the extension's named, produce-only KafkaEx client.
  """
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    children = [{KafkaEx.API, name: :kafka_ex, consumer_group: :no_consumer_group}]

    Supervisor.init(children,
      strategy: :one_for_one,
      max_restarts: Keyword.get(opts, :max_restarts, 10),
      max_seconds: Keyword.get(opts, :max_seconds, 60)
    )
  end
end
