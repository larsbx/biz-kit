defmodule ProofBankCore.DispatchPilot do
  @moduledoc """
  First-party Dispatch proof-to-implementation **review packet**.

  The abstract Lean transition theorems and live PostgreSQL regression
  witnesses are separate forms of evidence. Neither source anchors nor
  passing tests establish a universal refinement proof. D-GRANT has no
  Lean theorem: it is specifically a concurrency conformance obligation.

  This module has no runtime hooks, no business writer, and no proof-status
  promotion API. It only compiles candidate requirements and audits links.
  """

  @implementation "apps/dispatch/lib/dispatch/operations/board.ex"
  @authority "apps/dispatch/lib/dispatch/identity/principal_resolution.ex"
  @model "formal/lean/BizKitDispatch.lean"
  @board_test "apps/dispatch/test/dispatch/operations/board_test.exs"
  @concurrency_test "apps/dispatch/test/dispatch/operations/board_concurrency_test.exs"
  @grant_test "apps/dispatch/test/dispatch/operations/board_authority_concurrency_test.exs"
  @negative_controls [
    "formal/quint/dispatch_terminal_bug.qnt",
    "formal/quint/dispatch_idempotency_bug.qnt"
  ]

  @claims [
    %{
      id: "D-ORG",
      statement: "A trip transition for a different carrier organization is refused.",
      method: :lean,
      theorem: "foreign_organization_refused",
      test: @board_test,
      witness: "a foreign organization's trip cannot be transitioned"
    },
    %{
      id: "D-STALE",
      statement: "A stale expected trip version is refused without changing the trip.",
      method: :lean,
      theorem: "stale_version_refused",
      test: @board_test,
      witness: "a transition increments the version and rejects a stale retry"
    },
    %{
      id: "D-TERMINAL",
      statement: "Completed and cancelled trips refuse further status transitions.",
      method: :lean,
      theorem: "terminal_states_refused",
      test: @board_test,
      witness: "follows the transition table"
    },
    %{
      id: "D-AUDIT",
      statement: "A successful abstract transition increments its version and appends an audit entry.",
      method: :lean,
      theorem: "commit_appends_exactly_one_audit",
      test: @board_test,
      witness: "a load is created, stopped, planned and run end to end"
    },
    %{
      id: "D-GRANT",
      statement:
        "A role grant revoked while a trip update waits on its lock must prohibit the update and audit.",
      method: :conformance,
      theorem: nil,
      test: @grant_test,
      witness: "revoking the selected assignment denies it"
    }
  ]

  @spec claims() :: [map()]
  def claims, do: @claims

  @spec negative_controls() :: [String.t()]
  def negative_controls, do: @negative_controls

  @spec candidate() :: map()
  def candidate do
    %{
      id: "dispatch-transition-current-grant",
      revision: 1,
      title: "Dispatch: guarded transitions and current authority",
      idea: "Jointly inspect abstract transition safety and runtime admission behavior.",
      answers:
        Enum.map(@claims, fn claim ->
          %{
            id: "A-" <> claim.id,
            question: "Which Dispatch behavior requires owner review?",
            answer: claim.statement
          }
        end),
      requirements:
        Enum.map(@claims, fn claim ->
          %{
            id: "R-" <> claim.id,
            statement: claim.statement,
            kind: :invariant,
            answer_ids: ["A-" <> claim.id]
          }
        end),
      obligations:
        Enum.map(@claims, fn claim ->
          %{
            id: "O-" <> claim.id,
            claim:
              if(claim.theorem,
                do: "Check abstract Lean theorem BizKitDispatch." <> claim.theorem,
                else: "Reproduce and test current-grant concurrency at the real DB boundary"
              ),
            method: claim.method,
            requirement_ids: ["R-" <> claim.id]
          }
        end),
      capabilities: []
    }
  end

  @doc """
  A deterministic review packet. All obligations remain unverified and
  extension activation is inert, even if source files exist.
  """
  @spec compile() :: {:ok, map()} | {:error, term()}
  def compile do
    with {:ok, blueprint} <- ProofBankCore.compile(candidate()) do
      {:ok,
       %{
         blueprint: blueprint,
         sources: %{
           implementation: @implementation,
           authority: @authority,
           abstract_model: @model,
           negative_controls: @negative_controls
         },
         correspondence:
           Enum.map(@claims, fn claim ->
             %{
               obligation_id: "O-" <> claim.id,
               method: claim.method,
               lean_theorem: if(claim.theorem, do: "BizKitDispatch." <> claim.theorem),
               runtime_test: claim.test,
               witness: claim.witness,
               formal_check: :not_executed,
               runtime_check: :not_executed,
               implementation_refinement: :not_established
             }
           end),
         review_state: :needs_owner_review,
         activation_state: :inert
       }}
    end
  end

  @doc """
  Fail closed when named source/model/test anchors disappear from a checkout.

  This is intentionally *textual* drift detection, not source semantics,
  proof checking, proof promotion, or confirmation that the tests ran.
  """
  @spec audit_sources(Path.t()) :: :ok | {:error, term()}
  def audit_sources(root) when is_binary(root) do
    anchors =
      [
        {@implementation, "def transition("},
        {@implementation, "transaction(actor, \"assignment.update.status\""},
        {@implementation, "lock_trip!("},
        {@authority, "def authorize("},
        {@authority, "lock_authority!("},
        {@concurrency_test, "a queued transition rechecks the committed state"},
        {@grant_test, "an unchanged grant still moves the trip"},
        {@model, "namespace BizKitDispatch"}
      ] ++
        Enum.flat_map(@claims, fn claim ->
          proof_anchor =
            if claim.theorem, do: [{@model, "theorem " <> claim.theorem}], else: []

          proof_anchor ++ [{claim.test, claim.witness}]
        end) ++
        Enum.map(@negative_controls, &{&1, "module "})

    Enum.reduce_while(anchors, :ok, fn {path, token}, :ok ->
      case File.read(Path.join(root, path)) do
        {:ok, content} ->
          if String.contains?(content, token) do
            {:cont, :ok}
          else
            {:halt, {:error, {:missing_anchor, path, token}}}
          end

        {:error, _reason} ->
          {:halt, {:error, {:unreadable_source, path}}}
      end
    end)
  end

  def audit_sources(_root), do: {:error, :invalid_repo_root}
end
