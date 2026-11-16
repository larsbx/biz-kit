defmodule CoopSubstrate.Projections.AdmissionGate do
  @moduledoc "Combined admission fold; existing ledgers retain their original Membership shape."
  @behaviour CoopSubstrate.Projection
  alias CoopSubstrate.{Procurement, Scf}
  alias CoopSubstrate.CommercialAdmission
  alias CoopSubstrate.Projections.Membership

  def init, do: Map.put(Membership.init(), :commercial_admission, CommercialAdmission.init())

  def handle_event(env, gate) do
    next =
      cond do
        Procurement.event?(env.type) -> Map.put(gate, :procurement, Procurement.fold!(env, gate))
        Scf.event?(env.type) -> Map.put(gate, :scf, Scf.fold!(env, gate))
        true -> env |> Membership.handle_event(gate) |> then(&Scf.observe(env, &1))
      end

    CommercialAdmission.fold(env, gate, next)
  end
end
