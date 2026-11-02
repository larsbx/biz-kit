defmodule ProofBankCore.Portfolio do
  @moduledoc """
  Repository-derived **draft** Proof Bank intake for Biz-kit and all its
  in-umbrella applications. This is an owner-review backlog, not an
  approved specification, a proof of an implementation, or a grant.

  Source files establish package identity; proposed requirements need
  domain owner review. Referenced formal files are leads for *investigation*,
  not evidence that the property has been proven. This module performs no
  I/O except an explicitly requested directory inventory check.
  """

  @catalog_version "proof-bank.biz-kit-portfolio.v1"

  # Source inventory: apps/*/mix.exs at repository main commit
  # 4c550f01effe1bedba235fa68899e1b435bdde02.
  # Do not represent these draft statements as current verified guarantees.
  @applications [
    {"agent_core", :foundation, :conformance,
     "Execution profiles and agent output must not independently authorize business commands."},
    {"agent_ops_store", :foundation, :conformance,
     "Stale attempt leases and duplicate run effects must not become accepted outcomes."},
    {"barter_core", :capability, :conformance,
     "Barter proposals must not create settled or binding obligations without the specified bilateral admission."},
    {"biz_kit_cluster", :foundation, :conformance,
     "Cluster coordination must not permit a stale instance to act with revoked command authority."},
    {"biz_kit_composition", :capability, :conformance,
     "Cross-domain previews must never be mistaken for inventory reservations, orders, or fulfillment acceptance."},
    {"biz_kit_identity", :foundation, :conformance,
     "Revoked or expired authentication sessions and grants must not regain protected access."},
    {"commerce_core", :capability, :conformance,
     "Pricing must preserve currency consistency and agreed arithmetic under supported input shapes."},
    {"coop_substrate", :foundation, :lean,
     "Accepted signed business events must preserve canonical bytes, scope, idempotency and ordered replay."},
    {"dispatch", :hosted, :lean,
     "Dispatch assignments must remain organization-scoped and must not violate configured active-operator exclusivity."},
    {"dispatch_core", :capability, :conformance,
     "Transport handoff and status rules must not claim a delivery completed without required evidence."},
    {"eatsbot", :legacy, :manual,
     "Retirement must preserve existing authoritative order and customer history without enabling competing writers."},
    {"eatsbot_core", :legacy, :manual,
     "Salvaged restaurant rules must not silently become a second independent production authority."},
    {"eatsbot_extension_kafka", :legacy, :conformance,
     "Notification delivery or retry must not itself authorize an additional business effect."},
    {"eatsbot_extension_prometheus", :legacy, :conformance,
     "Metrics and monitoring access must not expose unauthorized private business data or grant commands."},
    {"eatsbot_extension_telegram_bot", :legacy, :conformance,
     "Telegram input must never be treated as sufficient authenticated business admission."},
    {"federation_core", :capability, :conformance,
     "Remote advertisements and projections must not be interpreted as local authoritative business facts."},
    {"federation_service", :hosted, :conformance,
     "Untrusted federation messages must not bypass local signatures, scoped grants or admission."},
    {"fulfillment_core", :capability, :conformance,
     "A fulfillment request must remain distinct from an authenticated transport acceptance and final delivery."},
    {"group_buy_core", :capability, :conformance,
     "Pledges and pooled orders must not become funded or released without authoritative escrow evidence."},
    {"hawala_capability", :capability, :conformance,
     "A Biz-kit host must not sign participant financial consent or infer settlement from operational intent."},
    {"inventory_core", :capability, :conformance,
     "Concurrent reservations must preserve stock availability and versioned reservation invariants."},
    {"keel", :foundation, :conformance,
     "Ownership and operator relationships must not grant access beyond current authorized scope."},
    {"marketing_core", :capability, :conformance,
     "Marketing attribution and promotions must not circumvent current consent or independently commit money."},
    {"sales_core", :capability, :conformance,
     "Withdrawal of marketing consent must prevent future actions under superseded consent."},
    {"school_ops", :hosted, :conformance,
     "Curriculum source revisions must be pinned and staff task completion must not imply learner attainment."},
    {"spruce_goose", :hosted, :manual,
     "Existing orchestration commands must not create a second writer during signed-ledger migration."},
    {"task_core", :foundation, :conformance,
     "Task transitions must refuse stale versions and preserve signed approval and review requirements."},
    {"proof_bank_core", :foundation, :conformance,
     "A generated proof obligation or implementation candidate must never be represented as verified or activated."}
  ]

  # Existing model files are leads for review. No model has been asserted
  # equivalent to the corresponding current Elixir implementation.
  @model_candidates %{
    "coop_substrate" => "formal/lean/BizKitEventProofs.lean",
    "dispatch" => "formal/lean/BizKitDispatch.lean",
    "agent_ops_store" => "formal/lean/BizKitLeases.lean",
    "eatsbot_core" => "formal/quint/eatsbot_delivery_candidate.qnt",
    "dispatch_core" => "formal/quint/dispatch_trip.qnt",
    "spruce_goose" => "formal/quint/event_cursor.qnt"
  }

  @type entry :: %{
          required(:id) => String.t(),
          required(:tier) => atom(),
          required(:source) => String.t(),
          required(:requirement) => String.t(),
          required(:method) => atom(),
          required(:model_candidate) => String.t() | nil,
          required(:review_state) => :needs_owner_review
        }

  @spec entries() :: [entry()]
  def entries do
    platform = %{
      id: "biz-kit",
      tier: :platform,
      source: "mix.exs",
      requirement:
        "Business-effect admission, scope and financial authority must remain with their existing domain owners.",
      method: :conformance,
      model_candidate: "formal/lean/BizKitBundles.lean",
      review_state: :needs_owner_review
    }

    apps =
      Enum.map(@applications, fn {id, tier, method, requirement} ->
        %{
          id: id,
          tier: tier,
          source: "apps/" <> id <> "/mix.exs",
          requirement: requirement,
          method: method,
          model_candidate: Map.get(@model_candidates, id),
          review_state: :needs_owner_review
        }
      end)

    [platform | apps]
  end

  @doc """
  Compile draft requirements for every installed first-party/legacy app.
  All outputs remain *unverified* and *inert*, regardless of compiler success.
  """
  @spec compile_all() :: {:ok, [map()]} | {:error, term()}
  def compile_all do
    Enum.reduce_while(entries(), {:ok, []}, fn entry, {:ok, acc} ->
      case ProofBankCore.compile(candidate(entry)) do
        {:ok, blueprint} ->
          enriched =
            Map.put(blueprint, :portfolio, %{
              schema: @catalog_version,
              tier: entry.tier,
              source: entry.source,
              model_candidate: entry.model_candidate,
              review_state: entry.review_state,
              formal_equivalence: :not_established,
              deployment_conformance: :not_established
            })

          {:cont, {:ok, [enriched | acc]}}

        {:error, reason} ->
          {:halt, {:error, {entry.id, reason}}}
      end
    end)
    |> case do
      {:ok, compiled} -> {:ok, Enum.reverse(compiled)}
      error -> error
    end
  end

  @spec candidate(entry()) :: map()
  def candidate(entry) do
    %{
      id: entry.id,
      revision: 1,
      title: "Biz-kit internal assessment: " <> entry.id,
      idea: "Review existing application guarantees before external app generation.",
      answers: [
        %{
          id: "A-1",
          question: "What important guarantee should domain owners review?",
          answer: entry.requirement
        }
      ],
      requirements: [
        %{id: "R-1", statement: entry.requirement, kind: :invariant, answer_ids: ["A-1"]}
      ],
      obligations: [
        %{
          id: "O-1",
          claim: "Establish: " <> entry.requirement,
          method: entry.method,
          requirement_ids: ["R-1"]
        }
      ],
      capabilities: []
    }
  end

  @doc """
  Verify declared app coverage against a checked-out Biz-kit umbrella.
  A new/removed app fails closed until its baseline is reviewed and updated.
  Does not assert any mathematical or runtime property.
  """
  @spec audit_repo(Path.t()) :: {:ok, map()} | {:error, term()}
  def audit_repo(root) when is_binary(root) do
    apps_dir = Path.join(root, "apps")

    if File.dir?(apps_dir) do
      actual =
        apps_dir
        |> Path.join("*/mix.exs")
        |> Path.wildcard()
        |> Enum.map(&Path.basename(Path.dirname(&1)))
        |> Enum.sort()

      expected =
        @applications
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      added = actual -- expected
      removed = expected -- actual

      if added == [] and removed == [] do
        {:ok,
         %{
           catalog: @catalog_version,
           app_count: length(actual),
           platform_count: 1,
           owner_review_pending: length(actual) + 1,
           verified: 0,
           activated: 0
         }}
      else
        {:error, {:inventory_drift, %{unregistered_apps: added, missing_apps: removed}}}
      end
    else
      {:error, :missing_umbrella_apps_directory}
    end
  end

  def audit_repo(_root), do: {:error, :invalid_repo_root}
end
