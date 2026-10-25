defmodule FederationService.Network do
  @moduledoc """
  Bounded HTTPS/1.1 transport. Resolve once, reject the entire answer set if
  any address is not globally routable, connect the approved IP tuple directly,
  and verify TLS against the original DNS name. No proxy, redirect, context
  expansion, compression, connection reuse or secondary DNS lookup.
  """
  import Bitwise

  def uri(url) when is_binary(url) and byte_size(url) <= 2048 do
    case URI.parse(url) do
      %URI{
        scheme: "https",
        host: host,
        port: 443,
        userinfo: nil,
        fragment: nil,
        query: nil,
        path: path
      } = u
      when is_binary(host) and is_binary(path) and path != "" ->
        if Regex.match?(~r/\A[a-z0-9]+(?:[.-][a-z0-9]+)*\.[a-z][a-z0-9-]*\z/, host) and
             not String.ends_with?(host, [".local", ".internal", ".localhost"]) and
             Regex.match?(~r/\A\/[A-Za-z0-9\/._~-]*\z/, path) and
             not Enum.any?(String.split(path, "/"), &(&1 in [".", ".."])) do
          {:ok, u}
        else
          {:error, :unsafe_url}
        end

      _ ->
        {:error, :unsafe_url}
    end
  end

  def uri(_), do: {:error, :unsafe_url}

  def same_origin(a, b) do
    with {:ok, x} <- uri(a),
         {:ok, y} <- uri(b),
         true <- x.host == y.host,
         do: :ok,
         else: (_ -> {:error, :origin_substitution})
  end

  def public_ip?({a, b, c, d}) when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 do
    ip = (a <<< 24) + (b <<< 16) + (c <<< 8) + d

    not Enum.any?(
      [
        {0, 8},
        {0x0A000000, 8},
        {0x64400000, 10},
        {0x7F000000, 8},
        {0xA9FE0000, 16},
        {0xAC100000, 12},
        {0xC0000000, 24},
        {0xC0000200, 24},
        {0xC0586300, 24},
        {0xC0A80000, 16},
        {0xC6120000, 15},
        {0xC6336400, 24},
        {0xCB007100, 24},
        {0xE0000000, 3}
      ],
      fn {net, n} -> ip >>> (32 - n) == net >>> (32 - n) end
    )
  end

  def public_ip?({a, b, _, _, _, _, _, _}) do
    # Only native global unicast; exclude Teredo, documentation, benchmarking,
    # ORCHID and 6to4 rather than accepting embedded IPv4 escape routes.
    a in 0x2000..0x3FFF and a != 0x2002 and
      not (a == 0x2001 and (b < 0x0200 or b == 0x0DB8)) and
      not (a == 0x3FFF and b <= 0x0FFF)
  end

  def public_ip?(_), do: false

  def resolve(host) do
    addresses =
      for family <- [:inet, :inet6],
          {:ok, ips} <- [:inet.getaddrs(String.to_charlist(host), family)],
          ip <- ips,
          do: ip

    validate_addresses(addresses)
  end

  def validate_addresses([]), do: {:error, :dns_unavailable}

  def validate_addresses(ips) do
    if Enum.all?(ips, &public_ip?/1), do: {:ok, hd(ips), 443}, else: {:error, :private_address}
  end

  def request(method, url, headers, body, opts \\ []) do
    # The caller is never allowed to alter TLS policy or choose an IP from a
    # remote document. The test-only loopback connector is absent in prod.
    bounded(fn ->
      with {:ok, u} <- uri(url),
           {:ok, ip, port} <- destination(u.host, opts),
           {:ok, socket} <- :ssl.connect(ip, port, tls_options(u.host, opts), 2000) do
        try do
          request = [
            String.upcase(to_string(method)),
            " ",
            u.path,
            " HTTP/1.1\r\n",
            Enum.map(headers, fn {k, v} -> [k, ": ", v, "\r\n"] end),
            "connection: close\r\ncontent-length: ",
            Integer.to_string(byte_size(body)),
            "\r\n\r\n",
            body
          ]

          with :ok <- :ssl.send(socket, request), do: response(socket)
        after
          :ssl.close(socket)
        end
      end
    end)
  end

  defp bounded(fun) do
    parent = self()
    {pid, ref} = spawn_monitor(fn -> send(parent, {self(), fun.()}) end)

    receive do
      {^pid, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, _, _, _} ->
        {:error, :network_failure}
    after
      5000 ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, _, _, _} -> :ok
        end

        {:error, :network_timeout}
    end
  end

  defp destination(host, opts) do
    if Keyword.has_key?(opts, :test_routes), do: test_destination(host, opts), else: resolve(host)
  end

  if Mix.env() == :test do
    defp test_destination(host, opts) do
      case opts[:test_routes][host] do
        {ip, port} -> {:ok, ip, port}
        _ -> {:error, :unconfigured_test_peer}
      end
    end

    defp roots(opts), do: Keyword.get(opts, :test_cacerts, :public_key.cacerts_get())
  else
    defp test_destination(_, _), do: {:error, :test_transport_disabled}
    defp roots(_), do: :public_key.cacerts_get()
  end

  defp tls_options(host, opts) do
    [
      :binary,
      active: false,
      packet: :http_bin,
      packet_size: 8192,
      verify: :verify_peer,
      cacerts: roots(opts),
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
      versions: [:"tlsv1.3", :"tlsv1.2"]
    ]
  end

  defp response(socket) do
    with {:ok, {:http_response, _, status, _}} <- :ssl.recv(socket, 0, 2000),
         {:ok, headers} <- headers(socket, %{}, 0, 0),
         false <- Map.has_key?(headers, "transfer-encoding"),
         false <- Map.has_key?(headers, "content-encoding"),
         {len, ""} <- Integer.parse(Map.get(headers, "content-length", "invalid")),
         true <- len in 0..65_536,
         :ok <- :ssl.setopts(socket, packet: :raw),
         {:ok, body} <- read(socket, len) do
      {:ok, status, headers, body}
    else
      _ -> {:error, :invalid_http_response}
    end
  end

  defp read(_, 0), do: {:ok, ""}
  defp read(s, n), do: :ssl.recv(s, n, 2000)
  defp headers(_, _, n, bytes) when n > 40 or bytes > 16_384, do: {:error, :header_limit}

  defp headers(s, acc, n, bytes) do
    case :ssl.recv(s, 0, 2000) do
      {:ok, :http_eoh} ->
        {:ok, acc}

      {:ok, {:http_header, _, key, _, value}} ->
        key = key |> to_string() |> String.downcase()

        if Map.has_key?(acc, key),
          do: {:error, :duplicate_header},
          else:
            headers(s, Map.put(acc, key, value), n + 1, bytes + byte_size(value) + byte_size(key))

      _ ->
        {:error, :invalid_headers}
    end
  end

  def json(url, opts \\ []) do
    with {:ok, u} <- uri(url),
         {:ok, 200, h, body} <-
           request(
             :get,
             url,
             [{"host", u.host}, {"accept", "application/activity+json, application/json"}],
             "",
             opts
           ),
         true <-
           Map.get(h, "content-type", "")
           |> String.split(";")
           |> hd()
           |> String.trim()
           |> then(&(&1 in ["application/json", "application/activity+json"])),
         {:ok, value} <- FederationService.JSON.decode(body) do
      {:ok, value}
    else
      _ -> {:error, :remote_document_unavailable}
    end
  end
end
