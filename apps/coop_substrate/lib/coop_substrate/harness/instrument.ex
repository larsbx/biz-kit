defmodule CoopSubstrate.Harness.Instrument do
  @moduledoc """
  The interview instrument as **versioned data, never code** (Phase 2B;
  corpus 11 §1.2/§6.3): a question tree validated, canonically encoded,
  stored out-of-log, and published by `InstrumentVersionPublished` — so a
  question change is a diffable, reviewable event, and leading-question
  contamination is auditable (11's adversarial suite). The tree hash IS the
  artifact hash: SHA-256 over the frozen canonical encoding.

  Tree shape:

      %{"section" => "D",
        "personas" => [
          %{"persona" => "carrier_owner",
            "questions" => [
              %{"id" => "co-1", "text" => "...", "follow_ups" => ["co-2"]}, ...]}]}
  """

  alias CoopSubstrate.Canonical
  alias CoopSubstrate.Constants
  alias CoopSubstrate.Crypto
  alias CoopSubstrate.Harness.Artifacts
  alias CoopSubstrate.Log
  alias CoopSubstrate.Projections.Membership
  alias CoopSubstrate.Protocol.Envelope

  @doc "Structural validation: known section, unique ids, resolving follow-ups."
  @spec validate(map()) :: :ok | {:error, term()}
  def validate(%{"section" => section, "personas" => personas} = tree)
      when is_list(personas) and personas != [] do
    questions = all_questions(tree)
    ids = Enum.map(questions, & &1["id"])

    cond do
      section not in Constants.harness_sections() ->
        {:error, {:unknown_section, section}}

      Enum.any?(personas, fn p ->
        not (is_binary(p["persona"]) and p["persona"] != "" and
               is_list(p["questions"]) and p["questions"] != [])
      end) ->
        {:error, :malformed_persona}

      Enum.any?(questions, fn q ->
        not (is_binary(q["id"]) and q["id"] != "" and is_binary(q["text"]) and q["text"] != "")
      end) ->
        {:error, :malformed_question}

      ids != Enum.uniq(ids) ->
        {:error, :duplicate_question_ids}

      (dangling = Enum.flat_map(questions, &Map.get(&1, "follow_ups", [])) |> Enum.uniq() |> Kernel.--(ids)) != [] ->
        {:error, {:dangling_follow_ups, Enum.sort(dangling)}}

      true ->
        :ok
    end
  end

  def validate(_tree), do: {:error, :malformed_tree}

  @doc "The tree's content address: SHA-256 over its canonical encoding."
  @spec hash(map()) :: {:ok, <<_::256>>} | {:error, term()}
  def hash(tree), do: Canonical.hash(tree)

  @doc """
  Validate, store the canonical bytes as an artifact, and publish the next
  version for the tree's section (the 2A gate enforces monotonicity).
  """
  @spec publish(String.t(), map(), String.t(), <<_::256>>) ::
          {:ok, %{version: pos_integer(), tree_hash: <<_::256>>}} | {:error, term()}
  def publish(chapter_id, tree, key_id, seed) do
    with :ok <- validate(tree),
         {:ok, bytes} <- Canonical.encode(tree),
         {:ok, tree_hash} <- Artifacts.put(bytes),
         {:ok, state} <- Log.replay(Membership) do
      version = Map.get(state.instrument_versions, {chapter_id, tree["section"]}, 0) + 1

      {:ok, envelope} =
        Envelope.new(%{
          chapter_id: chapter_id,
          type: "InstrumentVersionPublished",
          payload: %{
            "section" => tree["section"],
            "version" => version,
            "tree_hash" => {:bytes, tree_hash}
          },
          signers: [%{role: "steward", pubkey: Crypto.pubkey_from_seed(seed), key_id: key_id}],
          timestamp_ms: System.system_time(:millisecond)
        })

      {:ok, signed} = Envelope.sign(envelope, key_id, seed)

      with {:ok, _} <- Log.append(signed) do
        {:ok, %{version: version, tree_hash: tree_hash}}
      end
    end
  end

  @doc "Fetch a published version: event → artifact → decoded tree, hash-checked."
  @spec fetch(String.t(), String.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def fetch(chapter_id, section, version) do
    with {:ok, envelopes} <- Log.read_stream(chapter_id <> "/harness/" <> section) do
      publication =
        Enum.find(envelopes, fn env ->
          env.type == "InstrumentVersionPublished" and env.payload["version"] == version
        end)

      case publication do
        nil ->
          {:error, {:unknown_instrument_version, section, version}}

        %{payload: %{"tree_hash" => {:bytes, tree_hash}}} ->
          with {:ok, bytes} <- Artifacts.get(tree_hash) do
            Canonical.decode(bytes)
          end
      end
    end
  end

  @doc "Question-level diff between two trees: added / removed / changed ids."
  @spec diff(map(), map()) :: %{added: [String.t()], removed: [String.t()], changed: [String.t()]}
  def diff(tree_a, tree_b) do
    a = questions_by_id(tree_a)
    b = questions_by_id(tree_b)

    %{
      added: Enum.sort(Map.keys(b) -- Map.keys(a)),
      removed: Enum.sort(Map.keys(a) -- Map.keys(b)),
      changed:
        Map.keys(a)
        |> Enum.filter(&(Map.has_key?(b, &1) and a[&1] != b[&1]))
        |> Enum.sort()
    }
  end

  @doc """
  The v1 D instrument (corpus 11 §4-D). Content, not policy: publishing it
  is the operator's act. The core question — where exactly does trust stop —
  is what compiles into the envelope defaults (11 §1.3).
  """
  @spec seed_d() :: map()
  def seed_d do
    %{
      "section" => "D",
      "personas" => [
        %{
          "persona" => "carrier_owner",
          "questions" => [
            %{"id" => "co-1", "text" => "How do tenders actually arrive today — email, EDI, portal, text, phone? Roughly what share each?"},
            %{"id" => "co-2", "text" => "Walk me through the last tender you accepted: what did you check, in what order, before saying yes?", "follow_ups" => ["co-3"]},
            %{"id" => "co-3", "text" => "What would you let software accept on your behalf — which lanes, what rate floor, which counterparties — and where exactly does trust stop?"},
            %{"id" => "co-4", "text" => "Who assigns the driver, and what does that decision actually turn on?"},
            %{"id" => "co-5", "text" => "What paperwork moves with a load, and where does it get stuck?"},
            %{"id" => "co-6", "text" => "Tell me about the last time a load went wrong — breakdown, reschedule, driver swap. What happened, step by step?"}
          ]
        },
        %{
          "persona" => "dispatcher",
          "questions" => [
            %{"id" => "di-1", "text" => "What does your tracking ritual look like — check calls, ELD pings, texts? How often, and who asks for it?"},
            %{"id" => "di-2", "text" => "When you decline a tender, why — and how fast do you have to answer to keep the relationship?"},
            %{"id" => "di-3", "text" => "Which exceptions eat your day? Rank them."},
            %{"id" => "di-4", "text" => "What tool or spreadsheet is actually running dispatch right now? What does it get wrong?"}
          ]
        },
        %{
          "persona" => "driver",
          "questions" => [
            %{"id" => "dr-1", "text" => "What does a good dispatch look like from the seat — what information do you want before you roll?"},
            %{"id" => "dr-2", "text" => "Where do you wait, and what are you told while you wait?"},
            %{"id" => "dr-3", "text" => "What paperwork do you handle at pickup and delivery, and what happens when it's wrong?"}
          ]
        }
      ]
    }
  end

  defp all_questions(%{"personas" => personas}) when is_list(personas) do
    Enum.flat_map(personas, fn
      %{"questions" => questions} when is_list(questions) -> Enum.filter(questions, &is_map/1)
      _ -> []
    end)
  end

  defp all_questions(_), do: []

  defp questions_by_id(tree) do
    for persona <- tree["personas"] || [],
        question <- persona["questions"] || [],
        into: %{} do
      {question["id"], {persona["persona"], Map.delete(question, "id")}}
    end
  end
end
