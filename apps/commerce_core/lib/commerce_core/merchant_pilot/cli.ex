defmodule CommerceCore.MerchantPilot.CLI do
  @moduledoc "Offline command boundary. Errors never echo filenames, source rows or exception details."
  alias CommerceCore.MerchantPilot.{Intake, JSON, Scorecard}
  import CommerceCore.MerchantPilot.Validation

  def main(args) do
    case args do
      ["score", input | rest] ->
        check!(rest in [[], ["--include-orders"]], :arguments)
        input |> read!() |> Scorecard.score!(include_orders: rest != []) |> print()
        0

      ["export", input, destination] ->
        {snapshot, manifest} = input |> read!() |> Intake.export!()
        write!(destination, snapshot, manifest)

        IO.puts(
          "Created private snapshot and provenance manifest; no commercial outcome inferred."
        )

        0

      ["export", input, destination, "--records", directory] ->
        check!(File.dir?(directory), :records_directory)

        records =
          Path.wildcard(Path.join(directory, "*.json")) |> Enum.sort() |> Enum.map(&read!/1)

        {snapshot, manifest} = input |> read!() |> Intake.assemble!(records) |> Intake.export!()
        write!(destination, snapshot, manifest)

        IO.puts(
          "Created private snapshot and provenance manifest; no commercial outcome inferred."
        )

        0

      ["batch"] ->
        batch()

      _ ->
        IO.puts(
          :stderr,
          "Usage: merchant pilot score SNAPSHOT [--include-orders] | export INTAKE NEW_DIRECTORY [--records DIRECTORY]"
        )

        2
    end
  rescue
    _ ->
      IO.puts(
        :stderr,
        "Merchant pilot operation refused. Check schema, evidence, scope and common cutoff privately."
      )

      2
  end

  def read!(path), do: path |> File.read!() |> JSON.decode!()
  defp print(value), do: IO.puts(JSON.encode!(value))
  # Internal NDJSON bridge for finite Lean/Quint conformance. No application state is started.
  defp batch do
    IO.stream(:stdio, :line)
    |> Enum.each(fn line ->
      result =
        try do
          command = JSON.decode!(line)

          case command["op"] do
            "export" ->
              {snapshot, manifest} = Intake.export!(command["bundle"])

              %{
                "ok" => true,
                "snapshot" => snapshot,
                "manifest" => manifest,
                "report" => Scorecard.score!(snapshot, include_orders: true)
              }

            "score" ->
              %{
                "ok" => true,
                "report" => Scorecard.score!(command["snapshot"], include_orders: true)
              }
          end
        rescue
          _ -> %{"ok" => false}
        end

      print(result)
    end)

    0
  end

  def write!(destination, snapshot, manifest) do
    # Exclusive directory creation precedes writes. Never follow or replace an existing output.
    File.mkdir!(destination)

    try do
      File.chmod!(destination, 0o700)

      for {name, value} <- [{"snapshot.json", snapshot}, {"provenance.private.json", manifest}] do
        path = Path.join(destination, name)
        {:ok, file} = File.open(path, [:write, :exclusive, :binary])

        try do
          File.chmod!(path, 0o600)
          :ok = IO.binwrite(file, JSON.encode!(value) <> "\n")
        after
          File.close(file)
        end
      end

      :ok
    rescue
      exception ->
        File.rm_rf(destination)
        reraise exception, __STACKTRACE__
    end
  end
end
