defmodule Dispatch.RestaurantReceipts do
  @moduledoc false

  alias CoopSubstrate.ULID
  alias Dispatch.Access.Actor
  alias Dispatch.Fleet.{Assignment, Load}
  alias Dispatch.Identity.PrincipalResolution
  alias Dispatch.{Repo, RestaurantAutomation, RestaurantDelivery}

  def submit(%Actor{principal_type: :PARTICIPANT} = actor, %{
        "assignment_id" => id,
        "phase" => phase,
        "handoff_token" => code
      })
      when phase in ["picked_up", "delivered"] and is_binary(code) and byte_size(code) in 22..30 do
    with {:ok, <<_::128>>} <- Base.url_decode64(String.trim(code), padding: false),
         {:ok, id} <- Ecto.UUID.cast(id) do
      Repo.transaction(fn ->
        case receipt(actor, id, phase, String.trim(code)) do
          {:ok, result} -> result
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      _ -> {:error, :invalid_receipt}
    end
  end

  def submit(_, _), do: {:error, :invalid_receipt}

  defp receipt(actor, id, phase, code) do
    # Close the race with assignment cancellation or courier role revocation
    # while the remote ledger accepts the scoped proof.
    Repo.query!(
      "SELECT id FROM assignments WHERE id = $1::uuid AND tenant_id = $2::uuid FOR SHARE",
      [Ecto.UUID.dump!(id), Ecto.UUID.dump!(actor.tenant_id)]
    )

    with {:ok, actor} <- PrincipalResolution.authorize(actor, "status.declare.self", lock: true),
         {:ok, %Assignment{} = trip} <-
           Ash.get(Assignment, id, tenant: actor.tenant_id, authorize?: false),
         true <-
           Actor.self?(actor, trip.operator_participant_id) and
             trip.status in [:ACTIVE, :COMPLETED],
         {:ok, %Load{} = load} <-
           Ash.get(Load, trip.load_id, tenant: actor.tenant_id, authorize?: false),
         {:ok, config, order} <- source(load.external_reference, actor.tenant_id),
         {:ok, result} <-
           RestaurantDelivery.publish_automated(command(trip, order, phase, code), config) do
      {:ok, result}
    else
      _ -> {:error, :receipt_not_accepted}
    end
  end

  defp source(reference, tenant) when is_binary(reference) do
    with [source, _, _, _] <- String.split(reference, ":", parts: 4),
         {:ok, source} <- source_type(source),
         true <- RestaurantAutomation.enabled?(source),
         {:ok, %{tenant: ^tenant} = config} <- RestaurantDelivery.configuration(source),
         prefix = RestaurantDelivery.load_reference(config.chapter, config.merchant, "", source),
         true <- String.starts_with?(reference, prefix),
         order = String.replace_prefix(reference, prefix, ""),
         true <- valid_order?(source, order) do
      {:ok, config, order}
    else
      _ -> :error
    end
  end

  defp source(_, _), do: :error

  defp source_type("restaurant"), do: {:ok, :restaurant}
  defp source_type("procurement"), do: {:ok, :procurement}
  defp source_type(_), do: :error

  defp valid_order?(:restaurant, order), do: ULID.valid?(order)

  defp valid_order?(:procurement, order),
    do: Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/, order)

  defp command(trip, order, phase, code) do
    digest = :crypto.hash(:sha256, code)
    {:ok, proof_id} = digest |> binary_part(0, 16) |> Ecto.UUID.load()

    %{
      "op" => phase,
      "order_id" => order,
      "load_id" => trip.load_id,
      "assignment_id" => trip.id,
      "command_id" => phase <> "-" <> proof_id,
      "expected_version" => if(phase == "picked_up", do: 1, else: 2),
      "proof_id" => proof_id,
      "proof_digest" => Base.encode16(digest, case: :lower)
    }
  end
end
