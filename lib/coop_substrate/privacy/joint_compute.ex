defmodule CoopSubstrate.Privacy.JointCompute do
  @moduledoc """
  The JointCompute seam, behaviour only (hand-off §4: "not needed for
  substrate; define the seam so network features slot in"). The first
  backing (trusted operator, later MPC) arrives with the first network
  feature that needs cross-party matching — building one now would be
  premature (corpus 08 §9).
  """

  alias CoopSubstrate.Privacy.Mechanism

  @callback match(inputs_per_party :: %{optional(String.t()) => term()}) ::
              %{optional(String.t()) => term()}
  @callback descriptor() :: Mechanism.descriptor()

  @doc """
  The configured backing's mechanism descriptor, validated (Phase 6A).
  No default backing exists yet — a first backing arrives with the first
  cross-party feature, and an MPC/FHE one is only representable at the
  `:sidecar` boundary.
  """
  @spec descriptor() :: {:ok, Mechanism.descriptor()} | {:error, term()}
  def descriptor do
    case Application.get_env(:coop_substrate, :joint_compute_backing) do
      nil -> {:error, :no_backing_configured}
      backing -> Mechanism.describe(backing)
    end
  end
end
