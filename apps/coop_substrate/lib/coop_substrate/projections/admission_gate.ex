defmodule CoopSubstrate.Projections.AdmissionGate do
  @moduledoc "Combined admission fold; existing ledgers retain their original Membership shape."
  @behaviour CoopSubstrate.Projection
  alias CoopSubstrate.Procurement
  alias CoopSubstrate.CommercialAdmission
  alias CoopSubstrate.Projections.Membership

  def init, do: Map.put(Membership.init(), :commercial_admission, CommercialAdmission.init())

  def handle_event(env, gate) do
    next =
      if Procurement.event?(env.type) do
        Map.put(gate, :procurement, Procurement.fold!(env, gate))
      else
        Membership.handle_event(env, gate)
      end

    CommercialAdmission.fold(env, gate, next)
  end
end
