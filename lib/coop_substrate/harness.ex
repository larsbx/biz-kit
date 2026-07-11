defmodule CoopSubstrate.Harness do
  @moduledoc """
  Queryable harness gate (Phase 2A; corpus 11 §2): `gate(section)` and its
  input counts, each a deterministic replay of the gate fold —
  as-of-reproducible, revocation-excluded, failing closed until the charter
  constants (`harness/<section>/{n,c,d}` and `k`) are declared.
  """

  alias CoopSubstrate.Crypto
  alias CoopSubstrate.Harness.Artifacts
  alias CoopSubstrate.Log
  alias CoopSubstrate.Projections.Membership
  alias CoopSubstrate.Protocol.Envelope
  alias CoopSubstrate.ULID

  @doc "Does gate(section) hold? Supports `as_of:`. Fails closed on undeclared constants."
  @spec gate(String.t(), String.t(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def gate(chapter_id, section, opts \\ []) do
    with {:ok, state} <- Log.replay(Membership, opts) do
      Membership.harness_gate(state, chapter_id, section)
    end
  end

  @doc "The gate's inputs (interviews/corroborated/documents/adopted/fixtures). Supports `as_of:`."
  @spec counts(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def counts(chapter_id, section, opts \\ []) do
    with {:ok, state} <- Log.replay(Membership, opts),
         {:ok, constants} <- Membership.harness_constants(state, chapter_id, section) do
      {:ok, Membership.harness_counts(state, chapter_id, section, constants.k)}
    end
  end

  @doc """
  Document/recording intake (Phase 2B): store the binary out-of-log
  (content-addressed, `Harness.Artifacts`) and append the gated
  `DocumentCollected` in one step. The gate enforces consent — including
  recording consent for `doc_kind: "recording"`.
  """
  @spec collect_document(String.t(), String.t(), String.t(), binary(), String.t(), <<_::256>>) ::
          {:ok, %{document_id: String.t(), artifact_hash: <<_::256>>}} | {:error, term()}
  def collect_document(chapter_id, interview_ref, doc_kind, binary, key_id, seed) do
    document_id = ULID.generate()

    with {:ok, artifact_hash} <- Artifacts.put(binary),
         {:ok, envelope} <-
           Envelope.new(%{
             chapter_id: chapter_id,
             type: "DocumentCollected",
             payload: %{
               "document_id" => document_id,
               "interview_ref" => interview_ref,
               "doc_kind" => doc_kind,
               "artifact_hash" => {:bytes, artifact_hash}
             },
             signers: [
               %{role: "steward", pubkey: Crypto.pubkey_from_seed(seed), key_id: key_id}
             ],
             timestamp_ms: System.system_time(:millisecond)
           }),
         {:ok, signed} <- Envelope.sign(envelope, key_id, seed),
         {:ok, _} <- Log.append(signed) do
      {:ok, %{document_id: document_id, artifact_hash: artifact_hash}}
    end
  end
end
