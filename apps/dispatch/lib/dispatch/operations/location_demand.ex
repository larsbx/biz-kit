defmodule Dispatch.Operations.LocationDemand do
  @moduledoc """
  Whether anyone entitled to a participant's position is looking at it now
  (docs/architecture/2026-10-22-location-sharing.md, "Demand").

  A device shares in real time only while an authorized viewer is watching,
  and trickles otherwise. Authorized means a precise-location reader:
  `operations.location.precise.read`, the participant in the viewer's
  organization, and the participant's consent active now (Section 23.2: precise
  location needs the capability *and* consent).

  Watching is membership of an OTP `:pg` group per participant, joined by the
  viewer's live-stream process. `:pg` spans the cluster and drops a process
  when it exits, so a closed tab, a crashed stream or a lost node all end the
  watch without anyone remembering to. The device's demand stream monitors the
  group and learns of the first viewer and the last one at once.
  """

  require Ash.Query

  alias Dispatch.Access.Actor
  alias Dispatch.Accounts.Participant
  alias Dispatch.Operations.ConsentGrant

  @scope __MODULE__
  @precise "operations.location.precise.read"

  @defaults %{
    realtime: %{sample_interval_ms: 3_000, upload_interval_ms: 0},
    trickle: %{sample_interval_ms: 120_000, upload_interval_ms: 600_000}
  }

  @type mode :: :realtime | :trickle

  @doc "The `:pg` scope, started under the application."
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts), do: %{id: __MODULE__, start: {:pg, :start_link, [@scope]}}

  @doc """
  Whether `actor` may see `participant_id`'s position now: the capability, the
  same organization, and the participant's consent active.
  """
  @spec precise?(Actor.t(), Ash.UUID.t()) :: boolean()
  def precise?(%Actor{} = actor, participant_id) do
    Actor.can?(actor, @precise) and in_organization?(actor, participant_id) and
      consenting?(actor.tenant_id, participant_id)
  end

  @doc "Whether `participant_id` has a location consent active now."
  @spec consenting?(Ash.UUID.t(), Ash.UUID.t()) :: boolean()
  def consenting?(tenant_id, participant_id) do
    now = DateTime.utc_now()

    ConsentGrant
    |> Ash.Query.filter(participant_id == ^participant_id and kind == :LOCATION_SHARING)
    # REVIEWED-UNAUTHORIZED: whether consent is active, for a check that itself
    # gates what is shown; no grant leaves this function.
    |> Ash.read!(authorize?: false, tenant: tenant_id)
    |> Enum.any?(&ConsentGrant.covers?(&1, now))
  end

  @doc "The calling process watches `participant_id` until it unwatches or exits."
  @spec watch(Ash.UUID.t()) :: :ok
  def watch(participant_id) do
    if self() in :pg.get_members(@scope, group(participant_id)),
      do: :ok,
      else: :pg.join(@scope, group(participant_id), self())
  end

  @spec unwatch(Ash.UUID.t()) :: :ok
  def unwatch(participant_id) do
    _not_joined_or_left = :pg.leave(@scope, group(participant_id), self())
    :ok
  end

  @spec watched?(Ash.UUID.t()) :: boolean()
  def watched?(participant_id), do: :pg.get_members(@scope, group(participant_id)) != []

  @doc """
  Monitors who watches `participant_id`: the calling process receives
  `{ref, :join | :leave, group, pids}` on each change. Returns the reference and
  whether anyone watches now.
  """
  @spec monitor(Ash.UUID.t()) :: {reference(), boolean()}
  def monitor(participant_id) do
    {ref, members} = :pg.monitor(@scope, group(participant_id))
    {ref, members != []}
  end

  @spec demonitor(reference()) :: :ok
  def demonitor(ref) do
    _ = :pg.demonitor(@scope, ref)
    :ok
  end

  @doc "What a device is asked to do in `mode` (`:location_demand` configures it)."
  @spec policy(mode()) :: %{String.t() => term()}
  def policy(mode) do
    settings = Map.merge(@defaults[mode], configured(mode))

    %{
      "mode" => Atom.to_string(mode),
      "sample_interval_ms" => settings.sample_interval_ms,
      "upload_interval_ms" => settings.upload_interval_ms
    }
  end

  defp configured(mode),
    do: :dispatch |> Application.get_env(:location_demand, %{}) |> Map.get(mode, %{})

  defp in_organization?(actor, participant_id) do
    case Ash.get(Participant, participant_id, authorize?: false, tenant: actor.tenant_id) do
      {:ok, participant} ->
        participant.home_organization_id == actor.role_assignment.organization_id

      _unknown ->
        false
    end
  end

  defp group(participant_id), do: {:location_watch, participant_id}
end
