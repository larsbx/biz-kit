defmodule Dispatch.Support.PortalIdentity do
  @moduledoc false

  alias BizKit.Identity.{Sessions, Principal}

  def setup do
    old_bindings = Application.get_env(:biz_kit_identity, :bindings, [])
    old_identity = Application.get_env(:dispatch, :identity)

    Application.put_env(
      :dispatch,
      :identity,
      Keyword.put(old_identity, :token_verifier, Dispatch.Identity.Tokens.BizKitSession)
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:biz_kit_identity, :bindings, old_bindings)
      Application.put_env(:dispatch, :identity, old_identity)
    end)

    :ok
  end

  def token_for(subject, opts \\ []) do
    true = Principal.valid?(subject)
    identity = %{issuer: "https://portal.test", subject: subject}
    bindings = Application.get_env(:biz_kit_identity, :bindings, [])
    binding = Map.put(identity, :principal, subject)

    Application.put_env(:biz_kit_identity, :bindings, [
      binding
      | Enum.reject(
          bindings,
          &(&1.issuer == identity.issuer and &1.subject == subject)
        )
    ])

    token = Sessions.create(subject, identity)

    if at = opts[:authenticated_at] do
      # Runs inside the owning singleton, without wall-clock sleeps.
      :sys.replace_state(BizKit.Cluster.Singleton.name(Sessions), fn state ->
        key = {false, :crypto.hash(:sha256, token)}
        true = :ets.update_element(Sessions, key, {5, DateTime.to_unix(at, :millisecond)})
        state
      end)
    end

    token
  end

  def bind(entries) do
    case List.keyfind(entries, DispatchWeb.Plugs.PortalSession.subject_key(), 0) do
      {_, subject} ->
        reference = subject |> token_for() |> Sessions.reference()
        [{DispatchWeb.Plugs.PortalSession.reference_key(), reference} | entries]

      _ ->
        entries
    end
  end
end
