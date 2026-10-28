defmodule Dispatch.Accounts.DeviceKeys do
  @moduledoc """
  A field device's Ed25519 key (docs/architecture/2026-10-21-device-keys.md).

  Section 23.1: the app registers an installation public key after
  interactive login, and events created offline are signed with it. The
  device registers itself: it proves it holds the key by signing a
  registration statement, and no one approves it. What a valid signature buys
  is provenance, recorded on the event as `verification: :DEVICE_AUTHENTICATED`
  — the declaration was made on that participant's registered handset, whenever
  it was uploaded.

  Both statements are `CoopEventCanonicalV1` maps (the platform's one canonical
  form, as for capability documents) carrying a `schema` and no `type`, so a
  registration proof, an event signature and a ledger command can never pass
  for one another.

      DispatchDeviceRegistrationV1  tenant_id, participant_id, installation_id, public_key (bytes)
      DispatchStatusEventV1         the event body's own fields, less device_signature
      DispatchLocationSampleV1      a location sample's own fields, less device_signature

  The canonical form has no floats, deliberately: a signature needs the same
  bytes on the handset and here. So a location sample carries its coordinates
  and measurements as fixed-point integers (`lat_e7`, `accuracy_cm`, ...).
  """

  alias CoopSubstrate.{Canonical, Crypto}
  alias Dispatch.Access.Actor
  alias Dispatch.Accounts.Device

  require Ash.Query

  @registration_schema "DispatchDeviceRegistrationV1"
  @event_schema "DispatchStatusEventV1"
  @sample_schema "DispatchLocationSampleV1"
  @max_installation_id 200

  @type registration_error ::
          :invalid_installation_id
          | :invalid_public_key
          | :invalid_proof
          | :installation_conflict
          | :invalid_registration

  @doc "What a device signs to register `public_key` for `actor`."
  @spec registration_statement(Actor.t(), String.t(), <<_::256>>) :: binary()
  def registration_statement(%Actor{} = actor, installation_id, public_key) do
    Canonical.encode!(%{
      "schema" => @registration_schema,
      "tenant_id" => actor.tenant_id,
      "participant_id" => actor.principal_id,
      "installation_id" => installation_id,
      "public_key" => {:bytes, public_key}
    })
  end

  @doc """
  What a device signs for an event: the fields of the body it sends, without
  `device_signature`. Error when the fields have no canonical form (a float,
  say), which no honest client sends.
  """
  @spec event_statement(%{String.t() => term()}) :: {:ok, binary()} | {:error, term()}
  def event_statement(fields), do: Canonical.encode(Map.put(fields, "schema", @event_schema))

  @doc "What a device signs for a location sample: its fields, without `device_signature`."
  @spec sample_statement(%{String.t() => term()}) :: {:ok, binary()} | {:error, term()}
  def sample_statement(fields), do: Canonical.encode(Map.put(fields, "schema", @sample_schema))

  @doc """
  Registers the installation's key for `actor`, given a `proof` signed by it.

  Registering the same key again is a no-op returning the device. An
  installation already registered with another key, or to someone else, is a
  conflict: a new installation (or a revocation) is how a key changes.
  """
  @spec register(Actor.t(), term(), term(), term()) ::
          {:ok, :created | :existing, Device.t()} | {:error, registration_error()}
  def register(%Actor{} = actor, installation_id, public_key, proof) do
    with :ok <- check(valid_installation_id?(installation_id), :invalid_installation_id),
         {:ok, key} <- decode(public_key, 32, :invalid_public_key),
         {:ok, signature} <- decode(proof, 64, :invalid_proof),
         :ok <-
           check(
             Crypto.verify(registration_statement(actor, installation_id, key), signature, key),
             :invalid_proof
           ) do
      case installation(actor, installation_id) do
        nil -> create(actor, installation_id, public_key)
        device -> same(actor, device, public_key)
      end
    end
  end

  @doc """
  The verification an event earns. An event naming the actor's own active
  device must carry that device's signature over its fields, and is then
  `:DEVICE_AUTHENTICATED`; one without a device is `:NONE`. A device that is
  not the actor's own active one is left to `ReferencedRows`, which refuses
  the event.
  """
  @spec verify_event(Actor.t(), %{String.t() => term()}, term()) ::
          {:ok, :NONE | :DEVICE_AUTHENTICATED}
          | {:error, :device_signature_required | :device_signature_invalid}
  def verify_event(%Actor{} = actor, fields, signature) do
    case own_active_device(actor, fields["device_id"]) do
      nil -> {:ok, :NONE}
      _device when is_nil(signature) -> {:error, :device_signature_required}
      device -> verify_with(device, fields, signature)
    end
  end

  @doc """
  Checks a location sample's signature. Unlike a status declaration, a sample
  always names its device and is always signed: it is only ever acquired by a
  registered handset (Section 24.2).
  """
  @spec verify_sample(Actor.t(), %{String.t() => term()}, term()) ::
          :ok | {:error, :device_signature_required | :device_signature_invalid}
  def verify_sample(%Actor{} = actor, fields, signature) do
    case own_active_device(actor, fields["device_id"]) do
      nil ->
        {:error, :device_signature_invalid}

      _device when is_nil(signature) ->
        {:error, :device_signature_required}

      device ->
        with {:ok, _verified} <- verify_with(device, fields, signature, &sample_statement/1),
             do: :ok
    end
  end

  defp verify_with(device, fields, signature, statement \\ &event_statement/1) do
    with {:ok, statement} <- statement.(fields),
         {:ok, signature} <- decode(signature, 64, :invalid),
         {:ok, key} <- decode(device.public_key, 32, :invalid),
         true <- Crypto.verify(statement, signature, key) do
      {:ok, :DEVICE_AUTHENTICATED}
    else
      _invalid -> {:error, :device_signature_invalid}
    end
  end

  @doc """
  Names the refusal behind an Ash error from registering. Inside an enclosing
  transaction (an idempotency key's), Ash answers a refused insert by rolling
  that transaction back with its changeset, so a caller meets it there rather
  than as a `register/4` result, and names it with this.
  """
  @spec refusal(term()) :: :installation_conflict | :invalid_registration
  def refusal(error) do
    taken? =
      error
      |> Ash.Error.to_error_class()
      |> Map.get(:errors, [])
      |> Enum.any?(&(Map.get(&1, :field) == :installation_id))

    if taken?, do: :installation_conflict, else: :invalid_registration
  end

  defp own_active_device(actor, device_id) when is_binary(device_id) do
    case Ecto.UUID.cast(device_id) do
      {:ok, id} ->
        Device
        |> Ash.Query.filter(
          id == ^id and participant_id == ^actor.principal_id and status == :ACTIVE
        )
        # REVIEWED-UNAUTHORIZED: reads the actor's own device, scoped by the filter above.
        |> Ash.read_one!(authorize?: false, tenant: actor.tenant_id)

      :error ->
        nil
    end
  end

  defp own_active_device(_actor, _device_id), do: nil

  # Within the actor's tenant. One registered in another tenant is found by the
  # global unique index instead, when the insert is refused, and is a conflict
  # either way: nothing about it is read.
  defp installation(actor, installation_id) do
    Device
    |> Ash.Query.filter(installation_id == ^installation_id)
    # REVIEWED-UNAUTHORIZED: compared, and returned only if it is the actor's own.
    |> Ash.read_one!(authorize?: false, tenant: actor.tenant_id)
  end

  defp create(actor, installation_id, public_key) do
    Device
    |> Ash.Changeset.for_create(:register, %{
      tenant_id: actor.tenant_id,
      participant_id: actor.principal_id,
      installation_id: installation_id,
      public_key: public_key
    })
    # REVIEWED-UNAUTHORIZED: the actor registers their own device, proven above.
    |> Ash.create(authorize?: false, tenant: actor.tenant_id)
    |> case do
      {:ok, device} ->
        {:ok, :created, device}

      # The global unique index refused it: the installation is taken in
      # another tenant (one in this tenant was found above). Not re-read: the
      # refusal may have aborted an enclosing transaction. Two identical
      # registrations racing each other also land here; the loser's next
      # attempt finds the device and is a re-registration.
      {:error, error} ->
        {:error, refusal(error)}
    end
  end

  defp same(actor, device, public_key) do
    if device.tenant_id == actor.tenant_id and device.participant_id == actor.principal_id and
         device.public_key == public_key and device.status == :ACTIVE,
       do: {:ok, :existing, device},
       else: {:error, :installation_conflict}
  end

  defp valid_installation_id?(id),
    do: is_binary(id) and String.length(id) in 1..@max_installation_id and String.valid?(id)

  defp decode(value, size, error) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, bytes} when byte_size(bytes) == size -> {:ok, bytes}
      _malformed -> {:error, error}
    end
  end

  defp decode(_value, _size, error), do: {:error, error}

  defp check(true, _error), do: :ok
  defp check(false, error), do: {:error, error}
end
