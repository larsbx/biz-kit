defmodule RestaurantHost.Web.PairController do
  @moduledoc """
  Pairs a kitchen board: its secret, compared in constant time, puts the board
  in this browser's signed session. Without it the board page signs nothing.
  """
  use Phoenix.Controller, formats: [:html]

  alias RestaurantHost.Restaurant

  def pair(conn, %{"board" => board, "secret" => secret}) do
    case Restaurant.pair(Restaurant.current(), board, secret) do
      {:ok, board} ->
        conn
        |> configure_session(renew: true)
        |> put_session(:board, board)
        |> redirect(to: "/board")

      :error ->
        conn |> put_status(:forbidden) |> text("Unknown board")
    end
  end
end
