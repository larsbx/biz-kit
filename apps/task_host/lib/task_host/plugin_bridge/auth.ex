defmodule TaskHost.PluginBridge.Auth do
  @moduledoc """
  Resolve a live, resource-bound OAuth access token to a Biz-Kit principal.
  The configured issuer is the only source of token identity and scope.
  """

  alias BizKit.Identity.Resolver
  alias TaskCore.Admission

  @scope "bizkit.plugin.read"
  @metadata_path "/.well-known/oauth-protected-resource/mcp"
  @credentials [:client_id, :client_secret]

  def scope, do: @scope
  def metadata_path, do: @metadata_path

  def config do
    config = Application.get_env(:task_host, :plugin_bridge, %{})

    with %{
           resource: resource,
           issuer: issuer,
           introspection_url: endpoint,
           workspace_ids: [_ | _] = ids
         } <- config,
         %URI{path: "/mcp"} <- https_uri(resource),
         %URI{} <- https_uri(issuer),
         %URI{path: "/" <> _} <- https_uri(endpoint),
         true <- length(ids) <= 32 and Enum.all?(ids, &Admission.segment?/1),
         true <- Enum.all?(@credentials, &credential?(config[&1])) do
      {:ok, config}
    else
      _ -> {:error, :disabled}
    end
  end

  def origin(config) do
    uri = URI.parse(config.resource)
    URI.to_string(%{uri | path: nil})
  end

  def metadata(config) do
    %{
      resource: config.resource,
      authorization_servers: [config.issuer],
      scopes_supported: [@scope],
      bearer_methods_supported: ["header"]
    }
  end

  def challenge(config, reason) do
    base = ~s(Bearer resource_metadata="#{origin(config) <> @metadata_path}", scope="#{@scope}")

    case reason do
      :insufficient_scope -> base <> ~s(, error="insufficient_scope")
      :invalid_token -> base <> ~s(, error="invalid_token")
      :missing_token -> base
    end
  end

  def principal(config, [authorization]) when byte_size(authorization) <= 4_103 do
    case Regex.run(~r/\ABearer ([A-Za-z0-9._~+\/-]+=*)\z/i, authorization,
           capture: :all_but_first
         ) do
      [token] when byte_size(token) <= 4096 -> introspect(config, token)
      _ -> {:error, :invalid_token}
    end
  end

  def principal(_config, []), do: {:error, :missing_token}
  def principal(_config, _headers), do: {:error, :invalid_token}

  defp introspect(config, token) do
    # Encode client credentials as OAuth form components before HTTP Basic.
    credentials =
      URI.encode_www_form(config.client_id) <> ":" <> URI.encode_www_form(config.client_secret)

    options =
      Keyword.merge(
        Map.get(config, :req_options, []),
        auth: {:basic, credentials},
        form: [token: token, token_type_hint: "access_token"],
        redirect: false,
        retry: false,
        finch: [receive_timeout: 2_000, pool_timeout: 2_000, request_timeout: 3_000],
        connect_options: [timeout: 2_000]
      )

    case Req.post(config.introspection_url, options) do
      {:ok, %{status: 200, body: claims}} -> resolve(config, claims, System.system_time(:second))
      _ -> {:error, :identity_unavailable}
    end
  end

  defp resolve(
         %{issuer: issuer, resource: resource},
         %{"active" => true, "iss" => token_issuer, "sub" => subject, "exp" => expiration} =
           claims,
         now
       )
       when token_issuer == issuer and is_binary(subject) and byte_size(subject) in 1..512 and
              is_integer(expiration) and expiration > now do
    with true <- resource in List.wrap(claims["aud"]),
         type when type in ["Bearer", "bearer"] <- claims["token_type"],
         true <- valid_start?(Map.fetch(claims, "nbf"), now),
         {:ok, principal} <- Resolver.resolve(%{issuer: issuer, subject: subject}) do
      if is_binary(claims["scope"]) and @scope in String.split(claims["scope"]),
        do: {:ok, {principal, subject}},
        else: {:error, :insufficient_scope}
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp resolve(_config, _claims, _now), do: {:error, :invalid_token}

  defp valid_start?(:error, _now), do: true
  defp valid_start?({:ok, start}, now), do: is_integer(start) and start <= now

  defp credential?(value), do: is_binary(value) and byte_size(value) in 1..1024

  defp https_uri(value) when is_binary(value) and byte_size(value) in 1..2048 do
    with false <- String.contains?(value, ["\"", "\\"]),
         {:ok, %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil} = uri} <-
           URI.new(value),
         true <- is_binary(host) and host != "" do
      uri
    end
  end

  defp https_uri(_value), do: nil
end
