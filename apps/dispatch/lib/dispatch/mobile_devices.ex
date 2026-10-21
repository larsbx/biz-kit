defmodule Dispatch.MobileDevices do
  @moduledoc """
  Adapter from existing Identity sessions and governance-approved enrolments to
  Dispatch's existing device registry. No grant is minted here. Tenant-to-ledger
  scope mapping is deployment configuration, never client input.
  """
  import Ecto.Query
  alias CoopSubstrate.{Canonical, Crypto}
  alias Dispatch.Accounts.Device
  require Ash.Query

  @spec available?() :: boolean()
  def available? do
    is_pid(GenServer.whereis(BizKit.Cluster.Singleton.name(CoopSubstrate.Log))) and
      is_pid(GenServer.whereis(BizKit.Cluster.Singleton.name(CoopSubstrate.Enrolments)))
  end

  @spec scope(Dispatch.Access.Actor.t()) :: {:ok, tuple()} | {:error, atom()}
  def scope(actor) do
    case Map.get(Application.get_env(:dispatch, :mobile_enrolment_scopes, %{}), actor.tenant_id) do
      {c, t, p} = scope when is_binary(c) and is_binary(t) and is_binary(p) -> {:ok, scope}
      _ -> {:error, :enrolment_unavailable}
    end
  end

  @spec register(Dispatch.Access.Actor.t(), map(), map()) :: {:ok, Device.t()} | {:error, term()}
  def register(actor, session, params) do
    with {:ok, scope} <- scope(actor),
         {:ok, public} <- decode(params["public_key"], 32),
         key_id = key_id(public),
         true <- key_id == params["key_id"],
         :ok <- approved(session.principal, scope, public),
         installation when is_binary(installation) and byte_size(installation) in 1..128 <-
           params["installation_id"] do
      # The only registration authority is the conjunction above. A retry can
      # find its own existing ACTIVE row; a revoked row is never resurrected.
      query = Device |> Ash.Query.filter(installation_id == ^installation)

      # REVIEWED-UNAUTHORIZED: actor-owned installation under an authenticated
      # principal's exact, current governance-approved key; no client tenant/principal.
      case Ash.read_one(query, authorize?: false, tenant: actor.tenant_id) do
        {:ok, nil} ->
          Device
          |> Ash.Changeset.for_create(
            :register,
            %{
              tenant_id: actor.tenant_id,
              participant_id: actor.principal_id,
              installation_id: installation,
              public_key: params["public_key"]
            },
            tenant: actor.tenant_id
          )
          # REVIEWED-UNAUTHORIZED: same checked principal/key conjunction above.
          |> Ash.create(authorize?: false)

        {:ok, device} ->
          if device.status == :ACTIVE and device.participant_id == actor.principal_id and
               device.public_key == params["public_key"],
             do: {:ok, device},
             else: {:error, :device_rejected}

        _ ->
          {:error, :device_rejected}
      end
    else
      _ -> {:error, :device_rejected}
    end
  end

  # Check before idempotency lookup: revoked keys must not replay a stored 201.
  # The row lock serializes sequence admission, mutation and watermark advance.
  @spec submit(Dispatch.Access.Actor.t(), map(), map(), (map() -> term())) :: term()
  def submit(actor, session, params, fun) do
    if available?(),
      do: submit_available(actor, session, params, fun),
      else: {:error, :device_unavailable}
  end

  defp submit_available(actor, session, params, fun) do
    Dispatch.Repo.transaction(fn ->
      with event_id when is_binary(event_id) <- params["event_id"],
           {:ok, _event_uuid} <- Ecto.UUID.cast(event_id),
           device_id when is_binary(device_id) <- params["device_id"],
           {:ok, uuid} <- Ecto.UUID.dump(device_id),
           device when not is_nil(device) <-
             Dispatch.Repo.one(
               from(d in "devices",
                 where:
                   d.id == ^uuid and d.tenant_id == type(^actor.tenant_id, :binary_id) and
                     d.participant_id == type(^actor.principal_id, :binary_id),
                 select: %{
                   id: d.id,
                   public_key: d.public_key,
                   status: d.status,
                   last_sequence: d.last_sequence
                 },
                 lock: "FOR UPDATE"
               )
             ),
           true <- device.status == "ACTIVE",
           {:ok, scope} <- scope(actor),
           {:ok, public} <- decode(device.public_key, 32),
           :ok <- approved(session.principal, scope, public),
           {:ok, subject} <- Dispatch.Identity.Native.subject(session),
           true <- params["subject"] == subject,
           sequence when is_integer(sequence) and sequence > 0 <- params["device_sequence"],
           {:ok, signature} <- decode(params["device_signature"], 64),
           {:ok, bytes} <- signing_bytes(params, actor.role_assignment.id),
           true <- Crypto.verify(bytes, signature, public),
           :ok <- sequence_allowed(actor, params, device.last_sequence) do
        result =
          fun.(%{
            "signing_bytes" => Base.url_encode64(bytes, padding: false),
            "signature" => params["device_signature"],
            "public_key" => device.public_key
          })

        case result do
          {:ok, _, _} ->
            if sequence > device.last_sequence, do: advance_sequence!(actor, device_id, sequence)

            result

          error ->
            Dispatch.Repo.rollback(error)
        end
      else
        _ -> Dispatch.Repo.rollback({:error, :device_rejected})
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, error} -> error
    end
  end

  defp advance_sequence!(actor, device_id, sequence) do
    # REVIEWED-UNAUTHORIZED: this exact actor-owned row is locked above, and
    # its active grant and signature have already been verified. Reuse the
    # registry action so its timestamp and version lifecycle stay consistent.
    device = Ash.get!(Device, device_id, authorize?: false, tenant: actor.tenant_id)
    device
    |> Ash.Changeset.for_update(:record_sequence, %{last_sequence: sequence}, tenant: actor.tenant_id)
    |> Ash.update(authorize?: false)
    |> case do
      {:ok, _updated} -> :ok
      {:error, error} -> Dispatch.Repo.rollback({:error, error})
    end
  end

  @spec approved(String.t(), tuple(), binary()) :: :ok | {:error, atom()}
  def approved(principal, scope, public) do
    # key_id is only a four-byte display prefix. Compare the entire approved
    # public key, so a prefix collision cannot enrol a different key.
    grants = CoopSubstrate.Log.gate().orchestration.grants

    if Enum.any?(grants, fn {_id, g} ->
         g.active and g.principal_id == principal and g.pubkey == public and
           {g.chapter_id, g.tenant_id, g.project_id} == scope
       end), do: :ok, else: {:error, :device_rejected}
  end

  @spec signing_bytes(map(), String.t()) :: {:ok, binary()} | {:error, term()}
  def signing_bytes(params, assignment) do
    Canonical.encode(%{
      "schema" => "DispatchStatusV1",
      "role_assignment_id" => assignment,
      "payload" => Map.delete(params, "device_signature")
    })
  end

  defp sequence_allowed(actor, params, last) do
    if params["device_sequence"] > last do
      :ok
    else
      event = Dispatch.Operations.Declarations.by_id(actor, params["event_id"])

      if event && event.device_id == params["device_id"] &&
           event.device_sequence == params["device_sequence"] &&
           event.role_assignment_id == actor.role_assignment.id, do: :ok, else: {:error, :replay}
    end
  end

  @spec decode(term(), non_neg_integer()) :: {:ok, binary()} | {:error, atom()}
  def decode(value, size) when is_binary(value) do
    with {:ok, bytes} <- Base.url_decode64(value, padding: false),
         true <- byte_size(bytes) == size,
         do: {:ok, bytes},
         else: (_ -> {:error, :invalid_bytes})
  end

  def decode(_, _), do: {:error, :invalid_bytes}

  @spec key_id(binary()) :: String.t()
  def key_id(<<prefix::binary-size(4), _::binary>>),
    do: "k-" <> Base.encode16(prefix, case: :lower)
end
