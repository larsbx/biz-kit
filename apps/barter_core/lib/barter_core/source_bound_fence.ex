defmodule BarterCore.SourceBoundFence do
  @moduledoc """
  In-memory REFERENCE model of future source-bound commercial business admission.

  An actual production command MUST NOT call this model for authorization:
  its state is caller-controlled and its booleans are untrusted assertions.
  It neither authenticates evidence nor appends to CoopSubstrate.Log.

  The formal Lean/Quint models prove only an atomic source-consumption rule
  under independently established evidence. The source identity is
  {chapter, obligation ID}, not the monetary amount or its revision.
  Re-using a different revision of the same obligation is therefore blocked.

  No bank instructions, regulated credit, custody, legal discharge or
  financial settlement is represented. The canonical business-log append
  gate and Hawala's financial authority remain unchanged.
  """

  @schema "bizkit.commercial.source-fence.reference.v1"
  @source_keys ~w(id revision digest)a
  @plan_keys ~w(chapter intent_id sources)a
  @checks ~w(source_authenticated consents_verified agency_verified
              legal_effect_verified policy_allowed)a
  @maximum 9_007_199_254_740_991

  def new do
    %{schema: @schema, intents: %{}, consumed: %{}, commits: 0}
  end

  @doc """
  Preview a single atomic, business-only admission under externally assumed
  checks. Every check is a TEST ASSUMPTION, not a verified credential.
  Exact replay stutters. An intent changed under the same ID conflicts.
  """
  def admit(state, plan, checks) do
    with :ok <- validate_state(state),
         {:ok, sources, digest, key} <- validate_plan(plan),
         :ok <- validate_checks(checks) do
      case Map.fetch(state.intents, key) do
        {:ok, ^digest} ->
          {:ok, state, receipt(:reference_replay_only, digest)}

        {:ok, _different} ->
          {:error, :intent_digest_conflict}

        :error ->
          with :ok <- require_verified(checks),
               :ok <- require_unconsumed(state, plan.chapter, sources) do
            consumed =
              Enum.reduce(sources, state.consumed, fn source, acc ->
                Map.put(acc, {plan.chapter, source.id}, key)
              end)

            next = %{
              state
              | intents: Map.put(state.intents, key, digest),
                consumed: consumed,
                commits: state.commits + 1
            }

            {:ok, next, receipt(:reference_admitted_not_authoritative, digest)}
          end
      end
    end
  end

  defp receipt(status, digest) do
    %{
      status: status,
      commitment: digest,
      legal_discharge: :not_established,
      financial_settlement: :none,
      authoritative_ledger_append: false
    }
  end

  defp validate_state(%{
         schema: @schema,
         intents: intents,
         consumed: consumed,
         commits: commits
       })
       when is_map(intents) and is_map(consumed) and is_integer(commits) and commits >= 0,
       do: :ok

  defp validate_state(_), do: {:error, :invalid_reference_state}

  defp validate_plan(%{} = plan) do
    if Enum.sort(Map.keys(plan)) == Enum.sort(@plan_keys) and
         is_binary(plan.chapter) and plan.chapter != "" and
         is_binary(plan.intent_id) and plan.intent_id != "" and
         is_list(plan.sources) and plan.sources != [] and
         length(plan.sources) <= 256 do
      case normalize_sources(plan.sources) do
        {:ok, sources} ->
          fields = [
            @schema,
            plan.chapter,
            plan.intent_id,
            Integer.to_string(length(sources))
          ]

          fields =
            fields ++
              Enum.flat_map(sources, fn source ->
                [
                  source.id,
                  Integer.to_string(source.revision),
                  Base.encode16(source.digest, case: :lower)
                ]
              end)

          {:ok, sources, BarterCore.digest(fields), {plan.chapter, plan.intent_id}}

        error ->
          error
      end
    else
      {:error, :invalid_reference_plan}
    end
  end

  defp validate_plan(_), do: {:error, :invalid_reference_plan}

  defp normalize_sources(sources) do
    if Enum.all?(sources, &valid_source?/1) do
      sorted = Enum.sort_by(sources, & &1.id)
      ids = Enum.map(sorted, & &1.id)

      if ids == Enum.uniq(ids) do
        {:ok, sorted}
      else
        {:error, :duplicate_source_id}
      end
    else
      {:error, :invalid_source}
    end
  end

  defp valid_source?(%{} = source) do
    Enum.sort(Map.keys(source)) == Enum.sort(@source_keys) and
      is_binary(source.id) and source.id != "" and
      is_integer(source.revision) and source.revision > 0 and
      source.revision <= @maximum and match?(<<_::256>>, source.digest)
  end

  defp valid_source?(_), do: false

  defp validate_checks(%{} = checks) do
    if Enum.sort(Map.keys(checks)) == Enum.sort(@checks) and
         Enum.all?(Map.values(checks), &is_boolean/1) do
      :ok
    else
      {:error, :invalid_assumed_checks}
    end
  end

  defp validate_checks(_), do: {:error, :invalid_assumed_checks}

  defp require_verified(checks) do
    if Enum.all?(@checks, &Map.fetch!(checks, &1)) do
      :ok
    else
      {:error, :unverified_external_premise}
    end
  end

  defp require_unconsumed(state, chapter, sources) do
    case Enum.find(sources, &Map.has_key?(state.consumed, {chapter, &1.id})) do
      nil -> :ok
      source -> {:error, {:source_already_consumed, {chapter, source.id}}}
    end
  end
end
