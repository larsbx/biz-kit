defmodule ProofBankCore.DispatchPilot do
  @moduledoc """
  First internal Proof Bank evidence pilot for the Dispatch transition model.

  The checked-in Lean theorems apply to an *abstract* transition relation.
  Real PostgreSQL integration tests exercise selected analogous behaviors.
  The two must be executed at the same exact source revision and reviewed
  before any conformance claim. This module only prepares a draft, traceable
  work packet and checks that the known source anchors have not disappeared.

  Neither existence of these anchors nor a passing model proof constitutes
  a refinement proof for the Elixir/Ash/PostgreSQL implementation.
  """

  @source "apps/dispatch/lib/dispatch/operations/board.ex"
  @model "formal/lean/BizKitDispatch.lean"

  @checks [
    %{
      id: "D-ORG",
      statement: "A transition of a trip belonging to another organization is refused.",
      theorem: "foreign_organization_refused",
      runtime_test: "apps/dispatch/test/dispatch/operations/board_test.exs",
      test_marker: "a foreign organization's trip cannot be transitioned"
    },
    %{
      id: "D-STALE",
      statement: "A stale expected trip version is refused without changing current state.",
      theorem: "stale_version_refused",
      runtime_test: "apps/dispatch/test/dispatch/operations/board_test.exs",
      test_marker: "a transition increments the version and rejects a stale retry"
    },
    %{
      id: "D-TERMINAL",
      statement: "Terminal trip states refuse further status transitions.",
      theorem: "terminal_states_refused",
      runtime_test: "apps/dispatch/test/dispatch/operations/board_concurrency_test.exs",
      test_marker: "a queued transition rechecks the committed state"
    },
    %{
      id: "D-AUDIT",
      statement: "An admitted transition appends one abstract audit event and increments its version.",
      theorem: "commit_appends_exactly_one_audit",
      runtime_test: "apps/dispatch/test/dispatch/operations/board_test.exs",
      test_marker: "a load is created, stopped, planned and run end to end"
    }
  ]

  @negative_models [
    "formal/quint/dispatch_terminal_bug.qnt",
    "formal/quint/dispatch_idempotency_bug.qnt"
  ]

  @spec checks() :: [map()]
  def checks, do: @checks

  @spec negative_models() :: [String.t()]
  def negative_models, do: @negative_models

  @spec candidate() :: map()
  def candidate do
    answers =
      Enum.map(@checks, fn item ->
        %{
          id: "A-" <> item.id,
          question: "Which transition property needs independent review?",
          answer: item.statement
        }
      end)

    requirements =
      Enum.map(@checks, fn item ->
        %{
          id: "R-" <> item.id,
          statement: item.statement,
          kind: :invariant,
          answer_ids: ["A-" <> item.id]
        }
      end)

    obligations =
      Enum.map(@checks, fn item ->
        %{
          id: "O-" <> item.id,
          claim: "Check abstract Lean theorem: BizKitDispatch." <> item.theorem,
          method: :lean,
          requirement_ids: ["R-" <> item.id]
        }
      end)

    %{
      id: "dispatch-transition-pilot",
      revision: 1,
      title: "Dispatch transitions: abstract model and runtime correspondence",
      idea: "Establish a source-pinned, independently reviewed transition safety packet.",
      answers: answers,
      requirements: requirements,
      obligations: obligations,
      capabilities: []
    }
  end

  @doc """
  Compiles a candidate blueprint with explicit *unverified* evidence gaps.
  The runtime test names are traceability links, not successful test results.
  """
  @spec compile() :: {:ok, map()} | {:error, term()}
  def compile do
    with {:ok, blueprint} <- ProofBankCore.compile(candidate()) do
      {:ok,
       %{
         blueprint: blueprint,
         sources: %{
           implementation: @source,
           abstract_model: @model,
           negative_models: @negative_models
         },
         links:
           Enum.map(@checks, fn item ->
             %{
               obligation_id: "O-" <> item.id,
               lean_theorem: "BizKitDispatch." <> item.theorem,
               runtime_test: item.runtime_test,
               test_marker: item.test_marker,
               claim_status: :unverified,
               implementation_refinement: :not_established
             }
           end),
         review_state: :needs_owner_review,
         runtime_test_status: :not_run,
         formal_check_status: :not_run,
         extension_activation: :inert
       }}
    end
  end

  @doc """
  Confirm that exact named model/test anchors remain in this checkout.

  Textual existence is **not** correctness or test execution. Fail closed
  on renamed or missing anchors so a review must update the binding.
  """
  @spec audit_sources(Path.t()) :: :ok | {:error, term()}
  def audit_sources(root) when is_binary(root) do
    pairs =
      [{@source, "def transition("}, {@source, "lock_trip!("}, {@model, "namespace BizKitDispatch"}] ++
        Enum.flat_map(@checks, fn item ->
          [
            {@model, "theorem " <> item.theorem},
            {item.runtime_test, item.test_marker}
          ]
        end) ++
        Enum.map(@negative_models, &{&1, "module"})

    Enum.reduce_while(pairs, :ok, fn {path, token}, :ok ->
      absolute = Path.join(root, path)

      case File.read(absolute) do
        {:ok, content} ->
          # Negative models are Quint specifications with a module declaration.
          if String.contains?(content, token) do
            {:cont, :ok}
          else
            {:halt, {:error, {:missing_source_anchor, path, token}}}
          end

        {:error, _} ->
          {:halt, {:error, {:unreadable_source, path}}}
      end
    end)
  end

  def audit_sources(_), do: {:error, :invalid_repo_root}
end
