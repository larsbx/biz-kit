defmodule DispatchWeb.ApiSpec do
  @moduledoc """
  The canonical OpenAPI 3.1 description (Section 19.1).

  Section 20 makes `contracts/openapi.json` generated and diff-checked from this
  module and then used to generate the Android client, so this is the single
  source of the transport contract rather than a document maintained beside it.
  """

  @behaviour OpenApiSpex.OpenApi

  alias OpenApiSpex.{Components, Info, OpenApi, Paths, SecurityScheme, Server}

  @impl OpenApiSpex.OpenApi
  def spec do
    %OpenApi{
      openapi: "3.1.0",
      info: %Info{
        title: "Dispatch Platform API",
        version: Application.spec(:dispatch, :vsn) |> to_string(),
        description: """
        Machine API for the field application and internal services.

        Portal endpoints under `/ui` return HTML or Datastar SSE and are not
        described here; Section 24.5 keeps them separate from the `/v1` machine
        API on purpose.
        """
      },
      servers: [%Server{url: "/"}],
      paths: Paths.from_router(DispatchWeb.Router),
      components: %Components{
        securitySchemes: %{
          # Section 23.1: short-lived OIDC access tokens.
          "bearerAuth" => %SecurityScheme{type: "http", scheme: "bearer", bearerFormat: "JWT"}
        }
      }
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
