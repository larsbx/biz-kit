defmodule Dispatch.Access.Roles.Receiver do
  @moduledoc """
  Delivery-stop counterparty (Section 23.2).

  The mirror of `Shipper`, scoped to a `DELIVERY` stop. The two are separate
  profiles rather than one parameterised profile because Section 33.1 requires
  each to reject the other's stop kind, and a shared implementation would make
  that a runtime argument rather than a property of the role.
  """

  use Dispatch.Access.Roles.Base, projection: :partner_stop

  @doc "Whether this profile may act on a stop of the given kind."
  @spec validate_stop_kind(atom() | String.t()) :: :ok | {:error, :stop_kind_mismatch}
  def validate_stop_kind(:DELIVERY), do: :ok
  def validate_stop_kind("DELIVERY"), do: :ok
  def validate_stop_kind(_kind), do: {:error, :stop_kind_mismatch}
end
