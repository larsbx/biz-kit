defmodule Dispatch.Operations.Status do
  @moduledoc """
  The canonical participant-declared status vocabulary of Section 5.1.

  These are declarations, not observations. Section 5.2 permits only
  `source=PARTICIPANT` with the `status.declare.self` capability to update the
  displayed self-declared status; a geofence or an agent runtime may suggest
  `AT_PICKUP` but the suggestion stays separate until confirmed.

  Two of these are explicitly *not* what they resemble. `AVAILABLE` is not a
  legal hours-of-service assertion and `RESTING` is not an ELD duty-status
  record — Section 1 keeps external notices and driver declarations distinct,
  and the ELD is never treated as an authoritative record.

  `EMERGENCY` is a driver-originated safety state. Section 8.2 is emphatic that
  it grants no routing privilege and does not make the driver callable: it opens
  guidance and public emergency-service controls on the device, nothing more.
  """

  @statuses [
    {:AVAILABLE, "Available", "Ready for dispatch consideration; not a legal HOS assertion."},
    {:OFF_DUTY, "Off duty", "Driver operationally unavailable."},
    {:PRE_TRIP, "Pre-trip", "Preparing vehicle or load."},
    {:DEADHEAD, "Deadheading", "Traveling without the assigned freight."},
    {:EN_ROUTE_PICKUP, "En route to pickup", "Traveling to shipper."},
    {:AT_PICKUP, "At pickup", "Driver declares arrival at shipper."},
    {:LOADING, "Loading", "Freight is being loaded."},
    {:EN_ROUTE_DELIVERY, "En route to delivery", "Traveling to consignee."},
    {:AT_DELIVERY, "At delivery", "Driver declares arrival at consignee."},
    {:UNLOADING, "Unloading", "Freight is being unloaded."},
    {:DELAYED, "Delayed", "Delay exists; reason and revised estimate requested."},
    {:BREAKDOWN, "Breakdown", "Vehicle problem; description and safe-location requested."},
    {:RESTING, "Resting", "Driver unavailable while resting; not an ELD duty-status record."},
    {:COMPLETE, "Complete", "Driver declares operational completion."},
    {:EMERGENCY, "Emergency",
     "Driver-originated safety state opening emergency guidance and public " <>
       "emergency-service controls; it does not make the driver callable."}
  ]

  @codes Enum.map(@statuses, &elem(&1, 0))

  # Section 24.1: DELAYED and BREAKDOWN require a nonblank note.
  @require_note [:DELAYED, :BREAKDOWN]

  @typedoc "A canonical status code."
  @type t :: unquote(Enum.reduce(Enum.reverse(@codes), &{:|, [], [&1, &2]}))

  @doc "Every canonical status code, in the order Section 5.1 lists them."
  @spec all() :: [t()]
  def all, do: @codes

  @doc "Whether `code` is canonical."
  @spec known?(term()) :: boolean()
  def known?(code) when is_atom(code), do: code in @codes

  def known?(code) when is_binary(code) do
    Enum.any?(@codes, &(Atom.to_string(&1) == code))
  end

  def known?(_code), do: false

  @doc "The presentation label for a status."
  @spec label(t()) :: String.t() | nil
  def label(code) do
    Enum.find_value(@statuses, fn {c, label, _meaning} -> c == code && label end)
  end

  @doc "The documented meaning of a status."
  @spec meaning(t()) :: String.t() | nil
  def meaning(code) do
    Enum.find_value(@statuses, fn {c, _label, meaning} -> c == code && meaning end)
  end

  @doc """
  Whether declaring this status requires a nonblank note (Section 24.1).

  `DELAYED` and `BREAKDOWN` both describe a situation someone else has to act
  on, and a bare code says nothing actionable.
  """
  @spec requires_note?(t() | String.t()) :: boolean()
  def requires_note?(code) when is_atom(code), do: code in @require_note

  def requires_note?(code) when is_binary(code) do
    Enum.any?(@require_note, &(Atom.to_string(&1) == code))
  end

  def requires_note?(_code), do: false
end
