defmodule CoopSubstrate.Projections.AdmissionGate do
  @moduledoc "Combined admission fold; existing ledgers retain their original Membership shape."
  @behaviour CoopSubstrate.Projection
  alias CoopSubstrate.Procurement
  alias CoopSubstrate.Projections.Membership

  def init, do: Membership.init()

  def handle_event(env, gate) do
    if Procurement.event?(env.type) do
      Map.put(gate, :procurement, Procurement.fold!(env, gate))
    else
      Membership.handle_event(env, gate)
    end
  end
end
