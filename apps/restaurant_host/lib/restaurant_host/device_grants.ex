defmodule RestaurantHost.DeviceGrants do
  @moduledoc """
  Granting this restaurant's devices on the ledger, behind
  `mix restaurant.grant`, in the shape of device enrolment (`mix coop.enrol`):

    1. the host builds the grant a configured device needs
       (`RestaurantDeviceGrantedV1`: the storefront `checkout`, a board the
       kitchen steps) and holds it for a declared governance key
       (`CoopSubstrate.Commands.hold/5`);
    2. the administrator's machine decodes what it is asked to sign and signs
       with the governance key only if it is exactly the grant it was shown
       (`grants?/2`, `CoopSubstrate.Governance.Client.sign_held/4`);
    3. the host submits the signature and its own appender admits the grant.

  The governance seed never leaves the administrator's machine, and the host
  can only ever get a signature on the grant it showed.
  """

  alias CoopSubstrate.Commands
  alias RestaurantHost.Restaurant

  @type_name "RestaurantDeviceGrantedV1"
  @board_actions ~w(accept start_preparing mark_ready complete cancel)

  @doc "The grant a configured device needs: `{:ok, %{chapter_id, payload}}`."
  def details(%Restaurant{} = r, device_id) do
    with {:ok, device, actor, actions} <- device(r, device_id) do
      {:ok,
       %{
         chapter_id: r.chapter,
         type: @type_name,
         payload: %{
           "merchant_id" => r.merchant,
           "device_id" => device.device_id,
           "key_id" => device.signer.key_id,
           "pubkey" => {:bytes, device.signer.pubkey},
           "actor" => actor,
           "actions" => actions
         }
       }}
    end
  end

  defp device(%Restaurant{storefront: %{device_id: id} = d}, id),
    do: {:ok, d, "system", ["checkout"]}

  defp device(%Restaurant{boards: boards}, id) do
    case Enum.find(Map.values(boards), &(&1.device_id == id)) do
      nil -> {:error, :unknown_device}
      board -> {:ok, board, "staff", @board_actions}
    end
  end

  @doc "Hold the device's grant for this declared governance key to sign."
  def prepare(%Restaurant{} = r, device_id, governance_key_id) do
    with {:ok, d} <- details(r, device_id),
         {:ok, signer} <- Commands.governance_signer(r.chapter, governance_key_id) do
      Commands.hold(owner(r, device_id), r.chapter, d.type, d.payload, signer)
    end
  end

  @doc "Submit the governance signature on a held grant; the ledger admits or refuses."
  def submit(%Restaurant{} = r, device_id, held_id, <<_::512>> = signature)
      when is_binary(held_id) and byte_size(held_id) in 1..128 do
    with {:ok, _} <- details(r, device_id),
         do: Commands.submit(owner(r, device_id), held_id, signature)
  end

  def submit(_, _, _, _), do: {:error, :bad_request}

  # Include the chapter, merchant and configured key, so a hold cannot be
  # submitted through another restaurant or after the device is reconfigured.
  defp owner(r, device_id) do
    {:ok, d} = details(r, device_id)

    {:restaurant_device_grant, r.chapter, r.merchant, device_id, d.payload["key_id"],
     d.payload["pubkey"]}
  end

  @doc """
  Whether a decoded envelope core is exactly the grant `details` (as the
  host's JSON showed it) describes: type, chapter and every payload field.
  """
  def grants?(core, details) when is_map(core) do
    with true <- valid_details?(details),
         %{"chapter_id" => chapter, "payload" => shown} <- details,
         {:ok, pubkey} <- Base.url_decode64(shown["pubkey"], padding: false) do
      core["type"] == @type_name and core["chapter_id"] == chapter and
        core["payload"] == Map.put(shown, "pubkey", {:bytes, pubkey})
    else
      _ -> false
    end
  end

  def grants?(_, _), do: false

  @doc "Validate the public proposal before displaying or signing it."
  def valid_details?(%{"chapter_id" => ch, "type" => @type_name, "payload" => p} = d)
      when is_map(p) and map_size(d) == 3 and map_size(p) == 6 do
    Enum.all?([ch, p["merchant_id"], p["device_id"], p["key_id"]], &identifier?/1) and
      public_key?(p["pubkey"]) and
      ((p["actor"] == "system" and p["actions"] == ["checkout"]) or
         (p["actor"] == "staff" and p["actions"] == @board_actions))
  end

  def valid_details?(_), do: false

  @doc "A bounded identifier safe to display and use as a URL segment."
  def identifier?(value),
    do:
      is_binary(value) and byte_size(value) in 1..128 and
        Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/, value)

  defp public_key?(text) when is_binary(text),
    do: match?({:ok, <<_::256>>}, Base.url_decode64(text, padding: false))

  defp public_key?(_), do: false

  @doc "`details/2` as JSON: the public key base64url."
  def json(%{payload: payload} = d),
    do: %{
      d
      | payload:
          Map.update!(payload, "pubkey", fn {:bytes, b} ->
            Base.url_encode64(b, padding: false)
          end)
    }
end
