defmodule Mix.Tasks.Harness.Consent do
  @shortdoc "The consent ceremony: --ref IV-1 --classes synthesis,anonymized_fixtures [--recording]"
  @moduledoc """
  Runbook phase 2 — run this WITH the interviewee present; the signature is
  theirs. The seed prints exactly once below: hand it over (printout/photo,
  their choice) and do not keep a copy. Nothing is persisted here.
  """

  use Mix.Task

  alias CoopSubstrate.Harness.Ops
  alias CoopSubstrate.Harness.Ops.CLI

  @impl true
  def run(args) do
    CLI.start_app()

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [ref: :string, classes: :string, recording: :boolean]
      )

    ref = opts[:ref] || Mix.raise("missing --ref (the pseudonymous interviewee_ref)")
    classes = String.split(opts[:classes] || "", ",", trim: true)
    recording = opts[:recording] || false

    case Ops.consent_ceremony(ref, classes, recording) do
      {:ok, %{interviewee_ref: ^ref, key_id: key_id, seed_hex: seed_hex}} ->
        CLI.ok("consent recorded interviewee_ref=#{ref} key_id=#{key_id}")
        CLI.ok("")
        CLI.ok("==== SEED HANDOVER — shown ONCE, never stored ====")
        CLI.ok(seed_hex)
        CLI.ok("==== give this to the interviewee; revocation requires it ====")

      {:error, reason} ->
        CLI.reject(reason)
    end
  end
end
