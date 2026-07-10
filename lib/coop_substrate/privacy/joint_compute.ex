defmodule CoopSubstrate.Privacy.JointCompute do
  @moduledoc """
  The JointCompute seam, behaviour only (hand-off §4: "not needed for
  substrate; define the seam so network features slot in"). The first
  backing (trusted operator, later MPC) arrives with the first network
  feature that needs cross-party matching — building one now would be
  premature (corpus 08 §9).
  """

  @callback match(inputs_per_party :: %{optional(String.t()) => term()}) ::
              %{optional(String.t()) => term()}
end
