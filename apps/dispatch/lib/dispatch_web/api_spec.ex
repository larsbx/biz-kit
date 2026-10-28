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
      paths: DispatchWeb.Router |> Paths.from_router() |> custom_methods(),
      components: %Components{
        securitySchemes: %{
          # Section 23.1: short-lived OIDC access tokens.
          "bearerAuth" => %SecurityScheme{type: "http", scheme: "bearer", bearerFormat: "JWT"},
          "nativeSession" => %SecurityScheme{
            type: "apiKey",
            in: :header,
            name: "Authorization",
            description:
              "BizKit <session>, obtained through the PKCE native handoff. Revocable BizKit.Identity session."
          }
        }
      }
    }
    |> OpenApiSpex.resolve_schema_modules()
  end

  # A custom method (`/location-samples:batch`, Section 24.2) is a route whose
  # last segment ends in `:verb`, which Phoenix matches as a parameter and
  # OpenApiSpex therefore writes as `{verb}`. The contract states the path.
  defp custom_methods(paths) do
    Map.new(paths, fn {path, item} ->
      {Regex.replace(~r/([^\/])\{(\w+)\}$/, path, "\\1:\\2"), item}
    end)
  end
end
