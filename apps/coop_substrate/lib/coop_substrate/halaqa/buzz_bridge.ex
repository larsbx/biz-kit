defmodule CoopSubstrate.Halaqa.BuzzBridge do
  @moduledoc """
  Fail-closed boundary between signed Buzz collaboration events and the
  Halaqa/SANAD+ effect pipeline.

  This module is deliberately transport-neutral. Buzz supplies the signed
  collaboration input; this boundary derives a deterministic certificate and
  requires a durable pre-effect append before an adapter may execute.
  """

  alias CoopSubstrate.Canonical

  @type certificate :: %{
          effect_id: String.t(),
          effect: map(),
          effect_hash: binary(),
          resolution_hash: binary(),
          halaqa_id: String.t(),
          charter_hash: String.t(),
          epoch: non_neg_integer(),
          delegation_id: String.t()
        }

  @spec resolve(map()) :: {:admitted, certificate(), map()} | {:refused, atom(), map()}
  def resolve(input) when is_map(input) do
    case validate(input) do
      :ok -> admit(input)
      {:error, reason} -> {:refused, reason, refusal_card(input, reason)}
    end
  end

  @spec verify_effect(certificate(), map()) :: :ok | {:error, :effect_hash_mismatch}
  def verify_effect(certificate, effect) do
    if Canonical.hash!(effect) == certificate.effect_hash,
      do: :ok,
      else: {:error, :effect_hash_mismatch}
  end

  @doc "Append the authorization commitment before invoking the adapter."
  @spec commit_and_execute(certificate(), (map() -> term()), (map() -> term())) :: term()
  def commit_and_execute(certificate, append, execute)
      when is_function(append, 1) and is_function(execute, 1) do
    with :ok <- verify_effect(certificate, certificate.effect),
         :ok <- append.(%{kind: :pre_effect, certificate: certificate}) do
      execute.(certificate.effect)
    end
  end

  @doc "Reserve one effect identity, rejecting same-id/different-byte replay."
  @spec reserve(certificate(), map()) :: {:execute | :duplicate, map()} | {:error, atom()}
  def reserve(certificate, state) do
    case Map.fetch(state, certificate.effect_id) do
      :error -> {:execute, Map.put(state, certificate.effect_id, certificate.effect_hash)}
      {:ok, hash} when hash == certificate.effect_hash -> {:duplicate, state}
      {:ok, _other} -> {:error, :idempotency_conflict}
    end
  end

  @doc "Rebuild a disposable Buzz view without modifying canonical ledger input."
  def rebuild_projection(ledger, cards),
    do: %{ledger: ledger, cards: Enum.sort_by(cards, & &1["event_id"])}

  @spec delegate(map(), map()) :: {:ok, map()} | {:error, atom()}
  def delegate(input, child) do
    delegation = input["delegation"] || %{}
    child_class = child["class"]
    child_purpose = child["purpose"] || delegation["purpose"]

    cond do
      delegation["may_delegate"] != true ->
        {:error, :delegation_not_permitted}

      child_class not in (delegation["recipient_classes"] || []) ->
        {:error, :recipient_class_not_allowed}

      not is_integer(delegation["remaining_depth"]) or delegation["remaining_depth"] <= 0 ->
        {:error, :delegation_depth_exhausted}

      not purpose_within?(child_purpose, delegation["purpose"]) ->
        {:error, :purpose_amplification}

      true ->
        {:ok,
         %{
           "class" => child_class,
           "purpose" => child_purpose,
           "remaining_depth" => delegation["remaining_depth"] - 1,
           "parent_delegation_id" => delegation["id"]
         }}
    end
  end

  @spec apply_revocation([certificate()], String.t()) :: [certificate()]
  def apply_revocation(committed, _delegation_id), do: committed

  @spec invoke(map()) :: {:ok, map()} | {:error, atom()}
  def invoke(%{"orchestrator" => actor, "target" => actor}),
    do: {:error, :actor_separation_required}

  def invoke(
        %{"orchestrator" => orchestrator, "target" => target, "signatures" => signatures} =
          invocation
      )
      when orchestrator != target and is_list(signatures) and length(signatures) >= 2,
      do: {:ok, invocation}

  def invoke(_), do: {:error, :independent_signatures_required}

  defp validate(input) do
    delegation = input["delegation"]
    policy = input["policy"] || %{}

    cond do
      input["author_signature_valid"] != true ->
        {:error, :invalid_author_signature}

      input["member"] != true ->
        {:error, :not_member}

      not is_map(delegation) ->
        {:error, :missing_delegation}

      get_in(input, ["attestation", "type"]) != "TypedAttestation" ->
        {:error, :invalid_attestation}

      delegation["active"] != true ->
        {:error, :inactive_delegation}

      delegation["revoked"] == true ->
        {:error, :delegation_revoked}

      input["capability"] not in (delegation["capabilities"] || []) ->
        {:error, :capability_not_delegated}

      context_mismatch?(input, policy) ->
        {:error, :context_mismatch}

      input["evidence_grade"] < policy["min_evidence"] ->
        {:error, :insufficient_evidence}

      input["tool_sort"] not in policy["allowed_tools"] ->
        {:error, :tool_not_allowed}

      input["tool_sort"] not in (delegation["tools"] || []) ->
        {:error, :tool_not_delegated}

      delegation["delegate_class"] not in (delegation["recipient_classes"] || []) ->
        {:error, :recipient_class_not_allowed}

      delegation["basis"] == "constitutive" and blank?(delegation["office_ref"]) ->
        {:error, :missing_office_provenance}

      delegation["basis"] == "inherited" and
          not purpose_within?(delegation["purpose"], delegation["parent_purpose"]) ->
        {:error, :purpose_amplification}

      true ->
        :ok
    end
  end

  defp context_mismatch?(input, policy) do
    input["charter_hash"] != policy["current_charter_hash"] or
      input["epoch"] != policy["current_epoch"] or blank?(input["halaqa_id"])
  end

  defp admit(input) do
    effect_hash = Canonical.hash!(input["effect"])

    context = %{
      "halaqa_id" => input["halaqa_id"],
      "charter_hash" => input["charter_hash"],
      "epoch" => input["epoch"],
      "event_id" => input["event_id"],
      "delegation_id" => input["delegation"]["id"],
      "effect_hash" => {:bytes, effect_hash}
    }

    certificate = %{
      effect_id: input["event_id"],
      effect: input["effect"],
      effect_hash: effect_hash,
      resolution_hash: Canonical.hash!(context),
      halaqa_id: input["halaqa_id"],
      charter_hash: input["charter_hash"],
      epoch: input["epoch"],
      delegation_id: input["delegation"]["id"]
    }

    card = %{
      "kind" => "admitted",
      "event_id" => input["event_id"],
      "halaqa_id" => input["halaqa_id"],
      "resolution_hash" => Base.encode16(certificate.resolution_hash, case: :lower),
      "effect_hash" => Base.encode16(effect_hash, case: :lower)
    }

    {:admitted, certificate, card}
  end

  defp refusal_card(input, reason) do
    %{
      "kind" => "refused",
      "event_id" => input["event_id"],
      "halaqa_id" => input["halaqa_id"],
      "reason" => Atom.to_string(reason)
    }
  end

  defp purpose_within?(child, parent) when child == parent, do: true

  defp purpose_within?(child, parent) when is_binary(child) and is_binary(parent) do
    case String.split(parent, "*", parts: 2) do
      [prefix, ""] -> String.starts_with?(child, prefix)
      _ -> false
    end
  end

  defp purpose_within?(_, _), do: false
  defp blank?(value), do: value in [nil, ""]
end
