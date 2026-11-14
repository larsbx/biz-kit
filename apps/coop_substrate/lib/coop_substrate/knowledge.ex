defmodule CoopSubstrate.Knowledge do
  @moduledoc """
  Hold exact project knowledge decisions for an administrator to sign.

  Drafts are derived by TaskCore.Knowledge; reading them appends nothing. A
  review binds the shown snapshot, source fingerprints and review version.
  The append gate rechecks those bindings and current governance authority.
  Browser holds also retain the authenticated session owner, so dropping a
  cookie cannot turn a browser review into an unbound script submission.
  """

  alias CoopSubstrate.{Commands, Log}
  alias TaskCore.Knowledge, as: Core

  @shown_fields ~w(expected_review_version generator_version source_fingerprint draft_digest snapshot)

  @doc "Prepare exactly the review shown to the caller, without signing or applying it."
  def prepare(scope, candidate_id, decision, reason, shown, governance_key_id, binding \\ :cli) do
    gate = Log.gate()
    {chapter, _, _} = scope

    with {:ok, payload} <-
           Core.review_payload(gate.orchestration, scope, candidate_id, decision, reason),
         :ok <- matches_shown(payload, shown),
         {:ok, signer} <- Commands.governance_signer(chapter, governance_key_id),
         :ok <- binding_current(gate, scope, binding, governance_key_id) do
      Commands.hold(
        owner(scope, candidate_id, binding),
        chapter,
        "KnowledgeCandidateReviewedV1",
        payload,
        signer
      )
    end
  end

  @doc "The held review's signer, visible only to the same scope/candidate/session owner."
  def signer(scope, candidate_id, held_id, binding \\ :cli) do
    with {:ok, [%{signers: [%{role: "governance", key_id: key_id}]}]} <-
           Commands.peek(owner(scope, candidate_id, binding), held_id) do
      {:ok, key_id}
    else
      {:error, _} = error -> error
      _ -> {:error, :unknown_command}
    end
  end

  @doc "Submit one governance signature; browser principal/key binding is checked at admission."
  def submit(scope, candidate_id, held_id, signature, binding \\ :cli, opts \\ []) do
    with {:ok, key_id} <- signer(scope, candidate_id, held_id, binding),
         {:ok, [env]} <-
           Commands.submit_batch(owner(scope, candidate_id, binding), held_id, [signature],
             guard:
               Keyword.get(opts, :guard, {__MODULE__, :binding_current, [scope, binding, key_id]})
           ) do
      {:ok, env}
    end
  end

  @doc false
  def binding_current(_gate, _scope, :cli, _key_id), do: :ok

  def binding_current(gate, {chapter, _, _}, {:session, principal, _session}, key_id) do
    if gate.role_key_members[{chapter, "governance", key_id}] == principal and
         Map.has_key?(gate.role_keys[{chapter, "governance"}] || %{}, key_id),
       do: :ok,
       else: {:error, :needs_administrator}
  end

  def binding_current(_, _, _, _), do: {:error, :needs_administrator}

  @doc "The exact read-side fields a client must send back before a review can be held."
  def shown(payload) do
    payload
    |> Map.take(@shown_fields)
    |> Map.update!("source_fingerprint", &hex/1)
    |> Map.update!("draft_digest", &hex/1)
  end

  @doc "A signing client's exact decision/scope comparison, independent of transport."
  def expected?(
        %{
          "type" => "KnowledgeCandidateReviewedV1",
          "chapter_id" => chapter,
          "payload" => payload
        },
        {chapter, tenant, project},
        expected
      ) do
    payload === expected and payload["tenant_id"] == tenant and payload["project_id"] == project
  end

  def expected?(_, _, _), do: false

  defp matches_shown(payload, shown) when is_map(shown) do
    if shown(payload) === shown,
      do: :ok,
      else: {:error, :stale_knowledge_preview}
  end

  defp matches_shown(_, _), do: {:error, :bad_request}

  defp owner(scope, candidate_id, binding), do: {:knowledge_review, scope, candidate_id, binding}
  defp hex({:bytes, digest}), do: Base.encode16(digest, case: :lower)
end
