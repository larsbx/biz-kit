defmodule DispatchWeb.HealthController do
  @moduledoc """
  The three health endpoints of Section 32.

  The separation matters operationally: `/health/live` must stay cheap enough
  that a slow dependency cannot cause a restart loop, and `/health/ready` must
  never make an outbound paid-provider call.
  """

  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Dispatch.Integrations.AdapterRegistry

  alias DispatchWeb.Schemas.{
    DependenciesResponse,
    LivenessResponse,
    Problem,
    ReadinessResponse
  }

  tags(["health"])

  operation(:live,
    summary: "Process liveness",
    description: "Reports that the process is running. Asserts nothing about dependencies.",
    responses: [ok: {"Liveness", "application/json", LivenessResponse}]
  )

  operation(:ready,
    summary: "Readiness",
    description: "Database reachability and migration state. Makes no outbound provider call.",
    responses: [
      ok: {"Ready", "application/json", ReadinessResponse},
      service_unavailable: {"Not ready", "application/json", ReadinessResponse}
    ]
  )

  operation(:dependencies,
    summary: "Adapter configuration",
    description: "Redacted adapter selection and secret presence. Never reports secret values.",
    security: [%{"bearerAuth" => []}],
    responses: [
      ok: {"Configuration", "application/json", DependenciesResponse},
      unauthorized: {"Unauthorized", "application/problem+json", Problem}
    ]
  )

  @doc "Process liveness only. Asserts nothing about dependencies."
  @spec live(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def live(conn, _params) do
    json(conn, %{status: "ok", checked_at: now()})
  end

  @doc """
  Database reachability and migration state. Section 32 forbids an outbound
  paid-provider call here, so adapter configuration is reported by
  `/health/dependencies` instead.
  """
  @spec ready(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def ready(conn, _params) do
    checks = %{
      database: check_database(),
      migrations: check_migrations()
    }

    ready? = Enum.all?(checks, fn {_name, %{status: status}} -> status == "ok" end)

    conn
    |> put_status(if ready?, do: 200, else: 503)
    |> json(%{status: if(ready?, do: "ok", else: "unready"), checks: checks, checked_at: now()})
  end

  @doc """
  Authenticated adapter-configuration report. Section 31 permits printing
  configuration keys and redacted presence, never values, so this returns which
  adapter module is selected and whether its required secrets are present.
  """
  @spec dependencies(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def dependencies(conn, _params) do
    json(conn, %{
      status: "ok",
      adapters: AdapterRegistry.configuration_report(),
      checked_at: now()
    })
  end

  defp check_database do
    case Ecto.Adapters.SQL.query(Dispatch.Repo, "SELECT postgis_version()", []) do
      {:ok, %{rows: [[version]]}} -> %{status: "ok", postgis_version: version}
      {:error, _reason} -> %{status: "error", detail: "database_unreachable"}
    end
  rescue
    _ -> %{status: "error", detail: "database_unreachable"}
  end

  # Section 22 forbids auto-migration on boot, so readiness reports a pending
  # migration as unready rather than silently applying it.
  defp check_migrations do
    pending =
      Dispatch.Repo
      |> Ecto.Migrator.migrations()
      |> Enum.count(fn {status, _version, _name} -> status == :down end)

    if pending == 0 do
      %{status: "ok", pending: 0}
    else
      %{status: "error", detail: "migrations_pending", pending: pending}
    end
  rescue
    _ -> %{status: "error", detail: "migration_state_unavailable"}
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
