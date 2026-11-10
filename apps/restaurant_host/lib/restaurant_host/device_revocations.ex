defmodule RestaurantHost.DeviceRevocations do
  @moduledoc """
  Revoking a restaurant device on the ledger, behind `mix restaurant.revoke`,
  in the shape of `RestaurantHost.DeviceGrants`: the host lists the granted
  devices to governance (`granted/1`), holds `RestaurantDeviceRevokedV1` for
  one key, and the administrator signs it only if it is exactly that key for
  this chapter and merchant (`matches?/4`). From then on the ledger refuses
  everything the key signs, and never grants it again: a replacement device
  gets a new key. Orders it placed stay.
  """

  alias CoopSubstrate.{Commands, Log}
  alias RestaurantHost.{DeviceGrants, Restaurant}

  @type_name "RestaurantDeviceRevokedV1"

  @doc "The devices granted for this restaurant, as governance reviews them."
  def granted(%Restaurant{chapter: ch, merchant: m}) do
    for {{^ch, ^m, key_id}, g} <- Log.gate().restaurant.grants do
      %{
        "device_id" => g.device_id,
        "key_id" => key_id,
        "actor" => Atom.to_string(g.actor),
        "actions" => Enum.map(g.actions, &Atom.to_string/1)
      }
    end
    |> Enum.sort_by(& &1["device_id"])
  end

  @doc "Hold the revocation of `key_id` for this declared governance key to sign."
  def prepare(%Restaurant{} = r, key_id, governance_key_id) do
    with true <- DeviceGrants.identifier?(key_id) or {:error, :bad_request},
         {:ok, signer} <- Commands.governance_signer(r.chapter, governance_key_id) do
      Commands.hold(owner(r, key_id), r.chapter, @type_name, payload(r.merchant, key_id), signer)
    end
  end

  @doc "Submit the governance signature on a held revocation; the ledger admits or refuses."
  def submit(%Restaurant{} = r, key_id, held_id, <<_::512>> = signature)
      when is_binary(held_id) and byte_size(held_id) in 1..128,
      do: Commands.submit(owner(r, key_id), held_id, signature)

  def submit(_, _, _, _), do: {:error, :bad_request}

  @doc "Whether a decoded core is exactly the revocation of `key_id` here."
  def matches?(core, chapter, merchant, key_id) when is_map(core),
    do:
      core["type"] == @type_name and core["chapter_id"] == chapter and
        core["payload"] == payload(merchant, key_id)

  def matches?(_, _, _, _), do: false

  defp payload(merchant, key_id), do: %{"merchant_id" => merchant, "key_id" => key_id}
  defp owner(r, key_id), do: {:restaurant_device_revocation, r.chapter, r.merchant, key_id}
end
