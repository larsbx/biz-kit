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
    Enum.find_value(boards, {:error, :unknown_device}, fn {_board_id, board} ->
      if board.device_id == id, do: {:ok, board, "staff", @board_actions}
    end)
  end

  @doc "Hold the device's grant for this declared governance key to sign."
  def prepare(%Restaurant{} = r, device_id, governance_key_id) do
    with {:ok, d} <- details(r, device_id),
         {:ok, signer} <- Commands.governance_signer(r.chapter, governance_key_id) do
      Commands.hold(owner(d), r.chapter, d.type, d.payload, signer)
    end
  end

  @doc "Submit the governance signature on a held grant; the ledger admits or refuses."
  def submit(%Restaurant{} = r, device_id, held_id, <<_::512>> = signature)
      when is_binary(held_id) and byte_size(held_id) in 1..128 do
    with {:ok, d} <- details(r, device_id),
         do: Commands.submit(owner(d), held_id, signature)
  end

  def submit(_, _, _, _), do: {:error, :bad_request}

  # Include the chapter, merchant and configured key, so a hold cannot be
  # submitted through another restaurant or after the device is reconfigured.
  defp owner(%{chapter_id: chapter, payload: p}) do
    {:restaurant_device_grant, chapter, p["merchant_id"], p["device_id"], p["key_id"], p["pubkey"]}
  end

  @doc """
  Whether a decoded envelope core is exactly the grant `details` (as the
  host's JSON showed it) describes: type, chapter and every payload field.
  """
  def grants?(core, details) do
    with {:ok, proposal} <- decode_details(details) do
      matches?(core, proposal)
    else
      _ -> false
    end
  end

  @doc "Compare a decoded envelope with an already validated, immutable proposal."
  def matches?(
        core,
        %{"chapter_id" => chapter, "type" => @type_name, "payload" => payload} = proposal
      )
      when is_map(core) and map_size(proposal) == 3 do
    core["type"] == @type_name and core["chapter_id"] == chapter and core["payload"] == payload
  end

  def matches?(_, _), do: false

  @doc "Validate and normalize a public proposal, decoding its key exactly once."
  def decode_details(%{"chapter_id" => ch, "type" => @type_name, "payload" => p} = details)
      when is_map(p) and map_size(details) == 3 and map_size(p) == 6 do
    with true <- Enum.all?([ch, p["merchant_id"], p["device_id"], p["key_id"]], &identifier?/1),
         true <- capabilities?(p["actor"], p["actions"]),
         {:ok, pubkey} <- public_key(p["pubkey"]) do
      {:ok, put_in(details, ["payload", "pubkey"], {:bytes, pubkey})}
    else
      _ -> {:error, :unexpected_proposal}
    end
  end

  def decode_details(_), do: {:error, :unexpected_proposal}

  @doc "Validate the public proposal before displaying or signing it."
  def valid_details?(details), do: match?({:ok, _}, decode_details(details))

  defp capabilities?("system", ["checkout"]), do: true
  defp capabilities?("staff", @board_actions), do: true
  defp capabilities?(_, _), do: false

  @doc "A bounded identifier safe to display and use as a URL segment."
  def identifier?(value),
    do:
      is_binary(value) and byte_size(value) in 1..128 and
        Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/, value)

  defp public_key(text) when is_binary(text) do
    case Base.url_decode64(text, padding: false) do
      {:ok, <<_::256>> = key} -> {:ok, key}
      _ -> {:error, :unexpected_proposal}
    end
  end

  defp public_key(_), do: {:error, :unexpected_proposal}

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
