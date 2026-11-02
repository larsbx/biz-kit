defmodule RestaurantHost.ReleaseTasks do
  @moduledoc """
  Release tasks for the `restaurant` release, where Mix is absent
  (docs/deploy.md). An explicit operator step before each start, never run on
  boot:

      bin/restaurant eval "RestaurantHost.ReleaseTasks.migrate()"

  The host keeps no database of its own: every order lives in the ledger, so
  migrating means initializing the ledger's event stores. Idempotent.
  """

  @spec migrate() :: :ok
  def migrate, do: CoopSubstrate.ReleaseTasks.init_event_stores()
end
