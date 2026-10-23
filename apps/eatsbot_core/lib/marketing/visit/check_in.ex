defmodule EatsbotCore.Marketing.Visit.CheckIn do
  @moduledoc """
  Resolves the touchpoint, (re-)subscribes the customer, decides attribution,
  snapshots the commission rate and issues a redemption code.
  """
  use Ash.Resource.Change

  alias EatsbotCore.Marketing
  alias EatsbotCore.Marketing.{Attribution, Promotion, Subscriber, Touchpoint, Visit}

  @code_length 6

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, &check_in(&1, Ash.Context.to_opts(context)))
  end

  defp check_in(%{arguments: args} = changeset, opts) do
    now = DateTime.utc_now()

    with {:ok, touchpoint} <- Touchpoint.by_code(args.touchpoint_code, opts),
         {:ok, subscriber} <-
           Subscriber.subscribe(
             %{channel: args.channel, address: args.address, branch_id: touchpoint.branch_id},
             Keyword.put(opts, :load, [:last_attributed_at])
           ),
         {:ok, promotion} <-
           Promotion.active_for_branch(
             touchpoint.branch_id,
             Keyword.put(opts, :not_found_error?, false)
           ) do
      attributed? =
        Attribution.attributed?(
          subscriber.last_notified_at,
          subscriber.last_attributed_at,
          now,
          Marketing.attribution_window()
        )

      Ash.Changeset.force_change_attributes(changeset,
        touchpoint_id: touchpoint.id,
        subscriber_id: subscriber.id,
        promotion_id: promotion && promotion.id,
        checked_in_at: now,
        attributed?: attributed?,
        commission_rate: if(attributed?, do: touchpoint.commission_rate, else: Decimal.new(0)),
        code: unused_code(opts)
      )
    else
      {:error, error} -> Ash.Changeset.add_error(changeset, error)
    end
  end

  # Unique among currently redeemable visits, which is all `open_by_code` sees.
  defp unused_code(opts) do
    code = Attribution.code(@code_length)

    case Visit.open_by_code(code, Keyword.put(opts, :not_found_error?, false)) do
      {:ok, nil} -> code
      _taken -> unused_code(opts)
    end
  end
end
