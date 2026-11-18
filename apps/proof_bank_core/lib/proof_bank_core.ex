defmodule ProofBankCore do
  @moduledoc """
  Dependency-free, inert proof-bank contract compiler.

  Compiles *structured, reviewed candidate input* into a deterministic
  specification blueprint. It does not interpret natural language, approve
  requirements, construct Lean proofs, activate extensions, grant access,
  or admit business commands. Only authenticated hosts can make those decisions.

  Returned :unverified and :inert markers MUST NOT be promoted based on
  this compiler succeeding. Artifact custody, canonical wire encoding,
  proof checking and source revisions are host integration obligations.
  """

  alias ProofBankCore.Schema

  @spec compile(term()) :: {:ok, map()} | {:error, term()}
  def compile(candidate) do
    with :ok <-
           Schema.fields(candidate, [
             :id,
             :revision,
             :title,
             :idea,
             :answers,
             :requirements,
             :obligations,
             :capabilities
           ]),
         :ok <- Schema.identifier(Map.get(candidate, :id)),
         :ok <- Schema.positive_revision(Map.get(candidate, :revision)),
         :ok <- Schema.text(:title, Map.get(candidate, :title)),
         :ok <- Schema.text(:idea, Map.get(candidate, :idea)),
         {:ok, answers} <-
           Schema.items(:answers, Map.get(candidate, :answers), &Schema.answer/1),
         {:ok, requirements} <-
           Schema.items(:requirements, Map.get(candidate, :requirements), &Schema.requirement/1),
         {:ok, obligations} <-
           Schema.items(:obligations, Map.get(candidate, :obligations), &Schema.obligation/1),
         {:ok, capabilities} <- Schema.capabilities(Map.get(candidate, :capabilities)),
         :ok <- Schema.references(answers, requirements, obligations) do
      {:ok,
       %{
         schema: "proof-bank.blueprint.v1",
         id: candidate.id,
         revision: candidate.revision,
         title: String.trim(candidate.title),
         idea: String.trim(candidate.idea),
         answers: answers,
         requirements: requirements,
         obligations: obligations,
         capabilities: capabilities,
         verification_state: :unverified,
         activation_state: :inert
       }}
    end
  end
end
