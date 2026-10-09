defmodule Eatsbot.Geocoding do
  @moduledoc """
  Module for geocoding. It uses the Nominatim API as a fallback. It can be changed through config.
  """
  @max_body_bytes 256 * 1024

  defmodule ResponseTooLargeError do
    defexception message: "Geocoding response exceeds 256 KiB"
  end

  defmodule ProviderError do
    defexception [:status]

    @impl true
    def message(%{status: status}), do: "Geocoding provider returned HTTP #{status}"
  end

  def query(query_string) do
    case Eatsbot.GeocodingStore.get_cached(query_string) do
      {:ok, result} -> result
      _ -> fetch_from_provider(query_string)
    end
  end

  defp fetch_from_provider(query_string) do
    endpoint =
      Application.get_env(
        :eatsbot,
        :geocoding_endpoint,
        "https://nominatim.openstreetmap.org/search"
      )

    token = Application.get_env(:eatsbot, :geocoding_token, nil)

    # add token if it exists, for compatible API services such as LocationIQ
    params = [q: query_string, format: "json"] ++ if token, do: [token: token], else: []

    response =
      Application.get_env(:eatsbot, :req_impl, Req).get!(endpoint,
        params: params,
        compressed: false,
        decode_body: false,
        redirect: false,
        retry: false,
        receive_timeout: 5_000,
        request_timeout: 10_000,
        into: &collect_response/2
      )

    if Map.get(response, :status, 200) != 200 do
      raise ProviderError, status: response.status
    end

    # Streaming disables Req's automatic decoding. Decode only bounded JSON.
    body = if is_binary(response.body), do: Jason.decode!(response.body), else: response.body
    [result | _tail] = body

    Eatsbot.GeocodingStore.save_in_cache(query_string, result)
    result
  end

  defp collect_response({:data, data}, {request, response}) do
    if byte_size(response.body) + byte_size(data) > @max_body_bytes do
      raise ResponseTooLargeError
    end

    {:cont, {request, %{response | body: response.body <> data}}}
  end
end

defmodule Eatsbot.GeocodingStore do
  @moduledoc """
  ETS cache for the Eatsbot.Geocoding module. Should be migrated to Postgres in the future.
  """
  @table_name :geocoding_cache

  def init do
    :ets.new(@table_name, [:set, :public, :named_table])
  end

  def save_in_cache(query, result) do
    :ets.insert(@table_name, {query, result})
  end

  def get_cached(query) do
    case :ets.lookup(@table_name, query) do
      [{_query, result}] -> {:ok, result}
      [] -> :error
    end
  end
end
