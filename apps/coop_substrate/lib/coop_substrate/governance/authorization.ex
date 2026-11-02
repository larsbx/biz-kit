defmodule CoopSubstrate.Governance.Authorization do
  @moduledoc """
  The transport-independent CoopGovernance header codec, shared by hosts and
  the operator client. It accepts each named field once, in any order, and
  leaves freshness, chapter authority and nonce consumption to Governance.Read.
  """

  @fields ~w(key ts nonce sig)
  @parameters ~r/\A\s*[a-z]+="[^"]*"(?:\s*,\s*[a-z]+="[^"]*"){3}\s*\z/
  @parameter ~r/([a-z]+)="([^"]*)"/

  @doc "Decode a header bound to the actual HTTP method and path."
  def parse("CoopGovernance " <> params, method, path) do
    with {:ok, fields} <- fields(params),
         {timestamp, ""} <- Integer.parse(fields["ts"]),
         true <- timestamp in 0..9_223_372_036_854_775_807,
         {:ok, <<_::512>> = signature} <- Base.url_decode64(fields["sig"], padding: false) do
      request = %{
        method: method,
        path: path,
        timestamp_ms: timestamp,
        nonce: fields["nonce"],
        key_id: fields["key"]
      }

      {:ok, request, signature}
    else
      _ -> {:error, :malformed_authorization}
    end
  end

  def parse(_, _, _), do: {:error, :malformed_authorization}

  @doc "Encode the canonical header used by the operator client."
  def encode(request, signature) do
    sig = Base.url_encode64(signature, padding: false)

    ~s(CoopGovernance key="#{request.key_id}", ts="#{request.timestamp_ms}", ) <>
      ~s(nonce="#{request.nonce}", sig="#{sig}")
  end

  defp fields(params) do
    if Regex.match?(@parameters, params) do
      Enum.reduce_while(Regex.scan(@parameter, params), {:ok, %{}}, fn
        [_, key, value], {:ok, fields} when key in @fields ->
          if Map.has_key?(fields, key),
            do: {:halt, {:error, :malformed_authorization}},
            else: {:cont, {:ok, Map.put(fields, key, value)}}

        _, _ ->
          {:halt, {:error, :malformed_authorization}}
      end)
    else
      {:error, :malformed_authorization}
    end
  end
end
