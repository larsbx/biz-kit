defmodule Mix.Tasks.Coop.Owner.Backfill do
  @shortdoc "Governance-sign an existing project's first accountable owner"
  @moduledoc """
  Backfill an existing ownerless TaskCore project without changing its history.

      mix coop.owner.backfill CHAPTER TENANT PROJECT PRINCIPAL \\
        --server https://bizkit.example --yes

  If the principal does not already have an active operator grant in the
  project, supply a *pre-existing* device's key and public key:

      --device-key-id KEY --device-pubkey BASE64URL

  The governance signing seed is read from HARNESS_KEYS_DIR, never sent to
  the server. All returned canonical commands are checked against the
  intended chapter, tenant, project, principal and optional device before
  signing. No human principal is inferred from an identity provider.
  """
  use Mix.Task

  alias CoopSubstrate.Governance.Client
  alias CoopSubstrate.Harness.Ops

  @impl true
  def run(args) do
    Mix.Task.run("app.config")

    {opts, positions, invalid} =
      OptionParser.parse(args,
        strict: [
          server: :string,
          yes: :boolean,
          device_key_id: :string,
          device_pubkey: :string
        ]
      )

    unless invalid == [] and length(positions) == 4 do
      Mix.raise(
        "usage: mix coop.owner.backfill CHAPTER TENANT PROJECT PRINCIPAL " <>
          "[--server URL] [--device-key-id KEY --device-pubkey BASE64URL] [--yes]"
      )
    end

    [chapter, tenant, project, principal] = positions
    base = opts[:server] || System.get_env("BIZKIT_URL", "http://127.0.0.1:4000")

    with {:ok, device} <- device(opts),
         {:ok, signer} <- Ops.load_signer("governance") do
      path =
        "/api/v1/chapters/#{Client.segment(chapter)}/tenants/#{Client.segment(tenant)}" <>
          "/projects/#{Client.segment(project)}/ownership/backfill/#{Client.segment(principal)}"

      if opts[:yes] ||
           Mix.shell().yes?(
             "Assign #{principal} as accountable owner of #{chapter}/#{tenant}/#{project}?"
           ) do
        expected = &matches?(&1, {chapter, tenant, project}, principal, device)

        case Client.sign_batch(base <> path, signer, expected, params(device)) do
          {:ok, %{"events" => events}} ->
            Mix.shell().info("backfilled owner #{principal}: #{length(events)} signed events")

          {:error, reason} ->
            Mix.raise("owner not backfilled: #{inspect(reason)}")
        end
      else
        Mix.shell().info("nothing was signed")
      end
    else
      {:error, reason} -> Mix.raise("cannot backfill: #{inspect(reason)}")
    end
  end

  defp device(opts) do
    case {opts[:device_key_id], opts[:device_pubkey]} do
      {nil, nil} ->
        {:ok, nil}

      {key, text} when is_binary(key) and is_binary(text) ->
        with {:ok, bytes} <- Base.url_decode64(text, padding: false),
             true <- byte_size(bytes) == 32 and key != "" do
          {:ok, %{key_id: key, pubkey: bytes}}
        else
          _ -> {:error, :invalid_operator_device}
        end

      _ ->
        {:error, :invalid_operator_device}
    end
  end

  defp params(nil), do: %{}

  defp params(%{key_id: key_id, pubkey: pubkey}) do
    %{
      "operator_device" => %{
        "key_id" => key_id,
        "pubkey" => Base.url_encode64(pubkey, padding: false)
      }
    }
  end

  @doc false
  def matches?(cores, {chapter, tenant, project}, principal, device)
      when is_list(cores) do
    types = Enum.map(cores, & &1["type"])

    permitted =
      if device == nil do
        [
          ["TaskProjectOwnerAssignedV1"],
          ["TaskPrincipalKindDeclaredV1", "TaskProjectOwnerAssignedV1"]
        ]
      else
        [
          ["TaskOperatorGrantedV1", "TaskProjectOwnerAssignedV1"],
          ["TaskPrincipalKindDeclaredV1", "TaskOperatorGrantedV1", "TaskProjectOwnerAssignedV1"]
        ]
      end

    types in permitted and
      Enum.all?(cores, fn core ->
        core["chapter_id"] == chapter and
          case {core["type"], core["payload"]} do
            {"TaskPrincipalKindDeclaredV1", p} ->
              p == %{"principal_id" => principal, "kind" => "human"}

            {"TaskOperatorGrantedV1", p} ->
              device != nil and
                p == %{
                  "tenant_id" => tenant,
                  "project_id" => project,
                  "principal_id" => principal,
                  "key_id" => device.key_id,
                  "pubkey" => {:bytes, device.pubkey}
                }

            {"TaskProjectOwnerAssignedV1", p} ->
              p == %{
                "tenant_id" => tenant,
                "project_id" => project,
                "principal_id" => principal
              }

            _ ->
              false
          end
      end)
  end

  def matches?(_, _, _, _), do: false
end
