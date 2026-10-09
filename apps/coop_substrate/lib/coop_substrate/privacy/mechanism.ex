defmodule CoopSubstrate.Privacy.Mechanism do
  @moduledoc """
  Phase 6A (docs/phase6a_plan.md acceptance 1/3): the privacy mechanism
  ladder (corpus 08 §6) as DATA. A descriptor names the rung a backing
  stands on, the execution boundary it runs in, and the workload shape
  that justifies it — so apps and agents can inspect what they are
  trusting, and unsupported combinations are unrepresentable rather than
  discovered in production.

  Long-running or unbounded crypto (proof generation, MPC/FHE evaluation,
  unbounded-input work) may only be declared `:sidecar` (hand-off §4/§4a);
  bounded verification stays BEAM/NIF-eligible up the ladder. No mechanism
  is implemented here — premature crypto is a defect (08 §9).
  """

  @rungs [:plain, :k_anonymity, :additive_he, :zk, :mpc, :fhe, :nullifier]
  @boundaries [:beam, :bounded_nif, :dirty_nif, :sidecar]

  @workloads [
    :bounded_computation,
    :bounded_verification,
    :proof_generation,
    :joint_evaluation,
    :unbounded_input_crypto
  ]

  @sidecar_only_workloads [:proof_generation, :joint_evaluation, :unbounded_input_crypto]

  # Rung → execution boundaries it may run in. Joint evaluation (MPC/FHE)
  # never runs inside the BEAM's blast radius; verification-shaped rungs do.
  @allowed_boundaries %{
    plain: [:beam],
    k_anonymity: [:beam],
    additive_he: [:beam, :bounded_nif, :dirty_nif],
    zk: [:beam, :bounded_nif, :dirty_nif, :sidecar],
    mpc: [:sidecar],
    fhe: [:sidecar],
    nullifier: [:beam, :bounded_nif]
  }

  @type rung :: :plain | :k_anonymity | :additive_he | :zk | :mpc | :fhe | :nullifier
  @type boundary :: :beam | :bounded_nif | :dirty_nif | :sidecar
  @type workload ::
          :bounded_computation
          | :bounded_verification
          | :proof_generation
          | :joint_evaluation
          | :unbounded_input_crypto
  @type descriptor :: %{rung: rung(), boundary: boundary(), workload: workload()}

  @spec rungs() :: [rung()]
  def rungs, do: @rungs

  @spec boundaries() :: [boundary()]
  def boundaries, do: @boundaries

  @spec allowed_boundaries(rung()) :: [boundary()]
  def allowed_boundaries(rung) when rung in @rungs, do: Map.fetch!(@allowed_boundaries, rung)

  @spec validate(term()) :: :ok | {:error, term()}
  def validate(%{rung: rung, boundary: boundary, workload: workload}) do
    cond do
      rung not in @rungs ->
        {:error, {:unknown_rung, rung}}

      boundary not in @boundaries ->
        {:error, {:unknown_boundary, boundary}}

      workload not in @workloads ->
        {:error, {:unknown_workload, workload}}

      boundary not in Map.fetch!(@allowed_boundaries, rung) ->
        {:error, {:boundary_not_allowed, rung, boundary}}

      workload in @sidecar_only_workloads and boundary != :sidecar ->
        {:error, {:sidecar_required, workload}}

      true ->
        :ok
    end
  end

  def validate(other), do: {:error, {:not_a_descriptor, other}}

  @doc "Fetch and validate a backing module's declared descriptor."
  @spec describe(module()) :: {:ok, descriptor()} | {:error, term()}
  def describe(backing) when is_atom(backing) do
    if Code.ensure_loaded?(backing) and function_exported?(backing, :descriptor, 0) do
      descriptor = backing.descriptor()

      case validate(descriptor) do
        :ok -> {:ok, descriptor}
        error -> error
      end
    else
      {:error, {:descriptor_undeclared, backing}}
    end
  end
end
