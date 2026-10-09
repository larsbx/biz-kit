defmodule Mix.Tasks.Harness.Keys do
  @shortdoc "Operator role keys: gen <role> | list | genesis [blob_path] [--yes]"
  @moduledoc """
  Runbook 0.2 (`docs/runbook_gate_d.md`). Seeds are 0600 files under
  `HARNESS_KEYS_DIR`; nothing here prints one. `genesis` declares
  governance (TOFU) + steward + checkpoint and emits the checkpoint blob —
  **publish that blob outside this machine**.
  """

  use Mix.Task

  alias CoopSubstrate.Harness.Ops
  alias CoopSubstrate.Harness.Ops.CLI

  @impl true
  def run(args) do
    CLI.start_app()

    case args do
      ["gen", role] ->
        case Ops.gen_key(role) do
          {:ok, %{role: role, key_id: key_id, path: path}} ->
            CLI.ok("generated role=#{role} key_id=#{key_id} path=#{path} (seed stays on disk, 0600)")

          {:error, reason} ->
            CLI.reject(reason)
        end

      ["list"] ->
        case Ops.list_keys() do
          {:ok, keys} ->
            Enum.each(keys, &CLI.ok("role=#{&1.role} key_id=#{&1.key_id}"))

          {:error, reason} ->
            CLI.reject(reason)
        end

      ["genesis" | rest] ->
        {opts, positional, _} = OptionParser.parse(rest, strict: [yes: :boolean])
        blob_path = List.first(positional) || "genesis_checkpoint.bin"

        CLI.confirm!(
          "GENESIS: declare governance (trust-on-first-use) + steward + checkpoint keys,\n" <>
            "then emit a checkpoint to #{blob_path}.",
          opts
        )

        case Ops.genesis(blob_path) do
          {:ok, %{declared: declared, checkpoint_path: path}} ->
            Enum.each(declared, fn {role, status} -> CLI.ok("declared role=#{role} #{status}") end)
            CLI.ok("checkpoint=#{path}")
            CLI.ok("PUBLISH #{path} OUTSIDE THIS MACHINE — it is the TOFU mitigation.")

          {:error, reason} ->
            CLI.reject(reason)
        end

      _ ->
        Mix.raise("usage: mix harness.keys gen <role> | list | genesis [blob_path] [--yes]")
    end
  end
end
