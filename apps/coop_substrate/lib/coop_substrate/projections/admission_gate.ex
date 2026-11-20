defmodule CoopSubstrate.Projections.AdmissionGate do
  @moduledoc "Combined admission fold; existing ledgers retain their original Membership shape."
  @behaviour CoopSubstrate.Projection
  alias CoopSubstrate.Procurement
  alias CoopSubstrate.CommercialAdmission
  alias CoopSubstrate.Projections.Membership

  def init do
    Membership.init()
    |> Map.put(:commercial_admission, CommercialAdmission.init())
    |> Map.put(:member_key_epochs, %{})
  end

  def handle_event(env, gate) do
    next =
      if Procurement.event?(env.type) do
        Map.put(gate, :procurement, Procurement.fold!(env, gate))
      else
        Membership.handle_event(env, gate)
      end

    CommercialAdmission.fold(env, gate, track_member_key_epoch(env, next))
  end

  # The Log assigns this position before validating and folding the batch.
  # Replay restores the same position even if a rotation restores old keys.
  defp track_member_key_epoch(%{type: type} = env, gate)
       when type in ~w(MemberRegistered KeyRotated KeyRecoveryRotated) do
    member = {env.chapter_id, env.payload["member_id"]}

    if Map.has_key?(gate.members, member) do
      put_in(gate, [:member_key_epochs, Access.key(member)], env.global_seq)
    else
      gate
    end
  end

  defp track_member_key_epoch(_env, gate), do: gate
end
