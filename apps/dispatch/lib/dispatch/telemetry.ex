defmodule Dispatch.Telemetry do
  @moduledoc """
  Telemetry supervisor and the metric definitions required by Section 32.

  Metrics that describe a subsystem are declared by the slice that builds it.
  Slice 0 declares only transport, database, and VM metrics, because emitting
  a permanently zero counter for an unbuilt subsystem would misreport health.
  """

  use Supervisor

  import Telemetry.Metrics

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Metric definitions consumed by the reporter attached in each environment.
  """
  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    [
      counter("http_requests_total",
        event_name: [:phoenix, :endpoint, :stop],
        tags: [:method, :status],
        tag_values: &http_tags/1,
        description: "HTTP requests by method and response status"
      ),
      distribution("http_request_duration_seconds",
        event_name: [:phoenix, :endpoint, :stop],
        measurement: :duration,
        unit: {:native, :second},
        tags: [:method, :status],
        tag_values: &http_tags/1,
        description: "HTTP request duration"
      ),
      summary("dispatch.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "Database query time"
      ),
      last_value("vm.memory.total", unit: {:byte, :byte}),
      last_value("vm.total_run_queue_lengths.total")
    ]
  end

  defp periodic_measurements do
    [
      {:process_info, event: [:dispatch, :supervisor], name: Dispatch.Supervisor, keys: [:memory]}
    ]
  end

  # Section 32 forbids high-cardinality and sensitive tags, so the request path
  # is reduced to the matched Phoenix route and never the raw URI.
  defp http_tags(%{conn: conn} = metadata) do
    %{
      method: conn.method,
      status: Integer.to_string(conn.status || 0),
      route: Map.get(metadata, :route, "unmatched")
    }
  end
end
