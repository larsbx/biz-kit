defmodule CoopSubstrate.Protocol.EnvelopeTest do
  use ExUnit.Case, async: true

  alias CoopSubstrate.Canonical
  alias CoopSubstrate.Crypto
  alias CoopSubstrate.Protocol.Envelope
  alias CoopSubstrate.Protocol.TypeRegistry
  alias CoopSubstrate.ULID

  @vectors_path Path.expand("vectors/canonical_v1_vectors.json", __DIR__)

  defp keypair, do: Crypto.generate_keypair()

  defp base_attrs(pub, opts \\ []) do
    Map.merge(
      %{
        chapter_id: "chapter-test",
        type: "TestProjectionEvent",
        payload: %{"note" => "hello", "amount_minor" => 100},
        signers: [%{role: "author", pubkey: pub, key_id: "k1"}],
        timestamp_ms: 1_720_000_000_000
      },
      Map.new(opts)
    )
  end

  # -- construction ------------------------------------------------------------

  test "new/1 builds a validated envelope with a generated ULID event_id" do
    {pub, _seed} = keypair()
    assert {:ok, env} = Envelope.new(base_attrs(pub))
    assert ULID.valid?(env.event_id)
    assert env.stream_id == nil and env.global_seq == nil
    assert {:ok, "chapter-test/test"} = Envelope.stream_id(env)
  end

  test "construction rejections" do
    {pub, _seed} = keypair()
    signer = %{role: "author", pubkey: pub, key_id: "k1"}

    rejects = [
      {[type: "NoSuchEvent"], :unknown_type},
      {[payload: %{"note" => "x"}], {:payload_invalid, {:missing_fields, ["amount_minor"]}}},
      {[payload: %{"note" => "x", "amount_minor" => 1, "extra" => 2}],
       {:payload_invalid, {:unknown_fields, ["extra"]}}},
      {[payload: %{"note" => "x", "amount_minor" => 1.5}],
       {:payload_invalid, {:bad_field, "amount_minor"}}},
      {[chapter_id: nil], :chapter_id_required},
      {[chapter_id: ""], :chapter_id_required},
      {[timestamp_ms: nil], :bad_timestamp},
      {[timestamp_ms: -5], :bad_timestamp},
      {[event_id: "not-a-ulid"], :bad_event_id},
      {[auth_ref: "short"], :bad_auth_ref},
      {[signers: []], :signers_required},
      {[signers: [%{signer | pubkey: <<0>>}]], :bad_signer},
      {[signers: [signer, signer]], :duplicate_key_id}
    ]

    for {overrides, expected} <- rejects do
      assert {:error, ^expected} = Envelope.new(base_attrs(pub, overrides)),
             "expected #{inspect(expected)} for #{inspect(overrides)}"
    end

    assert {:error, {:roles_mismatch, _}} =
             Envelope.new(base_attrs(pub, signers: [%{signer | role: "witness"}]))
  end

  test "auth_ref accepts a 32-byte hash and lands in the signed core" do
    {pub, _seed} = keypair()
    ref = :crypto.hash(:sha256, "target")
    assert {:ok, env} = Envelope.new(base_attrs(pub, auth_ref: ref))
    assert Envelope.signed_core_term(env)["auth_ref"] == {:bytes, ref}
  end

  # -- signing & verification ---------------------------------------------------

  test "sign/verify roundtrip; completeness tracked" do
    {pub, seed} = keypair()
    {:ok, env} = Envelope.new(base_attrs(pub))

    refute Envelope.complete?(env)
    assert {:error, {:missing_signature, "k1"}} = Envelope.verify(env)

    assert {:ok, signed} = Envelope.sign(env, "k1", seed)
    assert Envelope.complete?(signed)
    assert :ok = Envelope.verify(signed)
  end

  test "signing with a seed that does not match the declared pubkey is rejected" do
    {pub, _seed} = keypair()
    {_other_pub, other_seed} = keypair()
    {:ok, env} = Envelope.new(base_attrs(pub))

    assert {:error, {:key_mismatch, "k1"}} = Envelope.sign(env, "k1", other_seed)
    assert {:error, {:unknown_signer, "nope"}} = Envelope.sign(env, "nope", other_seed)
  end

  test "tampering after signing breaks verification" do
    {pub, seed} = keypair()
    {:ok, env} = Envelope.new(base_attrs(pub))
    {:ok, signed} = Envelope.sign(env, "k1", seed)

    tampered = %{signed | payload: %{signed.payload | "amount_minor" => 999}}
    assert {:error, {:invalid_signature, "k1"}} = Envelope.verify(tampered)
  end

  test "attach_signature rejects invalid signatures at the door" do
    {pub, _seed} = keypair()
    {:ok, env} = Envelope.new(base_attrs(pub))

    assert {:error, {:invalid_signature, "k1"}} =
             Envelope.attach_signature(env, "k1", :binary.copy(<<0>>, 64))

    assert env.sigs == %{}
  end

  test "bilateral asynchronous dual signing (two roles, out-of-order attach)" do
    {author_pub, author_seed} = keypair()
    {cp_pub, cp_seed} = keypair()

    {:ok, env} =
      Envelope.new(%{
        chapter_id: "chapter-test",
        type: "TestBilateralEvent",
        payload: %{"terms" => "net-30", "amount_minor" => 250_000},
        signers: [
          %{role: "author", pubkey: author_pub, key_id: "author-key"},
          %{role: "counterparty", pubkey: cp_pub, key_id: "cp-key"}
        ],
        timestamp_ms: 1_720_000_000_000
      })

    # Counterparty signs the same sig-excluded bytes elsewhere, first.
    {:ok, bytes} = Envelope.signing_bytes(env)
    cp_sig = Crypto.sign(bytes, cp_seed)

    {:ok, env} = Envelope.attach_signature(env, "cp-key", cp_sig)
    refute Envelope.complete?(env)
    assert {:error, {:missing_signature, "author-key"}} = Envelope.verify(env)

    {:ok, env} = Envelope.sign(env, "author-key", author_seed)
    assert Envelope.complete?(env)
    assert :ok = Envelope.verify(env)
  end

  test "signature-set completeness follows the registry's declared roles" do
    {pub, _} = keypair()

    # single-role type must not declare a counterparty
    assert {:error, {:roles_mismatch, _}} =
             Envelope.new(
               base_attrs(pub,
                 signers: [
                   %{role: "author", pubkey: pub, key_id: "k1"},
                   %{role: "counterparty", pubkey: pub, key_id: "k2"}
                 ]
               )
             )

    # two-role type must declare both
    assert {:error, {:roles_mismatch, _}} =
             Envelope.new(%{
               chapter_id: "c",
               type: "TestBilateralEvent",
               payload: %{"terms" => "x", "amount_minor" => 1},
               signers: [%{role: "author", pubkey: pub, key_id: "k1"}],
               timestamp_ms: 0
             })
  end

  # -- committed vector reproduction ---------------------------------------------

  test "envelope construction reproduces the committed envelope-core vector exactly" do
    doc = JSON.decode!(File.read!(@vectors_path))
    vector = Enum.find(doc["vectors"], &(&1["name"] == "envelope-core"))

    seed = :binary.copy(<<0x42>>, 32)
    pub = Crypto.pubkey_from_seed(seed)

    {:ok, env} =
      Envelope.new(%{
        event_id: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
        chapter_id: "chapter-genesis",
        type: "TestProjectionEvent",
        payload: %{"note" => "vector fixture", "amount_minor" => 12_345},
        signers: [%{role: "author", pubkey: pub, key_id: "test-vector-key-1"}],
        timestamp_ms: 1_720_000_000_000
      })

    {:ok, bytes} = Envelope.signing_bytes(env)
    assert Base.encode16(bytes, case: :lower) == vector["canonical_hex"]

    {:ok, signed} = Envelope.sign(env, "test-vector-key-1", seed)

    assert Base.encode16(signed.sigs["test-vector-key-1"], case: :lower) ==
             vector["sig_hex"]

    assert :ok = Envelope.verify(signed)
  end

  # -- full record & event_hash ----------------------------------------------------

  test "event_hash covers signatures and chain fields" do
    {pub, seed} = keypair()
    {:ok, env} = Envelope.new(base_attrs(pub))
    {:ok, signed} = Envelope.sign(env, "k1", seed)
    {:ok, stream} = Envelope.stream_id(signed)

    appended = %{
      signed
      | stream_id: stream,
        stream_seq: 1,
        global_seq: 1,
        prev_stream_hash: nil,
        prev_global_hash: :crypto.hash(:sha256, "prior")
    }

    assert {:ok, <<_::256>> = hash} = Envelope.event_hash(appended)
    assert {:ok, ^hash} = Canonical.hash(Envelope.full_record_term(appended))

    # a different signature yields a different event_hash
    resigned = %{appended | sigs: %{"k1" => :binary.copy(<<1>>, 64)}}
    {:ok, other_hash} = Envelope.event_hash(resigned)
    refute other_hash == hash

    # so does a different chain position
    moved = %{appended | global_seq: 2}
    {:ok, moved_hash} = Envelope.event_hash(moved)
    refute moved_hash == hash
  end

  # -- registry ---------------------------------------------------------------------

  test "registry exposes bootstrap types and stream derivation" do
    for type <- ~w(TestProjectionEvent CorrectionRecorded KeyRotated CharterConstantDeclared) do
      assert TypeRegistry.registered?(type)
    end

    refute TypeRegistry.registered?("Unregistered")

    assert {:ok, "c1/keys/m-77"} =
             TypeRegistry.stream_id("KeyRotated", "c1", %{"member_id" => "m-77"})

    assert {:error, {:stream_field_missing, "member_id"}} =
             TypeRegistry.stream_id("KeyRotated", "c1", %{})

    assert {:ok, spec} = TypeRegistry.spec("KeyRotated")
    assert spec.disclosure_class == :commons
  end

  test "CharterConstantDeclared accepts any canonical value and optional note" do
    :ok =
      TypeRegistry.validate_payload("CharterConstantDeclared", %{
        "name" => "max_canonical_bytes",
        "value" => 65_536,
        "note" => "placeholder ratification fixture"
      })

    :ok =
      TypeRegistry.validate_payload("CharterConstantDeclared", %{
        "name" => "quorum",
        "value" => %{"numerator" => 2, "denominator" => 3}
      })
  end
  test "full record round-trips: encode -> strict decode -> same envelope" do
    {pub, seed} = keypair()
    {:ok, env} = Envelope.new(base_attrs(pub))
    {:ok, signed} = Envelope.sign(env, hd(env.signers).key_id, seed)

    appended =
      Envelope.with_log_assignment(signed, %{
        stream_id: "chapter-genesis/test",
        stream_seq: 1,
        global_seq: 1,
        prev_stream_hash: nil,
        prev_global_hash: nil
      })

    {:ok, bytes} = CoopSubstrate.Canonical.encode(Envelope.full_record_term(appended))
    {:ok, term} = CoopSubstrate.Canonical.decode(bytes)
    assert {:ok, rebuilt} = Envelope.from_full_record_term(term)
    assert rebuilt == appended
    assert Envelope.verify(rebuilt) == :ok
  end

  test "from_full_record_term rejects a foreign profile or schema version" do
    {pub, seed} = keypair()
    {:ok, env} = Envelope.new(base_attrs(pub))
    {:ok, signed} = Envelope.sign(env, hd(env.signers).key_id, seed)

    appended =
      Envelope.with_log_assignment(signed, %{
        stream_id: "chapter-genesis/test",
        stream_seq: 1,
        global_seq: 1,
        prev_stream_hash: nil,
        prev_global_hash: nil
      })

    term = Envelope.full_record_term(appended)

    assert {:error, {:unsupported_profile, _}} =
             Envelope.from_full_record_term(%{term | "canonical_profile" => "V2"})

    assert {:error, {:unsupported_schema_version, _}} =
             Envelope.from_full_record_term(%{term | "schema_version" => "EventEnvelopeV9"})
  end
end
