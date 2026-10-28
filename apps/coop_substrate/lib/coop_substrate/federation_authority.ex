defmodule CoopSubstrate.FederationAuthority do
  @moduledoc """
  Signed, chapter-scoped authority for one local subscription control activity.

  A grant is an admitted governance-signed envelope, not a transport receipt.
  Its event ID is the opaque receipt retained by the discovery journal. The
  trusted host pins `chapter_id`, `local_actor`, an EventStore SQL connection
  and its schema in the port returned by `port/1`. No remote actor chooses them.

  Admission and each delivery attempt run under the canonical ledger row lock,
  through the appender. Revocation ordered first refuses the effect; an effect
  ordered first may finish before revocation commits. An HTTP request already
  started cannot be recalled. No remote exactly-once guarantee is implied.
  """
  alias CoopSubstrate.Protocol.Envelope
  @scope "public_subscription_control"
  @grant "FederationSubscriptionGrantedV1"
  @revoke "FederationSubscriptionRevokedV1"

  def event_types do
    %{
      @grant => %{
        required_roles: ["governance"],
        disclosure_class: :own_data,
        stream: {:chapter_scoped, "federation-authority"},
        payload: %{
          required: %{
            "local_actor" => :string,
            "follow_id" => :string,
            "activity_id" => :string,
            "operation" => :string,
            "scope" => :string,
            "not_before" => :int,
            "expires_at" => :int
          },
          optional: %{}
        }
      },
      @revoke => %{
        required_roles: ["governance"],
        disclosure_class: :own_data,
        stream: {:chapter_scoped, "federation-authority"},
        payload: %{required: %{"grant_event_id" => :string}, optional: %{}}
      }
    }
  end

  def check(%Envelope{type: @grant, payload: p} = env, gate) do
    with :ok <- declared_signer(env, gate),
         true <- p["scope"] == @scope and p["operation"] in ~w(accept reject undo),
         true <- Enum.all?(~w(local_actor follow_id activity_id), &https?(p[&1])),
         true <- URI.parse(p["local_actor"]).host == URI.parse(p["activity_id"]).host,
         true <- p["not_before"] >= 0 and p["expires_at"] > p["not_before"],
         true <- p["expires_at"] > div(env.timestamp_ms, 1000),
         false <- Map.has_key?(gate.federation_grants, {env.chapter_id, env.event_id}) do
      :ok
    else
      _ -> {:error, :invalid_federation_grant}
    end
  end

  def check(%Envelope{type: @revoke, payload: p, chapter_id: ch} = env, gate) do
    with :ok <- declared_signer(env, gate),
         %{active: true} <- gate.federation_grants[{ch, p["grant_event_id"]}] do
      :ok
    else
      _ -> {:error, :invalid_federation_revocation}
    end
  end

  def fold(%Envelope{type: @grant} = env, state),
    do:
      put_in(state, [:federation_grants, Access.key({env.chapter_id, env.event_id})], %{
        envelope: env,
        active: true
      })

  def fold(%Envelope{type: @revoke, chapter_id: ch, payload: p}, state),
    do: put_in(state, [:federation_grants, {ch, p["grant_event_id"]}, :active], false)

  # Revoking and re-declaring the identical key never resurrects old grants.
  def revoke_key(state, chapter, key_id) do
    update_in(state.federation_grants, fn grants ->
      Map.new(grants, fn {{ch, _} = id, row} ->
        revoked = ch == chapter and Enum.any?(row.envelope.signers, &(&1.key_id == key_id))
        {id, if(revoked, do: %{row | active: false}, else: row)}
      end)
    end)
  end

  @doc "A host-only authority port for FederationService.config!/1."
  def port(opts) do
    context = Map.new(opts)
    true = is_binary(context.chapter_id) and is_binary(context.local_actor)
    true = is_pid(context.connection) or is_atom(context.connection)
    schema = Map.get(context, :schema, "public")
    true = is_binary(schema) and Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, schema)
    context = Map.put(context, :schema, schema)
    fn request, effect -> CoopSubstrate.Log.federation_effect(context, request, effect) end
  end

  @doc false
  def authorize(gate, context, request, now) do
    with true <- request.local_actor == context.local_actor,
         %{active: true, envelope: env} <-
           gate.federation_grants[{context.chapter_id, request.receipt}],
         :ok <- Envelope.verify(env),
         :ok <- declared_signer(env, gate),
         p <- env.payload,
         true <- p["local_actor"] == request.local_actor and p["follow_id"] == request.follow_id,
         true <-
           p["activity_id"] == request.activity_id and
             p["operation"] == to_string(request.operation),
         true <- p["scope"] == @scope and p["not_before"] <= now and now < p["expires_at"] do
      :ok
    else
      _ -> {:error, :unverified_local_authority}
    end
  rescue
    _ -> {:error, :unverified_local_authority}
  end

  defp declared_signer(%Envelope{chapter_id: ch, signers: [%{role: "governance"} = s]}, gate) do
    if get_in(gate.role_keys, [{ch, "governance"}, s.key_id]) == s.pubkey,
      do: :ok,
      else: {:error, :not_declared_governance}
  end

  defp declared_signer(_, _), do: {:error, :not_declared_governance}

  defp https?(value) when is_binary(value) and byte_size(value) in 1..2048 do
    case URI.new(value) do
      {:ok,
       %URI{scheme: "https", host: host, port: 443, userinfo: nil, query: nil, fragment: nil}} ->
        is_binary(host) and host != ""

      _ ->
        false
    end
  end

  defp https?(_), do: false
end
