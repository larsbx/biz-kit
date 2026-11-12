defmodule Keel.ReleaseReview do
  @moduledoc """
  Signs a Keel decision bound to one Ship request and its source evidence.

  The caller supplies the governance snapshot and ballots from its admission
  layer. This module evaluates them and attests to the result. It grants no
  execution permission and does not authenticate the caller's inputs.
  """

  alias Keel.{Body, Decision, Org, Party}

  @domain "biz-kit.keel.release-review.v1"
  @binding ~w(request_id action target inventory generation release release_sha256 graft_evidence)
  @id ~r/\A[a-z][a-z0-9-]{0,63}\z/
  @hash ~r/\A[0-9a-f]{64}\z/
  @uuid ~r/\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/

  @doc "Evaluate an organization body and sign the exact bound outcome with Ed25519."
  def issue(%Org{} = org, body, votes, %Date{calendar: Calendar.ISO} = date, binding, key_id, seed)
      when is_binary(seed) and byte_size(seed) == 32 and date.year in 1..9999 do
    with true <- matches?(body, @id) and matches?(key_id, @id),
         true <- valid_binding?(binding),
         %Body{} <- Org.get(org, body),
         [] <- Keel.check(org),
         true <- valid_votes?(org, votes) do
      matter = if binding["action"] == "deploy", do: :deploy_release, else: :rollback_release
      {verdict, _tally} = Decision.decide(org, body, matter, votes, date)

      record =
        Map.merge(binding, %{
          "schema" => @domain,
          "repository" => "larsbx/biz-kit",
          "key_id" => key_id,
          "body" => body,
          "verdict" => Atom.to_string(verdict),
          "decision_date" => Date.to_iso8601(date),
          "policy_sha256" => term_digest(org),
          "ballots_sha256" => term_digest({body, date, binding, votes})
        })

      signature = :crypto.sign(:eddsa, :none, signing_bytes(record), [seed, :ed25519])
      {:ok, Map.put(record, "signature", Base.encode16(signature, case: :lower))}
    else
      _invalid -> {:error, :invalid_release_review_input}
    end
  end

  def issue(_, _, _, _, _, _, _), do: {:error, :invalid_release_review_input}

  @doc """
  Wire preimage for a validated record. LF separates fields and terminates the last.
  The caller must validate the schema and field syntax before using this encoder.
  """
  def signing_bytes(record) do
    fields =
      ~w(schema repository key_id body verdict decision_date policy_sha256 ballots_sha256) ++
        @binding

    Enum.map_join(fields, "", fn field -> to_string(Map.fetch!(record, field)) <> "\n" end)
  end

  defp valid_binding?(binding) when is_map(binding) do
    Enum.sort(Map.keys(binding)) == Enum.sort(@binding) and
      matches?(binding["request_id"], @uuid) and
      binding["action"] in ["deploy", "rollback"] and
      matches?(binding["target"], @id) and
      matches?(binding["release"], @id) and
      Enum.all?(~w(inventory release_sha256 graft_evidence), &matches?(binding[&1], @hash)) and
      is_integer(binding["generation"]) and binding["generation"] >= 0 and
      binding["generation"] <= 9_223_372_036_854_775_807
  end

  defp valid_binding?(_binding), do: false

  defp valid_votes?(org, votes) when is_map(votes) do
    Enum.all?(votes, fn {party, ballot} ->
      ballot in [:yes, :no, :abstain] and match?(%Party{}, Org.get(org, party))
    end)
  end

  defp valid_votes?(_org, _votes), do: false

  defp matches?(value, pattern), do: is_binary(value) and Regex.match?(pattern, value)

  defp term_digest(term) do
    encoded = :erlang.term_to_binary(term, [:deterministic])
    :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower)
  end
end
