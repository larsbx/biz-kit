defmodule SalesCore.ConsentWire do
  @moduledoc """
  Untrusted v1 JSON-map boundary for scoped promotional consent commands.

  A host must supply its *verified* tenant, party binding, permissible
  operations, evidence receipt and time. These are not accepted as authority
  from JSON. No network, contact address or sender is present here.
  """

  @schema "bizkit.sales.consent.v1"
  @max_int 9_007_199_254_740_991
  @base ~w(schema tenant party_ref op id expected_version channel jurisdiction)
  @grant_fields ~w(audience evidence_ref)
  @channels %{
    "email" => :email,
    "sms" => :sms,
    "phone" => :phone,
    "push" => :push,
    "telegram" => :telegram
  }
  @audiences %{
    "customer" => :customer,
    "business_contact" => :business_contact
  }

  @doc """
  Parse a map only against a verified host scope.

  `trusted` is `%{tenant: ..., party_ref: ..., at_ms: ...,
  authorized_operations: [:grant | :withdraw],
  verified_evidence_ref: ...}`; granting requires an exact match against a
  previously validated evidence receipt. This parser does not itself verify
  identity, signatures, consent evidence, or durable admission.
  """
  def decode(wire, trusted) when is_map(wire) and is_map(trusted) do
    with :ok <- bind(wire, trusted),
         {:ok, operation} <- operation(Map.get(wire, "op")),
         :ok <- authorized(trusted, operation),
         :ok <- shape(wire, operation),
         {:ok, channel} <- lookup(@channels, Map.get(wire, "channel")),
         :ok <- identifiers(wire),
         :ok <- numbers(wire, trusted),
         {:ok, extra} <- evidence(wire, trusted, operation) do
      command =
        %{
          id: wire["id"],
          expected_version: wire["expected_version"],
          op: operation,
          party_ref: wire["party_ref"],
          channel: channel,
          jurisdiction: wire["jurisdiction"],
          at_ms: trusted.at_ms
        }
        |> Map.merge(extra)

      {:ok, command}
    end
  end

  def decode(_, _), do: {:error, :invalid_consent_command}

  defp bind(wire, trusted) do
    tenant = Map.get(trusted, :tenant)
    party = Map.get(trusted, :party_ref)

    if identifier(tenant) and identifier(party) and
         wire["tenant"] === tenant and wire["party_ref"] === party do
      :ok
    else
      {:error, :wrong_consent_scope}
    end
  end

  defp operation("grant"), do: {:ok, :grant}
  defp operation("withdraw"), do: {:ok, :withdraw}
  defp operation(_), do: {:error, :unknown_consent_operation}

  defp authorized(trusted, op) do
    operations = Map.get(trusted, :authorized_operations)

    if is_list(operations) and op in operations,
      do: :ok,
      else: {:error, :consent_operation_not_authorized}
  end

  defp shape(wire, op) do
    fields = if(op == :grant, do: @grant_fields, else: [])

    if wire["schema"] == @schema and Enum.sort(Map.keys(wire)) == Enum.sort(@base ++ fields) do
      :ok
    else
      {:error, :invalid_consent_shape}
    end
  end

  defp identifiers(wire) do
    if Enum.all?(~w(id tenant party_ref jurisdiction), &identifier(Map.get(wire, &1))) do
      :ok
    else
      {:error, :invalid_consent_reference}
    end
  end

  defp numbers(wire, trusted) do
    revision = wire["expected_version"]
    timestamp = Map.get(trusted, :at_ms)

    if bounded_int?(revision) and bounded_int?(timestamp),
      do: :ok,
      else: {:error, :invalid_consent_version_or_time}
  end

  defp bounded_int?(number) do
    is_integer(number) and number >= 0 and number <= @max_int
  end

  defp evidence(_wire, _trusted, :withdraw), do: {:ok, %{}}

  defp evidence(wire, trusted, :grant) do
    ref = Map.get(wire, "evidence_ref")
    verified = Map.get(trusted, :verified_evidence_ref)

    with {:ok, audience} <- lookup(@audiences, Map.get(wire, "audience")),
         true <- identifier(ref) and ref === verified do
      {:ok, %{audience: audience, evidence_ref: ref}}
    else
      {:error, _} = error -> error
      _ -> {:error, :consent_evidence_not_verified}
    end
  end

  defp lookup(options, name) do
    case Map.fetch(options, name) do
      {:ok, type} -> {:ok, type}
      :error -> {:error, :unsupported_consent_classification}
    end
  end

  defp identifier(s), do: is_binary(s) and byte_size(s) in 1..128
end
