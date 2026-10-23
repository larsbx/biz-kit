defmodule DispatchWeb.Streams.LocationDemand do
  @moduledoc """
  The device's demand stream: what the participant's own phone hears about
  who is watching its position (`Dispatch.Operations.LocationDemand`).

  Each `location-demand` event carries the policy to apply now, and is sent
  when the stream opens and whenever the mode changes: `realtime` while at
  least one precise-location reader watches, `trickle` otherwise. Nothing names
  the watchers; the device learns that someone looks, not who.

  The stream exists only while the participant shares. It is revalidated on
  every heartbeat and on every change to the participant (a revocation is one),
  and closes when the role assignment or the consent ends; a device that sees
  it close falls back to its own idea of trickle until it consents again.
  """

  @behaviour DispatchWeb.Streams.Transport

  alias Dispatch.Access.Actor
  alias Dispatch.Identity.PrincipalResolution
  alias Dispatch.Operations.LocationDemand, as: Demand
  alias DispatchWeb.Datastar

  @retry_ms 3_000

  @enforce_keys [:actor, :ref, :mode]
  defstruct [:actor, :ref, :mode]

  @type t :: %__MODULE__{actor: Actor.t(), ref: reference(), mode: Demand.mode()}

  @doc "Opens the stream for the sharing participant `actor`, or reports nothing."
  @spec open(Actor.t()) :: {:ok, t(), iodata()} | {:error, :not_found}
  def open(%Actor{} = actor) do
    with {:ok, actor} <- revalidate(actor), true <- sharing?(actor) do
      {ref, watched?} = Demand.monitor(actor.principal_id)
      mode = mode(watched?)

      {:ok, %__MODULE__{actor: actor, ref: ref, mode: mode},
       [Datastar.retry(@retry_ms), event(mode)]}
    else
      _not_sharing -> {:error, :not_found}
    end
  end

  @impl DispatchWeb.Streams.Transport
  @spec tick(t(), DispatchWeb.Streams.Transport.reason()) ::
          {:emit, iodata(), t()} | {:close, :unauthorized}
  def tick(%__MODULE__{} = session, reason) do
    # Group changes can arrive continuously and postpone the heartbeat. They
    # must not bypass consent/role validation while changing collection policy.
    with {:ok, actor} <- revalidate(session.actor),
         true <- sharing?(actor),
         {:emit, change, session} <- policy_change(%{session | actor: actor}) do
      chunk = if reason == :demand, do: change, else: [beat(reason), change]
      {:emit, chunk, session}
    else
      _gone -> {:close, :unauthorized}
    end
  end

  defp policy_change(session) do
    case mode(Demand.watched?(session.actor.principal_id)) do
      unchanged when unchanged == session.mode -> {:emit, [], session}
      mode -> {:emit, event(mode), %{session | mode: mode}}
    end
  end

  @doc "Stops monitoring."
  @impl DispatchWeb.Streams.Transport
  @spec release(t()) :: :ok
  def release(%__MODULE__{ref: ref}), do: Demand.demonitor(ref)

  defp sharing?(actor) do
    actor.principal_type == :PARTICIPANT and Actor.can?(actor, "location.share.self") and
      Demand.consenting?(actor.tenant_id, actor.principal_id)
  end

  defp revalidate(actor), do: PrincipalResolution.revalidate(actor)

  defp mode(true), do: :realtime
  defp mode(false), do: :trickle

  defp beat(:heartbeat), do: Datastar.heartbeat()
  defp beat(:refresh), do: []

  defp event(mode),
    do: ["event: location-demand\ndata: ", Jason.encode!(Demand.policy(mode)), "\n\n"]
end
