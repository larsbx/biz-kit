# Native apps' sessions in the host's Postgres, as in the releases
# (config/runtime.exs sets this for dev and prod only).
Application.put_env(:biz_kit_identity, :session_store, BizKit.Identity.PostgresSessionStore)
Application.put_env(:biz_kit_identity, :session_repo, TaskHost.Repo)

# :browser needs Node, Playwright and Chromium (test/browser).
{:ok, _} = Application.ensure_all_started(:task_host)
ExUnit.start(exclude: [:browser])
