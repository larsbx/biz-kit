defmodule EatsbotWeb.Deliveries.DeliveryAuthPlug do
  @moduledoc """
  Sets the delivery actor from a recognized credential. Invalid credentials
  leave the request unauthenticated so resource policies can reject it.
  """
  @behaviour Plug
  import Plug.Conn
  alias AshAuthentication.Plug.Helpers

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{assigns: %{current_user: %{admin?: true}}} = conn, _opts) do
    conn
    |> assign(:actor, generate_actor(:admin))
    |> Helpers.set_actor(:actor)
  end

  @impl true
  def call(conn, _opts) do
    with false <- Map.has_key?(conn.assigns, :actor),
         ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, actor, resource} <- get_token_data(token) do
      conn
      |> assign(:resource, resource)
      |> assign(:actor, actor)
      |> Helpers.set_actor(:actor)
    else
      _ -> conn
    end
  end

  @spec get_token_data(String.t()) ::
          {:ok, %{access_level: atom()}, EatsbotCore.Deliveries.Delivery.t() | nil} | :error
  def get_token_data(token) do
    if admin?(token) do
      # The admin credential is not bound to a delivery.
      {:ok, generate_actor(:admin), nil}
    else
      with {:ok, _uuid} <- Ecto.UUID.cast(token),
           {:ok, [resource]} <-
             EatsbotCore.Deliveries.Delivery.get_via_token(token, authorize?: false) do
        {:ok, generate_actor(token, resource), resource}
      else
        _ -> :error
      end
    end
  end

  @spec generate_actor(atom()) :: %{access_level: atom()}
  defp generate_actor(:admin), do: EatsbotCore.Deliveries.Actors.admin()

  @spec generate_actor(atom(), EatsbotCore.Deliveries.Delivery.t()) :: %{access_level: atom()}
  defp generate_actor(token, %{public_auth_key: public_key, private_auth_key: private_key}) do
    cond do
      token == public_key -> EatsbotCore.Deliveries.Actors.public()
      token == private_key -> EatsbotCore.Deliveries.Actors.private()
    end
  end

  @spec admin?(String.t()) :: boolean()
  defp admin?(token), do: token == System.get_env("ADMIN_API_KEY")
end
