defmodule TaskCore.ExecutionRecovery do
  @moduledoc """
  Generic recovery decisions over durable effect snapshots and host-verified
  backend observations. No backend, clock, database or business writer lives
  here. The host verifies observation provenance before calling this module;
  the store must enforce version/epoch CAS again when applying the decision.

  Expiry alone never authorizes relaunch. Unknown outcomes remain held.
  Absence must be final under the backend's durable idempotency contract,
  including in-flight launches and retained deduplication/tombstone records.
  Candidate custody is operational storage, never accepted business evidence.
  """

  @states [:running, :absent, :cancelled, :candidate]

  def decide(row, observation) when is_map(row) and is_map(observation) do
    with :ok <- binding(row, observation) do
      decision(row, observation)
    end
  end

  def decide(_row, _observation), do: {:error, :unverified_backend_outcome}

  defp binding(row, observation) do
    cond do
      not is_binary(row[:effect_id]) or byte_size(row.effect_id) not in 1..256 ->
        {:error, :invalid_effect_snapshot}

      not is_integer(row[:epoch]) or row.epoch < 1 or
        not is_integer(row[:version]) or row.version < 1 ->
        {:error, :invalid_effect_snapshot}

      observation[:effect_id] != row[:effect_id] ->
        {:error, :observation_effect_mismatch}

      observation[:epoch] != row[:epoch] ->
        {:error, :observation_epoch_mismatch}

      observation[:state] not in @states ->
        {:error, :unverified_backend_outcome}

      observation[:verified] != true ->
        {:error, :unverified_backend_outcome}

      observation.state != :running and observation[:final] != true ->
        {:error, :unverified_backend_outcome}

      not is_binary(observation[:receipt]) ->
        {:error, :invalid_observation_receipt}

      byte_size(observation.receipt) not in 1..65_536 ->
        {:error, :invalid_observation_receipt}

      row[:backend_ref] != nil and row.backend_ref != observation[:backend_ref] ->
        {:error, :observation_backend_mismatch}

      observation[:backend_ref] != nil and not reference?(observation.backend_ref) ->
        {:error, :invalid_backend_reference}

      observation.state != :absent and not reference?(observation[:backend_ref]) ->
        {:error, :invalid_backend_reference}

      observation.state == :candidate and not bounded_candidate?(row, observation) ->
        {:error, :candidate_not_verified_within_budget}

      true ->
        :ok
    end
  end

  defp decision(%{phase: "cancel_requested"}, %{state: state})
       when state in [:absent, :cancelled], do: {:ok, :confirm_cancel}

  defp decision(%{phase: "cancel_requested"}, _observation), do: {:ok, :request_termination}

  defp decision(%{phase: "leased", expired: true, deadline_expired: false}, %{state: :running}),
    do: {:ok, :adopt}

  defp decision(%{phase: "leased", expired: true, deadline_expired: false}, %{state: :absent}),
    do: {:ok, :retry_pending}

  defp decision(%{phase: "leased", expired: true}, %{state: :candidate}),
    do: {:ok, :recover_candidate}

  defp decision(%{phase: "leased", expired: true}, _observation),
    do: {:ok, :request_termination}

  defp decision(_row, _observation), do: {:error, :effect_not_recoverable}

  defp reference?(value),
    do: is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/, value)

  defp bounded_candidate?(row, observation) do
    observation[:within_budget] == true and is_binary(observation[:candidate_bytes]) and
      is_integer(row[:max_output_bytes]) and row.max_output_bytes in 1..16_777_216 and
      byte_size(observation.candidate_bytes) <= row.max_output_bytes
  end
end
