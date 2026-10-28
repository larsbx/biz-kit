defmodule MarketingCore.Attribution do
  @moduledoc """
  Pure merchant-independent attribution rule salvaged from Eatsbot.

  Only **independently confirmed** message delivery can qualify for
  attribution. A queued notification, QR/NFC scan or subscriber record
  cannot establish consent or successful delivery. The host must validate
  the original evidence and SalesCore consent before recording a conversion.

  Uses exact microsecond intervals; the legacy Eatsbot policy truncated
  time differences to whole seconds.
  """

  @spec eligible?(map(), DateTime.t(), non_neg_integer()) :: boolean()
  def eligible?(
        %{delivery_status: :confirmed, delivered_at: %DateTime{} = delivered_at} = evidence,
        %DateTime{} = checked_in_at,
        window_seconds
      )
      when is_integer(window_seconds) and window_seconds >= 0 do
    elapsed = DateTime.diff(checked_in_at, delivered_at, :microsecond)

    prior_ok? =
      case Map.get(evidence, :last_attributed_at) do
        nil -> true
        %DateTime{} = prior -> DateTime.compare(prior, delivered_at) == :lt
        _ -> false
      end

    elapsed >= 0 and elapsed <= window_seconds * 1_000_000 and prior_ok?
  end

  def eligible?(_, _, _), do: false
end
