defmodule RestaurantHost.ReleaseTasks do
  @moduledoc """
  Release tasks for the `restaurant` release, where Mix is absent
  (docs/deploy.md). An explicit operator step before each start, never run on
  boot:

      bin/restaurant eval "RestaurantHost.ReleaseTasks.migrate()"

  The host keeps no database of its own: every order lives in the ledger, so
  migrating means initializing the ledger's event stores. Idempotent.
  """

  @doc "Review and enroll devices from an operator's release copy, without starting the host."
  def grant(args), do: RestaurantHost.Enrollment.main(args)

  @doc "Add or replace a menu item from an operator's release copy, without starting the host."
  def menu(args), do: RestaurantHost.MenuEditor.main(args)

  @spec migrate() :: :ok
  def migrate, do: CoopSubstrate.ReleaseTasks.init_event_stores()
end
