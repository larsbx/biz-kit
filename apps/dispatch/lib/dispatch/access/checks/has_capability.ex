defmodule Dispatch.Access.Checks.HasCapability do
  @moduledoc """
  Passes when the actor's single role assignment carries a capability.

  Section 23.3 requires authorization to be expressed in Ash policies and
  reusable named policy checks rather than controller conditionals, and Section
  23.2 forbids branching on a role key. This check reads capabilities only, so
  a policy written with it cannot accidentally depend on which profile granted
  them.

      policies do
        policy action(:declare) do
          authorize_if Dispatch.Access.Checks.HasCapability.of("status.declare.self")
        end
      end
  """

  use Ash.Policy.SimpleCheck

  alias Dispatch.Access.Actor

  @doc "Builds the check for one capability key."
  @spec of(String.t()) :: {module(), keyword()}
  def of(capability) when is_binary(capability), do: {__MODULE__, capability: capability}

  @impl Ash.Policy.Check
  def describe(opts), do: "actor carries #{inspect(opts[:capability])}"

  @impl Ash.Policy.SimpleCheck
  def match?(%Actor{} = actor, _context, opts) do
    Actor.can?(actor, Keyword.fetch!(opts, :capability))
  end

  # Anything that is not a Dispatch actor carries no capability. Section 21.1
  # requires every externally initiated action to receive an actor, so a nil or
  # foreign actor here is a programming error — and denying is the only safe
  # reading of one.
  def match?(_actor, _context, _opts), do: false
end
