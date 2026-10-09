defmodule CoopSubstrate.Harness.Fixtures do
  @moduledoc """
  Predicate-enforced fixture publication (Phase 2D; corpus 11 §1.5): a
  fixture set containing ANY anonymization violation is unpublishable — a
  build failure, not a review note. The bundle is deterministic
  (name-sorted), content-addressed, and published by the 2A-gated
  `FixtureSetPublished` (source consent classes checked at the gate). The
  operator's denylist is an input only — it never enters the artifact.
  """

  alias CoopSubstrate.Canonical
  alias CoopSubstrate.Crypto
  alias CoopSubstrate.Harness.Anonymization
  alias CoopSubstrate.Harness.Artifacts
  alias CoopSubstrate.Log
  alias CoopSubstrate.Protocol.Envelope

  @doc """
  Publish a fixture set: `fixtures` is a list of
  `%{"name" => String.t(), "content" => String.t()}`; `denylist` the
  operator's literal redaction terms; `source_refs` the interview ids the
  fixtures derive from (their `anonymized_fixtures` consent is gate-checked).
  """
  @spec publish(String.t(), String.t(), [map()], [String.t()], [String.t()], String.t(), <<_::256>>) ::
          {:ok, %{fixture_hash: <<_::256>>}} | {:error, term()}
  def publish(chapter_id, section, fixtures, denylist, source_refs, key_id, seed) do
    with :ok <- check_fixtures(fixtures, denylist),
         {:ok, bytes} <-
           Canonical.encode(%{
             "schema" => "FixtureSetV1",
             "section" => section,
             "fixtures" => Enum.sort_by(fixtures, & &1["name"])
           }),
         {:ok, fixture_hash} <- Artifacts.put(bytes),
         {:ok, envelope} <-
           Envelope.new(%{
             chapter_id: chapter_id,
             type: "FixtureSetPublished",
             payload: %{
               "section" => section,
               "fixture_hash" => {:bytes, fixture_hash},
               "source_refs" => source_refs
             },
             signers: [
               %{role: "steward", pubkey: Crypto.pubkey_from_seed(seed), key_id: key_id}
             ],
             timestamp_ms: System.system_time(:millisecond)
           }),
         {:ok, signed} <- Envelope.sign(envelope, key_id, seed),
         {:ok, _} <- Log.append(signed) do
      {:ok, %{fixture_hash: fixture_hash}}
    end
  end

  defp check_fixtures([], _denylist), do: {:error, :no_fixtures}

  defp check_fixtures(fixtures, denylist) do
    Enum.find_value(fixtures, :ok, fn
      %{"name" => name, "content" => content} when is_binary(name) and is_binary(content) ->
        case Anonymization.violations(content, denylist) do
          [] -> nil
          violations -> {:error, {:anonymization_violation, name, violations}}
        end

      other ->
        {:error, {:malformed_fixture, other}}
    end)
  end
end
