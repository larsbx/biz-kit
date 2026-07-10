defmodule CoopSubstrate.Privacy.Proof.TrustedAudit do
  @moduledoc """
  Day-one Proof backing (hand-off §4): trusted-but-auditable. A "proof" is
  the fact plus the log position it was checked at — any holder of the log
  re-derives the verdict deterministically; `verify/2` IS the audit (a full
  recomputation).

  Phase 1D closes the 1C flagged deviation: pass `sign_with: {key_id, seed}`
  in `private_inputs` and the assertion is signed with a `checkpoint`-role
  key; `verify/2` then additionally validates the signature against the
  fact's chapter registry **as of the pinned position** — the same
  discipline as `Log.verify_checkpoint/1`. Unsigned proofs (bootstrap, or a
  caller without the key) verify by recomputation alone, exactly as in 1C;
  whether a verifier should *demand* signatures post-bootstrap is the
  verifier's policy, not encoded here.
  """

  @behaviour CoopSubstrate.Privacy.Proof

  alias CoopSubstrate.Canonical
  alias CoopSubstrate.Capital
  alias CoopSubstrate.Crypto
  alias CoopSubstrate.Floor
  alias CoopSubstrate.Log
  alias CoopSubstrate.Projections.Membership

  @impl true
  def prove(fact, private_inputs) do
    as_of = Log.head().global_seq

    if holds?(fact, as_of) do
      {:ok, maybe_sign(%{fact: fact, as_of: as_of}, private_inputs)}
    else
      {:error, :fact_does_not_hold}
    end
  end

  @impl true
  def verify(fact, %{fact: fact, as_of: as_of, key_id: key_id, signature: signature}) do
    with {:ok, gate} <- Log.replay(Membership, as_of: as_of) do
      declared =
        Map.get(gate.role_keys[{chapter_of(fact), "checkpoint"}] || %{}, key_id)

      declared != nil and
        Crypto.verify(assertion_bytes(fact, as_of, key_id), signature, declared) and
        holds?(fact, as_of)
    else
      _ -> false
    end
  end

  def verify(fact, %{fact: fact, as_of: as_of} = proof) when not is_map_key(proof, :signature) do
    holds?(fact, as_of)
  end

  def verify(_fact, _proof), do: false

  defp maybe_sign(assertion, private_inputs) do
    case Keyword.get(private_inputs, :sign_with) do
      nil ->
        assertion

      {key_id, seed} ->
        signature =
          Crypto.sign(assertion_bytes(assertion.fact, assertion.as_of, key_id), seed)

        Map.merge(assertion, %{key_id: key_id, signature: signature})
    end
  end

  # The signed bytes: the assertion in canonical form (fact tuples become
  # lists — the profile has no tuples).
  defp assertion_bytes(fact, as_of, key_id) do
    [tag | rest] = Tuple.to_list(fact)

    Canonical.encode!(%{
      "fact" => [Atom.to_string(tag) | rest],
      "as_of" => as_of,
      "key_id" => key_id
    })
  end

  defp chapter_of(fact), do: elem(fact, 1)

  defp holds?({:floor_cleared, chapter, member, entity, at_ms}, as_of) do
    Floor.cleared?(chapter, member, entity, at: at_ms, as_of: as_of) == {:ok, true}
  end

  defp holds?({:balance_at_least, chapter, member, entity, min_minor}, as_of) do
    case Capital.balance(chapter, member, entity, as_of: as_of) do
      {:ok, balance} -> balance >= min_minor
      _ -> false
    end
  end

  defp holds?(_fact, _as_of), do: false
end
