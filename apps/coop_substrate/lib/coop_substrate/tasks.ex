defmodule CoopSubstrate.Tasks do
  @moduledoc """
  Bounded common-ledger task command: inbox -> proposed, lifecycle version 1.

  Governance records a baseline and a project-scoped operator signing key.
  The operator signs the command; the existing Log serializes admission and
  rechecks its grant and task version against committed state. No cooperative
  membership, Ash row, or local certified-event writer licenses this command.

  Baselines attest source state, not historical user approval. This path is for
  isolated cutover rehearsal until the complete production write surface is
  migrated and its old writer fenced.

  The rules are `TaskCore`'s (`TaskCore.Admission`, `TaskCore.State`); this
  module is the ledger's side: appending a command and answering a retried
  one. `CoopSubstrate.TaskHost` gives the rules the artifact store and the
  canonical hash.
  """

  alias CoopSubstrate.Log
  alias CoopSubstrate.Protocol.Envelope

  @doc "Build the unsigned command. Sign with Envelope.sign/3 before submitting."
  def proposal(attrs), do: Envelope.new(Map.put(Map.new(attrs), :type, "TaskProposedV1"))

  @doc "Append a proposal durably and return the accepted event/version watermark."
  def propose(command, server \\ Log.server())

  def propose(%Envelope{type: "TaskProposedV1"} = command, server), do: append(command, server)
  def propose(_command, _server), do: {:error, :not_a_task_proposal}

  @doc "Append a Definition of Done command durably, as `propose/2`."
  def submit(command, server \\ Log.server())

  def submit(%Envelope{type: type} = command, server) do
    if type in TaskCore.DoD.commands(),
      do: append(command, server),
      else: {:error, :not_a_dod_command}
  end

  def submit(_command, _server), do: {:error, :not_a_dod_command}

  defp append(command, server) do
    with {:ok, [accepted]} <- Log.append(command, server),
         {:ok, hash} <- Envelope.event_hash(accepted) do
      {:ok,
       %{
         event_id: accepted.event_id,
         event_hash: hash,
         global_seq: accepted.global_seq,
         task_version: accepted.payload["expected_version"] + 1
       }}
    end
  end

  @doc false
  def duplicate([%Envelope{} = env], state) do
    commands =
      state.proposals |> Map.merge(state.dod_commands) |> Map.merge(state.timing_commands)

    case Map.fetch(commands, env.event_id) do
      :error ->
        :new

      {:ok, accepted} ->
        if Envelope.signed_core_term(env) == Envelope.signed_core_term(accepted) and
             env.sigs == accepted.sigs,
           do: {:ok, [accepted]},
           else: {:error, {:reject, 0, :task_command_id_conflict}}
    end
  end

  def duplicate(_batch, _state), do: :new
end
