defmodule HalaqaSignedDraft do
  @moduledoc """
  Independent, offline Elixir decoder/verifier of the proposed signed draft.
  No Python calls, network, canonical admission, persistence or effect API.
  All identity/context inputs are explicit TEST policy assertions.
  """
  @max_integer 9_007_199_254_740_991
  @domain "halaqa.federation.signed-experiment/draft-1\0"
  @token ~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/
  @digest ~r/\Asha256:[0-9a-f]{64}\z/
  @envelope ~w(schema candidate key_id issued_at expires_at signature)
  @candidate ~w(schema message_id halaqa_id charter_hash epoch sender recipient kind parents payload payload_hash)
  @policy ~w(sender recipient halaqa_id charter_hash epoch key_id public_key now revoked)
  @verdict "SIGNATURE_VALID_AUTHORITY_UNVERIFIED"

  def verify(wire, policy) do
    try do
      public_key = policy!(policy)
      require!(is_binary(wire) and byte_size(wire) in 1..12_288, "signed_wire_limit")
      envelope = json!(wire)
      fields!(envelope, @envelope, "signed_fields")

      require!(
        envelope["schema"] == "halaqa-federation-signed-experiment/draft-1",
        "signed_schema"
      )

      key_id = envelope["key_id"]
      require!(token?(key_id), "signed_key")
      issued = envelope["issued_at"]
      expires = envelope["expires_at"]

      require!(
        uint?(issued) and uint?(expires) and issued < expires and expires - issued <= 300,
        "signed_time"
      )

      candidate_bytes = base64!(envelope["candidate"], "signed_encoding")
      signature = base64!(envelope["signature"], "signed_encoding", 64)
      {message, payload} = candidate!(candidate_bytes)

      require!(
        key_id == policy["key_id"] and message["sender"] == policy["sender"],
        "test_key_binding"
      )

      require!(not policy["revoked"], "test_key_revoked")

      require!(
        Enum.all?(~w(recipient halaqa_id charter_hash epoch), &(message[&1] == policy[&1])),
        "test_context"
      )

      require!(issued <= policy["now"] and policy["now"] < expires, "test_expiry")

      transcript =
        <<@domain::binary, byte_size(key_id)::unsigned-big-32, key_id::binary,
          issued::unsigned-big-64, expires::unsigned-big-64,
          byte_size(candidate_bytes)::unsigned-big-32, candidate_bytes::binary>>

      valid = :crypto.verify(:eddsa, :none, transcript, signature, [public_key, :ed25519])
      require!(valid, "invalid_signature")

      {:ok,
       %{
         verdict: @verdict,
         payload: payload,
         transcript: transcript,
         authority_verified: false,
         production_receiver: false
       }}
    catch
      {:refused, reason} -> {:error, reason}
    end
  end

  def check_corpus(path) do
    bytes = File.read!(path)
    require!(byte_size(bytes) <= 2_000_000, "corpus_limit")
    corpus = json!(bytes)
    fields!(corpus, ~w(schema scope vectors), "corpus")
    require!(corpus["schema"] == "halaqa-federation-signed-vectors/draft-1", "corpus")
    require!(corpus["scope"] == "offline-signed-test-only", "corpus")
    vectors = corpus["vectors"]
    require!(is_list(vectors) and vectors != [], "corpus")

    {counts, _names} =
      Enum.reduce(
        vectors,
        {%{@verdict => 0, "REFUSED_SIGNED_TEST" => 0}, MapSet.new()},
        fn vector, {counts, names} ->
          fields!(
            vector,
            ~w(name wire_base64 test_policy expected reason payload_base64 transcript_base64),
            "corpus"
          )

          name = vector["name"]
          require!(token?(name) and not MapSet.member?(names, name), "corpus")
          expected = vector["expected"]
          require!(expected in [@verdict, "REFUSED_SIGNED_TEST"], "corpus")
          wire = base64!(vector["wire_base64"], "corpus")

          case verify(wire, vector["test_policy"]) do
            {:ok, result} ->
              require!(
                expected == @verdict and vector["reason"] == :null and
                  Base.encode64(result.payload) == vector["payload_base64"] and
                  Base.encode64(result.transcript) == vector["transcript_base64"],
                "corpus_disagreement:" <> name
              )

            {:error, reason} ->
              require!(
                expected == "REFUSED_SIGNED_TEST" and vector["reason"] == reason and
                  vector["payload_base64"] == :null and vector["transcript_base64"] == :null,
                "corpus_disagreement:" <> name <> ":" <> reason
              )
          end

          {Map.update!(counts, expected, &(&1 + 1)), MapSet.put(names, name)}
        end
      )

    require!(Enum.all?(Map.values(counts), &(&1 > 0)), "corpus")

    %{
      "scope" => "offline-signed-test-only",
      "implementation" => "independent-elixir",
      "counts" => counts,
      "authority_verified" => false,
      "production_receiver" => false
    }
  end

  def json!(bytes) do
    require!(String.valid?(bytes) and depth?(bytes, 0, false, false), "invalid_json")

    decoders = %{
      object_start: fn _ -> %{} end,
      object_push: fn key, value, acc ->
        require!(not Map.has_key?(acc, key), "duplicate_key")
        Map.put(acc, key, value)
      end,
      object_finish: fn acc, old -> {acc, old} end
    }

    try do
      {value, _acc, rest} = :json.decode(bytes, nil, decoders)
      require!(String.trim(rest) == "", "invalid_json")
      value
    rescue
      _ -> refuse!("invalid_json")
    end
  end

  defp policy!(policy) do
    fields!(policy, @policy, "test_policy")
    require!(Enum.all?(~w(sender recipient halaqa_id key_id), &token?(policy[&1])), "test_policy")

    require!(
      digest?(policy["charter_hash"]) and uint?(policy["epoch"]) and
        uint?(policy["now"]) and is_boolean(policy["revoked"]),
      "test_policy"
    )

    base64!(policy["public_key"], "signed_encoding", 32)
  end

  defp candidate!(bytes) do
    require!(byte_size(bytes) in 1..8192, "wire_limit")
    message = json!(bytes)
    fields!(message, @candidate, "fields")
    require!(message["schema"] == "halaqa-federation-candidate/draft-0", "schema")

    require!(
      Enum.all?(~w(message_id halaqa_id sender recipient), &token?(message[&1])),
      "identifier"
    )

    require!(
      digest?(message["charter_hash"]) and digest?(message["payload_hash"]),
      "digest_format"
    )

    require!(uint?(message["epoch"]), "epoch")
    require!(message["kind"] in ["proposal", "public_activity"], "kind")
    parents = message["parents"]
    require!(is_list(parents) and length(parents) <= 16, "parents")
    require!(Enum.all?(parents, &digest?/1), "parents")
    require!(parents == Enum.sort(Enum.uniq(parents)), "parents")
    payload = base64!(message["payload"], "payload_encoding")
    require!(byte_size(payload) in 1..4096, "payload_limit")
    digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, payload), case: :lower)
    require!(digest == message["payload_hash"], "payload_digest")
    {message, payload}
  end

  defp fields!(value, fields, reason) do
    require!(is_map(value) and MapSet.new(Map.keys(value)) == MapSet.new(fields), reason)
  end

  defp token?(value), do: is_binary(value) and Regex.match?(@token, value)
  defp digest?(value), do: is_binary(value) and Regex.match?(@digest, value)
  defp uint?(value), do: is_integer(value) and value >= 0 and value <= @max_integer

  defp base64!(value, reason, size \\ nil) do
    require!(is_binary(value), reason)

    case Base.decode64(value) do
      {:ok, bytes} ->
        require!(
          Base.encode64(bytes) == value and (size == nil or byte_size(bytes) == size),
          reason
        )

        bytes

      :error ->
        refuse!(reason)
    end
  end

  defp require!(true, _reason), do: :ok
  defp require!(false, reason), do: refuse!(reason)
  defp refuse!(reason), do: throw({:refused, reason})

  defp depth?(_, n, _, _) when n > 8 or n < 0, do: false
  defp depth?(<<>>, 0, false, _), do: true
  defp depth?(<<>>, _, _, _), do: false
  defp depth?(<<_, rest::binary>>, n, true, true), do: depth?(rest, n, true, false)
  defp depth?(<<92, rest::binary>>, n, true, false), do: depth?(rest, n, true, true)
  defp depth?(<<34, rest::binary>>, n, quoted, false), do: depth?(rest, n, not quoted, false)

  defp depth?(<<c, rest::binary>>, n, false, false) when c in [123, 91],
    do: depth?(rest, n + 1, false, false)

  defp depth?(<<c, rest::binary>>, n, false, false) when c in [125, 93],
    do: depth?(rest, n - 1, false, false)

  defp depth?(<<_, rest::binary>>, n, quoted, escaped), do: depth?(rest, n, quoted, escaped)
end
