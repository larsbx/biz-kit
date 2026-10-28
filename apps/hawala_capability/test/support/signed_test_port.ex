defmodule HawalaCapability.SignedTestPort do
  @moduledoc "TEST-only signed local endpoint codec. Never financial evidence."
  @request "hawala/TEST-endpoints/request/v1\0"
  @response "hawala/TEST-endpoints/response/v1\0"
  @id_domain "hawala/TEST-outbox/id/v1\0"
  def public(seed), do: elem(:crypto.generate_key(:eddsa, :ed25519, seed), 0)
  def hash(bytes), do: :crypto.hash(:sha256, bytes)

  def request_id(c, n) when is_integer(n) and n > 0 and n < 18_446_744_073_709_551_616,
    do: hash(@id_domain <> c.attempt <> c.binding <> <<n::64>>)

  def pin(c),
    do: hash(public(c.seed) <> c.service <> c.grant <> <<c.epoch::64>> <> c.attempt <> c.binding)

  def request(c, op, n, now)
      when op in 1..4 and is_integer(n) and n > 0 and n < 18_446_744_073_709_551_616 and
             is_integer(now) and now >= 0 and now <= 18_446_744_073_709_551_555 do
    b =
      @request <>
        <<op>> <>
        c.service <>
        public(c.seed) <>
        c.grant <>
        <<c.epoch::64>> <>
        request_id(c, n) <> c.attempt <> c.binding <> <<now::64, now + 60::64>>

    b <> :crypto.sign(:eddsa, :none, b, [c.seed, :ed25519])
  end

  def verify_request(raw, c, n) do
    case raw do
      <<@request, op, service::binary-size(32), host::binary-size(32), grant::binary-size(32),
        epoch::64, id::binary-size(32), attempt::binary-size(32), binding::binary-size(32),
        issued::64, expires::64, signature::binary-size(64)>>
      when op in 1..4 ->
        b = binary_part(raw, 0, byte_size(raw) - 64)

        if service == c.service and host == public(c.seed) and grant == c.grant and
             epoch == c.epoch and
             id == request_id(c, n) and attempt == c.attempt and binding == c.binding and
             expires > issued and expires - issued <= 60 and
             :crypto.verify(:eddsa, :none, b, signature, [host, :ed25519]),
           do: {:ok, op},
           else: {:error, :binding}

      _ ->
        {:error, :request_shape}
    end
  end

  def verify_response(raw, request, c) do
    case raw do
      <<@response, service::binary-size(32), call::binary-size(32), attempt::binary-size(32),
        binding::binary-size(32), stage, held, 0, 0, epoch::64, signature::binary-size(64)>>
      when stage in 0..3 and held in 0..1 ->
        b = binary_part(raw, 0, byte_size(raw) - 64)

        if service == c.service and call == hash(request) and attempt == c.attempt and
             binding == c.binding and
             epoch == c.epoch and
             :crypto.verify(:eddsa, :none, b, signature, [c.service, :ed25519]),
           do: {:ok, %{stage: stage, held: held == 1}},
           else: {:error, :response_binding}

      _ ->
        {:error, :non_test_or_malformed_response}
    end
  end

  def exchange(socket, raw, timeout \\ 1500) do
    base = [:binary, active: false, packet: 4, packet_size: 4096, send_timeout: timeout]

    connection =
      case socket do
        {:loopback, port} when is_integer(port) and port in 1..65535 ->
          :gen_tcp.connect({127, 0, 0, 1}, port, base, timeout)

        path when is_binary(path) ->
          :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [:local | base], timeout)
      end

    case connection do
      {:ok, conn} ->
        try do
          with :ok <- :gen_tcp.send(conn, raw), do: :gen_tcp.recv(conn, 0, timeout)
        after
          :gen_tcp.close(conn)
        end

      error ->
        error
    end
  end
end
