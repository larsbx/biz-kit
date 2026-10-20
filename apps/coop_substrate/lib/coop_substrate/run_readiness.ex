defmodule CoopSubstrate.RunReadiness do
  @moduledoc """
  Governance defines readiness for a workflow run's tasks at once
  (docs/architecture/2026-10-20-run-readiness.md): one `TaskReadinessDefinedV1`
  per task of the run that is proposed or queued and has none yet, held as
  one batch for a governance key to sign. A run follows one SOP, optionally
  at a named version (docs/architecture/2026-10-20-sprucegoose-salvage.md): a
  later batch, for tasks proposed later, must name the SOP and version an
  earlier one did.

  What the blueprint fixed is filled in, not chosen: each task's
  predecessors (the run's own tasks) and the names of its inputs. Governance
  supplies only digests: one per input, per task, and the SOP the run
  follows. The ledger admits each definition by the usual rules
  (`TaskCore.Readiness`, `TaskCore.Hierarchy.keeps_blueprint/3`).
  """

  alias CoopSubstrate.{Commands, Log}

  @doc """
  The run's tasks readiness can be defined for now, in task ID order:
  `{task_id, task}` for each that is proposed or queued without readiness.
  """
  def pending(o, {chapter, tenant, project}, run) do
    for(
      {{^chapter, ^tenant, ^project, id}, %{blueprint: %{run_event_id: ^run}} = task} <-
        o.tasks,
      task.state in ~w(proposed queued),
      not Map.has_key?(task, :readiness),
      do: {id, task}
    )
    # A map's order is not its keys' order past 32 entries.
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc """
  Hold the run's readiness definitions for `governance_key_id` to sign.
  `inputs` gives, per task ID, a digest for each input name its blueprint
  requires; `sop` is the SOP's digest, and `version` its version, if
  named. Digests are 32 bytes.
  """
  @spec prepare(
          TaskCore.State.scope(),
          String.t(),
          binary(),
          map(),
          String.t(),
          String.t() | nil
        ) ::
          {:ok, %{id: String.t(), commands: [map()], expires_at: integer()}} | {:error, term()}
  def prepare(
        {chapter, tenant, project} = scope,
        run,
        sop,
        inputs,
        governance_key_id,
        version \\ nil
      ) do
    o = Log.gate().orchestration
    pending = pending(o, scope, run)

    with true <- pending != [] or {:error, :nothing_to_define},
         true <- match?(<<_::256>>, sop) or {:error, :bad_request},
         true <- sop(o, scope, run) in [nil, {sop, version}] or {:error, :sop_mismatch},
         {:ok, commands} <- commands(pending, tenant, project, {sop, version}, inputs),
         {:ok, signer} <- Commands.governance_signer(chapter, governance_key_id) do
      Commands.hold_batch({:run_readiness, scope, run}, chapter, commands, signer)
    end
  end

  @doc """
  The SOP the run's tasks were already readied under, if any, as
  `{digest, version}`: a run follows one SOP, so a later batch (tasks
  proposed later) must name it too.
  """
  def sop(o, {chapter, tenant, project}, run) do
    Enum.find_value(o.tasks, fn
      {{^chapter, ^tenant, ^project, _}, %{blueprint: %{run_event_id: ^run}, readiness: r}} ->
        {elem(r.sop_digest, 1), r[:sop_version]}

      _ ->
        nil
    end)
  end

  @doc "Submit one signature per held definition, appended together."
  def define(scope, run, held_id, signatures),
    do: Commands.submit_batch({:run_readiness, scope, run}, held_id, signatures)

  defp commands(pending, tenant, project, {digest, version}, inputs) do
    Enum.reduce_while(pending, {:ok, []}, fn {id, task}, {:ok, acc} ->
      names = task.blueprint.artifact_requirements
      given = (is_map(inputs) && inputs[id]) || %{}

      if Enum.all?(names, &match?(<<_::256>>, given[&1])) do
        command =
          {"TaskReadinessDefinedV1",
           %{
             "tenant_id" => tenant,
             "project_id" => project,
             "task_id" => id,
             "expected_version" => task.version,
             "artifact_requirements" => Map.new(names, &{&1, {:bytes, given[&1]}}),
             "predecessor_ids" => task.blueprint.predecessor_ids,
             "sop_digest" => {:bytes, digest}
           }
           |> then(&if(version, do: Map.put(&1, "sop_version", version), else: &1))}

        {:cont, {:ok, acc ++ [command]}}
      else
        {:halt, {:error, :missing_input}}
      end
    end)
  end
end
