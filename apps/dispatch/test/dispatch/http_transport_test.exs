defmodule Dispatch.HTTPTransportTest do
  use ExUnit.Case, async: true

  @moduletag capture_log: true

  test "the production Finch pool can reach permitted loopback HTTP" do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :line,
        active: false,
        ip: {127, 0, 0, 1},
        reuseaddr: true
      ])

    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)

        try do
          {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
          assert request =~ "GET /work HTTP/1.1"
          :ok = consume_headers(socket)

          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok"
          )
        after
          :gen_tcp.close(socket)
        end
      end)

    assert {:ok, %Finch.Response{status: 200, body: "ok"}} =
             Finch.request(Finch.build(:get, "http://127.0.0.1:#{port}/work"), Dispatch.Finch)

    assert :ok = Task.await(server, 6_000)
  end

  defp consume_headers(socket) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, "\r\n"} -> :ok
      {:ok, _header} -> consume_headers(socket)
    end
  end

  test "the production Finch pool rejects an untrusted HTTPS certificate" do
    {port, server, _certificates} = tls_server()

    assert {:error, %{reason: {:tls_alert, {:unknown_ca, _}}}} =
             Finch.request(Finch.build(:get, "https://127.0.0.1:#{port}/work"), Dispatch.Finch)

    assert {:error, {:tls_alert, {:unknown_ca, _}}} = Task.await(server, 6_000)
  end

  test "the same verified TLS options reject a trusted certificate for another hostname" do
    {port, server, certificates} = tls_server()

    {:ok, %{default_pool_config: %{conn_opts: connection}}} =
      Registry.meta(Dispatch.Finch, :config)

    # Trust only this disposable test CA in an isolated pool. Keep every other
    # production TLS option, including verify_peer; never modify Dispatch.Finch.
    transport =
      connection
      |> Keyword.fetch!(:transport_opts)
      |> Keyword.delete(:cacertfile)
      |> Keyword.put(:cacerts, Keyword.fetch!(certificates, :cacerts))

    assert Keyword.fetch!(transport, :verify) == :verify_peer
    name = __MODULE__.TrustedCA

    start_supervised!(
      {Finch,
       name: name,
       pools: %{default: [conn_opts: Keyword.put(connection, :transport_opts, transport)]}}
    )

    assert {:error, %{reason: {:tls_alert, {:handshake_failure, reason}}}} =
             Finch.request(Finch.build(:get, "https://127.0.0.1:#{port}/work"), name)

    assert to_string(reason) =~ "hostname_check_failed"
    assert {:error, {:tls_alert, {:handshake_failure, _}}} = Task.await(server, 6_000)
  end

  defp tls_server do
    # OTP's test-chain generator uses the node hostname as its DNS subjectAltName,
    # which cannot authenticate the literal loopback IP used by these requests.
    # Fresh keys and certificates are generated for each test, never persisted.
    certificates =
      :public_key.pkix_test_data(%{
        root: [key: {:rsa, 2048, 65_537}, digest: :sha256],
        peer: [key: {:rsa, 2048, 65_537}, digest: :sha256]
      })

    {:ok, listener} =
      :ssl.listen(
        0,
        Keyword.take(certificates, [:cert, :key]) ++ [active: false, ip: {127, 0, 0, 1}]
      )

    on_exit(fn -> :ssl.close(listener) end)
    {:ok, {{127, 0, 0, 1}, port}} = :ssl.sockname(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :ssl.transport_accept(listener, 5_000)

        try do
          :ssl.handshake(socket, 5_000)
        after
          :ssl.close(socket)
        end
      end)

    {port, server, certificates}
  end
end
