defmodule RestaurantHost.Refusal do
  @moduledoc """
  What a restaurant operator is told when a command is refused: one closed
  vocabulary for the host's governance routes
  (`RestaurantHost.Web.DeviceGrantController`) and the operator's clients
  (`mix restaurant.grant`, `mix restaurant.manage` and their release tasks).

  The host names a ledger refusal (`code/1`) only on routes governance
  already holds: preparing takes a signed governance request, and submitting
  the held ID that only such a request is given. At submit, every ledger
  refusal but `invalid_signature` follows a signature that verifies under the
  held governance key. A wrapped refusal is named by its head atom alone,
  and only from the ledger table, so no key ID or role is echoed; any other
  is `not_admitted`, as before, and logged by the host. A bare reason is
  returned as before.

  The clients decode a reason through the same table (`decode/2`), never
  making an atom, and show its sentence (`explain/1`).
  """

  @ledger [
    key_not_separate:
      "That public key is already another kind of key in this chapter (a device, " <>
        "Dispatch, dispatcher or procurement key, revoked or not, or a declared role key) " <>
        "or serves another Dispatch tenant. Make a new seed and key ID",
    restaurant_key_already_granted:
      "This merchant already granted this key ID or public key, revoked or not. " <>
        "Use a new key ID and seed",
    restaurant_device_not_active: "No active grant has that key ID at this merchant",
    stale_menu: "The menu revision moved. Read GET /api/restaurant-menu and prepare again",
    invalid_restaurant_menu: "The menu items or prices are malformed",
    invalid_restaurant_grant: "The device grant fields are malformed",
    invalid_dispatch_tenant: "tenant_id must be the Dispatch tenant UUID",
    invalid_dispatch_grant: "The Dispatch grant fields or public key are malformed",
    restaurant_governance_not_declared:
      "The signing governance key is not declared in the chapter",
    role_key_not_declared:
      "The signing key is not, or no longer, declared for its role, for example " <>
        "revoked between prepare and submit",
    invalid_signature:
      "The signature does not verify under the held governance key. Check the seed"
  ]

  @host [
    forbidden:
      "The governance request was not authenticated for this chapter. " <>
        "Check the governance key ID, its seed and the clock",
    unknown_device: "No device with that ID is configured on the host",
    bad_request: "The request is malformed",
    unknown_command:
      "No command is held under that ID: it expired, was spent or was never prepared. " <>
        "Prepare it again",
    signature_count: "The number of signatures does not match the held commands",
    unknown_governance_key: "That governance key ID is not declared in the chapter",
    not_admitted:
      "The ledger refused the command for a reason the host does not name; " <>
        "the host log has it"
  ]

  @client [
    not_what_was_shown:
      "The host offered bytes other than the reviewed command, and nothing was signed",
    unexpected_proposal:
      "The host's proposal could not be fetched or read, or names another chapter, " <>
        "merchant or device, and nothing was signed. Check the server URL and that the " <>
        "host serves this device",
    governance_key_unavailable: "No governance seed could be read from HARNESS_KEYS_DIR",
    invalid_options:
      "The arguments, the server URL (HTTPS, or HTTP on loopback only) or the " <>
        "command file's merchant_id are invalid",
    not_granted: "The host did not confirm the grant. Check that it is reachable, and its log"
  ]

  @sentences Map.new(@ledger ++ @host ++ @client)
  @codes Map.keys(@sentences)
  @by_code Map.new(@codes, &{Atom.to_string(&1), &1})
  @ledger_codes Keyword.keys(@ledger)

  @doc "The ledger refusals the host names."
  def ledger_codes, do: @ledger_codes

  @doc """
  The code the host returns for a refusal: a bare reason as itself; a
  preflight (`{:invalid, reason}`, `CoopSubstrate.Commands.hold/5`) or append
  (`{:reject, index, reason}`, `CoopSubstrate.Log.append/1`) refusal, or any
  other tuple, by its head atom if the ledger table has it; otherwise
  `"not_admitted"`.
  """
  @spec code(term()) :: String.t()
  def code(reason) when is_atom(reason), do: Atom.to_string(reason)
  def code({:invalid, reason}), do: named(reason)
  def code({:reject, index, reason}) when is_integer(index), do: named(reason)
  def code(reason), do: named(reason)

  defp named(reason) when is_tuple(reason) and tuple_size(reason) > 0, do: known(elem(reason, 0))
  defp named(reason), do: known(reason)

  defp known(code) when code in @ledger_codes, do: Atom.to_string(code)
  defp known(_), do: "not_admitted"

  @doc """
  A client's error as a known code: the host's `"error"`, or a known reason
  itself (`:not_what_was_shown` from `CoopSubstrate.Governance.Client`, a
  client's own); otherwise `fallback`.
  """
  @spec decode(term(), atom()) :: atom()
  def decode({:error, {status, raw}}, fallback) when is_integer(status) and is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, %{"error" => code}} -> Map.get(@by_code, code, fallback)
      _ -> fallback
    end
  end

  def decode({:error, code}, _fallback) when code in @codes, do: code
  def decode(_error, fallback), do: fallback

  @doc "`\"code: sentence\"` for a known code, else the code alone."
  @spec explain(atom()) :: String.t()
  def explain(code) when is_atom(code) do
    case Map.fetch(@sentences, code) do
      {:ok, sentence} -> "#{code}: #{sentence}"
      :error -> Atom.to_string(code)
    end
  end

  @doc "An error explained if it decodes, else inspected as before."
  @spec describe(term()) :: String.t()
  def describe(error) do
    case decode(error, nil) do
      nil -> inspect(error, limit: 5)
      code -> explain(code)
    end
  end
end
