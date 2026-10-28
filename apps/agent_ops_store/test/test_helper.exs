ExUnit.start()

defmodule AgentOpsStore.TestConnection do
  def options do
    [
      hostname: "127.0.0.1",
      port: System.get_env("BIZKIT_OPS_TEST_PORT", "5544") |> String.to_integer(),
      username: System.get_env("BIZKIT_OPS_TEST_USER", "bizkit"),
      password: System.fetch_env!("BIZKIT_PG_PASSWORD_FILE") |> File.read!() |> String.trim(),
      database: System.get_env("BIZKIT_OPS_TEST_DATABASE", "bizkit_agent_dev")
    ]
  end
end
