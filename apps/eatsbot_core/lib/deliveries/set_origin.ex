defmodule EatsbotCore.Deliveries.SetOrigin do
  @moduledoc """
  Sets a new delivery's origin (name and coordinates) from the application config.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    {lat, lng} = Application.get_env(:eatsbot, :from_location, {0, 0})
    name = Application.get_env(:eatsbot, :business_name, "A business")

    Ash.Changeset.change_attributes(changeset, %{
      from_name: name,
      from_latitude: lat,
      from_longitude: lng
    })
  end
end
