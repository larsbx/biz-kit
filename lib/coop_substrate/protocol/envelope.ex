defmodule CoopSubstrate.Protocol.Envelope do
  @moduledoc """
  Event Envelope V1 (SUBSTRATE.md §2).

  Certificate-transparency-shaped split (the flagged deviation from the
  hand-off sketch — docs/phase1a_plan.md):

    * **Signed core** — what every signer signs: `canonical_profile`,
      `schema_version`, `event_id` (ULID), `chapter_id`, `type`, `payload`,
      `signers` (ordered, role-tagged `{role, pubkey, key_id}`), optional
      `auth_ref` (hash-pointer to the authorizing event), `timestamp_ms`.
      Stream identity is derivable from `type` + `payload` + `chapter_id`,
      so signers bind to it implicitly.
    * **Signature set** — stored BESIDE the core, never inside the signed
      bytes. All signers sign the same sig-excluded canonical bytes; a
      counterparty can sign asynchronously (bilateral dual signing).
    * **Log-assigned fields** — `stream_id`, `stream_seq`, `global_seq`,
      `prev_stream_hash`, `prev_global_hash`: assigned at append, never
      signed by authors. History integrity comes from the dual hash-chains;
      author authenticity from the signatures over the core.

  `event_hash` = SHA-256 over the canonical encoding of the FULL record
  (core + signature set + chain fields), so the chains are tamper-evident
  over signatures too.

  Timestamps are author-asserted claims; ordering authority is sequence,
  never wall-clock.
  """

  alias CoopSubstrate.Canonical
  alias CoopSubstrate.Constants
  alias CoopSubstrate.Crypto
  alias CoopSubstrate.Protocol.TypeRegistry
  alias CoopSubstrate.ULID

  @enforce_keys [:event_id, :chapter_id, :type, :payload, :signers, :timestamp_ms]
  defstruct [
    # signed core
    :event_id,
    :chapter_id,
    :type,
    :payload,
    :signers,
    :timestamp_ms,
    auth_ref: nil,
    # signature set: %{key_id => 64-byte sig}; canonical order is signer order
    sigs: %{},
    # log-assigned (nil until append; step 6)
    stream_id: nil,
    stream_seq: nil,
    global_seq: nil,
    prev_stream_hash: nil,
    prev_global_hash: nil
  ]

  @type signer :: %{role: String.t(), pubkey: <<_::256>>, key_id: String.t()}
  @type t :: %__MODULE__{}

  @doc """
  Build a validated, unsigned envelope. Validates: type registered, payload
  schema (unknown fields rejected), signer set matches the type's declared
  roles exactly, auth_ref shape, timestamp, and that the signed core
  canonically encodes (size/depth caps included).
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs = Map.new(attrs)

    envelope = %__MODULE__{
      event_id: Map.get_lazy(attrs, :event_id, &ULID.generate/0),
      chapter_id: Map.get(attrs, :chapter_id),
      type: Map.get(attrs, :type),
      payload: Map.get(attrs, :payload),
      signers: Map.get(attrs, :signers),
      auth_ref: Map.get(attrs, :auth_ref),
      timestamp_ms: Map.get(attrs, :timestamp_ms)
    }

    with :ok <- validate_core(envelope),
         {:ok, _bytes} <- signing_bytes(envelope) do
      {:ok, envelope}
    end
  end

  @doc "The canonical logical term every signer signs (sig-excluded core)."
  @spec signed_core_term(t()) :: map()
  def signed_core_term(%__MODULE__{} = env) do
    %{
      "auth_ref" => if(env.auth_ref, do: {:bytes, env.auth_ref}),
      "canonical_profile" => Constants.canonical_profile(),
      "chapter_id" => env.chapter_id,
      "event_id" => env.event_id,
      "payload" => env.payload,
      "schema_version" => Constants.envelope_schema_version(),
      "signers" =>
        Enum.map(env.signers, fn s ->
          %{"key_id" => s.key_id, "pubkey" => {:bytes, s.pubkey}, "role" => s.role}
        end),
      "timestamp_ms" => env.timestamp_ms,
      "type" => env.type
    }
  end

  @spec signing_bytes(t()) :: {:ok, binary()} | {:error, term()}
  def signing_bytes(%__MODULE__{} = env) do
    case Canonical.encode(signed_core_term(env)) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, {:encoding, reason}}
    end
  end

  @doc """
  Sign as the declared signer `key_id` with `seed`. Rejects a seed whose
  derived public key differs from the declared one.
  """
  @spec sign(t(), String.t(), <<_::256>>) :: {:ok, t()} | {:error, term()}
  def sign(%__MODULE__{} = env, key_id, seed) do
    with {:ok, signer} <- fetch_signer(env, key_id),
         :ok <- check_seed(signer, seed),
         {:ok, bytes} <- signing_bytes(env) do
      {:ok, %{env | sigs: Map.put(env.sigs, key_id, Crypto.sign(bytes, seed))}}
    end
  end

  @doc """
  Attach a signature produced elsewhere (asynchronous counterparty signing).
  Invalid signatures are rejected at the door, never stored.
  """
  @spec attach_signature(t(), String.t(), binary()) :: {:ok, t()} | {:error, term()}
  def attach_signature(%__MODULE__{} = env, key_id, sig) do
    with {:ok, signer} <- fetch_signer(env, key_id),
         {:ok, bytes} <- signing_bytes(env) do
      if Crypto.verify(bytes, sig, signer.pubkey) do
        {:ok, %{env | sigs: Map.put(env.sigs, key_id, sig)}}
      else
        {:error, {:invalid_signature, key_id}}
      end
    end
  end

  @doc "True when every declared signer has signed."
  @spec complete?(t()) :: boolean()
  def complete?(%__MODULE__{} = env) do
    Enum.all?(env.signers, &Map.has_key?(env.sigs, &1.key_id))
  end

  @doc """
  Full verification of a (possibly wire-received) envelope: structural
  validity, canonical encodability, signature-set completeness against the
  type's declared roles, and every signature valid over the re-encoded core.
  """
  @spec verify(t()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = env) do
    with :ok <- validate_core(env),
         {:ok, bytes} <- signing_bytes(env) do
      Enum.find_value(env.signers, :ok, fn signer ->
        case Map.fetch(env.sigs, signer.key_id) do
          :error ->
            {:error, {:missing_signature, signer.key_id}}

          {:ok, sig} ->
            unless Crypto.verify(bytes, sig, signer.pubkey) do
              {:error, {:invalid_signature, signer.key_id}}
            end
        end
      end)
    end
  end

  @doc "Stream identity, derived — never author-supplied (07 P7)."
  @spec stream_id(t()) :: {:ok, String.t()} | {:error, term()}
  def stream_id(%__MODULE__{} = env) do
    TypeRegistry.stream_id(env.type, env.chapter_id, env.payload)
  end

  @doc """
  Canonical logical term of the FULL record — core + ordered signature set +
  log-assigned chain fields. Only meaningful once the log has assigned
  sequence/chain fields (step 6); `event_hash` is SHA-256 over its encoding.
  """
  @spec full_record_term(t()) :: map()
  def full_record_term(%__MODULE__{} = env) do
    signed_core_term(env)
    |> Map.merge(%{
      "sigs" =>
        Enum.map(env.signers, fn s ->
          %{"key_id" => s.key_id, "sig" => {:bytes, Map.fetch!(env.sigs, s.key_id)}}
        end),
      "stream_id" => env.stream_id,
      "stream_seq" => env.stream_seq,
      "global_seq" => env.global_seq,
      "prev_stream_hash" => if(env.prev_stream_hash, do: {:bytes, env.prev_stream_hash}),
      "prev_global_hash" => if(env.prev_global_hash, do: {:bytes, env.prev_global_hash})
    })
  end

  @spec event_hash(t()) :: {:ok, <<_::256>>} | {:error, term()}
  def event_hash(%__MODULE__{} = env) do
    case Canonical.hash(full_record_term(env)) do
      {:ok, digest} -> {:ok, digest}
      {:error, reason} -> {:error, {:encoding, reason}}
    end
  end

  # -- validation --------------------------------------------------------------

  defp validate_core(env) do
    cond do
      not (is_binary(env.chapter_id) and env.chapter_id != "" and String.valid?(env.chapter_id)) ->
        {:error, :chapter_id_required}

      not ULID.valid?(env.event_id) ->
        {:error, :bad_event_id}

      not (is_integer(env.timestamp_ms) and env.timestamp_ms >= 0) ->
        {:error, :bad_timestamp}

      not (env.auth_ref == nil or match?(<<_::256>>, env.auth_ref)) ->
        {:error, :bad_auth_ref}

      true ->
        with :ok <- TypeRegistry.validate_payload(env.type, env.payload),
             :ok <- validate_signers(env),
             {:ok, _stream} <- stream_id(env) do
          :ok
        end
    end
  end

  defp validate_signers(env) do
    {:ok, spec} = TypeRegistry.spec(env.type)

    cond do
      not (is_list(env.signers) and env.signers != []) ->
        {:error, :signers_required}

      not Enum.all?(env.signers, &valid_signer?/1) ->
        {:error, :bad_signer}

      env.signers |> Enum.map(& &1.key_id) |> Enum.uniq() |> length() != length(env.signers) ->
        {:error, :duplicate_key_id}

      Enum.sort(Enum.uniq(Enum.map(env.signers, & &1.role))) != Enum.sort(spec.required_roles) ->
        {:error,
         {:roles_mismatch,
          declared: Enum.sort(Enum.uniq(Enum.map(env.signers, & &1.role))),
          required: Enum.sort(spec.required_roles)}}

      true ->
        :ok
    end
  end

  defp valid_signer?(%{role: role, pubkey: <<_::256>>, key_id: key_id})
       when is_binary(role) and role != "" and is_binary(key_id) and key_id != "",
       do: true

  defp valid_signer?(_), do: false

  defp fetch_signer(env, key_id) do
    case Enum.find(env.signers, &(&1.key_id == key_id)) do
      nil -> {:error, {:unknown_signer, key_id}}
      signer -> {:ok, signer}
    end
  end

  defp check_seed(signer, seed) do
    if Crypto.pubkey_from_seed(seed) == signer.pubkey do
      :ok
    else
      {:error, {:key_mismatch, signer.key_id}}
    end
  end
end
