defmodule Dispatch.Access.Roles.Shipper do
  @moduledoc """
  Pickup-stop counterparty (Section 23.2).

  Scoped to a `PICKUP` stop and optionally bounded to its load. Section 4.3
  keeps the full driver timeline, continuous route trace, unrelated stops,
  negotiated rate, internal carrier notes, and other parties' communications off
  this surface entirely.
  """

  use Dispatch.Access.Roles.Base, projection: :partner_stop

  @doc """
  Whether this profile may act on a stop of the given kind.

  Section 33.1 requires the shipper and receiver validators to reject a stop
  whose kind does not match their relationship, so a shipper cannot update
  readiness on a delivery.
  """
  @spec validate_stop_kind(atom() | String.t()) :: :ok | {:error, :stop_kind_mismatch}
  def validate_stop_kind(:PICKUP), do: :ok
  def validate_stop_kind("PICKUP"), do: :ok
  def validate_stop_kind(_kind), do: {:error, :stop_kind_mismatch}
end
