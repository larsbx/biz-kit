defmodule TaskHost.Repo do
  @moduledoc """
  The task host's Postgres: native apps' sessions
  (`BizKit.Identity.PostgresSessionStore`). Every business fact is the
  ledger's; nothing else is kept here.
  """
  use Ecto.Repo, otp_app: :task_host, adapter: Ecto.Adapters.Postgres
end
