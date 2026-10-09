defmodule CoopSubstrate.Membership.Lifecycle do
  @moduledoc """
  The membership state machine (hand-off §2.2), as a pure, exhaustive
  transition table. Anything not declared here is illegal and is rejected at
  the append gate — before persistence — so the eternal log never contains an
  illegal transition (docs/phase1b_plan.md; the flagged AshStateMachine
  deviation is recorded there and in SUBSTRATE.md).

      (none) --MembershipInvited-->          invited
      invited --MembershipProbationStarted--> probationary
      probationary --MembershipConfirmed-->   member
      invited | probationary | member | in_cure | hardship --MembershipDeparted--> departed
      member --MembershipRetired-->           retired
      member | in_cure --MembershipFloorExited--> floor_exited
      probationary | member | in_cure | hardship --MembershipDeceased--> deceased
      member --FloorCureStarted-->            in_cure
      in_cure --FloorCureCleared-->           member
      member --HardshipDeclared-->            hardship
      hardship --HardshipEnded-->             member

  Terminal states (departed, retired, floor_exited, deceased) are the
  redeemable-account states; no lifecycle event leaves them (re-joining is a
  flagged open question, not allowed in 1B/1C). `in_cure` and `hardship` are
  the Phase 1C floor machinery (docs/phase1c_plan.md; hand-off §2.4):
  hardship suspends floor evaluation, cure is the window before floor exit.
  """

  @type state ::
          :invited
          | :probationary
          | :member
          | :in_cure
          | :hardship
          | :departed
          | :retired
          | :floor_exited
          | :deceased

  # event type => {legal from-states (nil = no membership yet), to-state}
  @table %{
    "MembershipInvited" => {[nil], :invited},
    "MembershipProbationStarted" => {[:invited], :probationary},
    "MembershipConfirmed" => {[:probationary], :member},
    "MembershipDeparted" =>
      {[:invited, :probationary, :member, :in_cure, :hardship], :departed},
    "MembershipRetired" => {[:member], :retired},
    "MembershipFloorExited" => {[:member, :in_cure], :floor_exited},
    "MembershipDeceased" => {[:probationary, :member, :in_cure, :hardship], :deceased},
    "FloorCureStarted" => {[:member], :in_cure},
    "FloorCureCleared" => {[:in_cure], :member},
    "HardshipDeclared" => {[:member], :hardship},
    "HardshipEnded" => {[:hardship], :member}
  }

  @states @table |> Map.values() |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
  @terminal [:departed, :retired, :floor_exited, :deceased]

  @spec states() :: [state()]
  def states, do: @states

  @spec event_types() :: [String.t()]
  def event_types, do: Map.keys(@table)

  @spec lifecycle_event?(String.t()) :: boolean()
  def lifecycle_event?(type), do: Map.has_key?(@table, type)

  @doc """
  Apply one lifecycle event to the current state (`nil` = no membership
  record exists yet). Total: every illegal pair returns an error naming the
  event and the state it was attempted from.
  """
  @spec apply(state() | nil, String.t()) ::
          {:ok, state()} | {:error, term()}
  def apply(state, event_type) do
    case Map.fetch(@table, event_type) do
      :error ->
        {:error, {:not_a_lifecycle_event, event_type}}

      {:ok, {from_states, to_state}} ->
        if state in from_states do
          {:ok, to_state}
        else
          {:error, {:illegal_transition, event_type, state}}
        end
    end
  end

  @doc "The state a lifecycle event transitions INTO (state-independent)."
  @spec target(String.t()) :: {:ok, state()} | {:error, term()}
  def target(event_type) do
    case Map.fetch(@table, event_type) do
      {:ok, {_from_states, to_state}} -> {:ok, to_state}
      :error -> {:error, {:not_a_lifecycle_event, event_type}}
    end
  end

  @doc "Terminal = redeemable-account state (acceptance item 10)."
  @spec terminal?(state()) :: boolean()
  def terminal?(state), do: state in @terminal

  @doc """
  May this membership accrue patronage/throughput? `probationary` counting
  (1B) and `in_cure`/`hardship` counting (1C — a member curing or in
  hardship keeps accruing) are **PLACEHOLDER governance semantics — awaiting
  charter declaration** (docs/phase1b_plan.md, docs/phase1c_plan.md).
  """
  @spec active?(state() | nil) :: boolean()
  def active?(state), do: state in [:probationary, :member, :in_cure, :hardship]

  @doc "Hardship suspends floor evaluation (docs/phase1c_plan.md); cure does not."
  @spec floor_suspended?(state() | nil) :: boolean()
  def floor_suspended?(state), do: state == :hardship
end
