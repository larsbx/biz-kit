defmodule CoopSubstrate.PrivacyMechanismTest do
  @moduledoc """
  Phase 6A (docs/phase6a_plan.md acceptance 1/3/6): the mechanism ladder as
  pure data — unsupported rung × boundary combinations are unrepresentable,
  long-running/unbounded workloads are sidecar-only, and `describe/1`
  rejects backings that lack or misdeclare their metadata.
  """

  use ExUnit.Case, async: true

  alias CoopSubstrate.Privacy.Mechanism

  defmodule SidecarProver do
    def descriptor, do: %{rung: :zk, boundary: :sidecar, workload: :proof_generation}
  end

  defmodule BeamFhe do
    def descriptor, do: %{rung: :fhe, boundary: :beam, workload: :joint_evaluation}
  end

  defmodule Undeclared do
  end

  test "valid ladder combinations" do
    for descriptor <- [
          %{rung: :plain, boundary: :beam, workload: :bounded_computation},
          %{rung: :k_anonymity, boundary: :beam, workload: :bounded_computation},
          %{rung: :additive_he, boundary: :dirty_nif, workload: :bounded_computation},
          %{rung: :zk, boundary: :bounded_nif, workload: :bounded_verification},
          %{rung: :zk, boundary: :sidecar, workload: :proof_generation},
          %{rung: :mpc, boundary: :sidecar, workload: :joint_evaluation},
          %{rung: :fhe, boundary: :sidecar, workload: :joint_evaluation},
          %{rung: :nullifier, boundary: :beam, workload: :bounded_verification}
        ] do
      assert :ok = Mechanism.validate(descriptor), "expected valid: #{inspect(descriptor)}"
    end
  end

  test "unsupported combinations are unrepresentable" do
    # Joint evaluation never runs inside the BEAM's blast radius.
    assert {:error, {:boundary_not_allowed, :fhe, :beam}} =
             Mechanism.validate(%{rung: :fhe, boundary: :beam, workload: :joint_evaluation})

    assert {:error, {:boundary_not_allowed, :mpc, :dirty_nif}} =
             Mechanism.validate(%{rung: :mpc, boundary: :dirty_nif, workload: :joint_evaluation})

    # Long-running / unbounded workloads are sidecar-only even where the
    # rung itself allows lighter boundaries.
    assert {:error, {:sidecar_required, :proof_generation}} =
             Mechanism.validate(%{rung: :zk, boundary: :bounded_nif, workload: :proof_generation})

    assert {:error, {:sidecar_required, :unbounded_input_crypto}} =
             Mechanism.validate(%{
               rung: :plain,
               boundary: :beam,
               workload: :unbounded_input_crypto
             })

    assert {:error, {:unknown_rung, :homomorphic_vibes}} =
             Mechanism.validate(%{
               rung: :homomorphic_vibes,
               boundary: :beam,
               workload: :bounded_computation
             })

    assert {:error, {:unknown_boundary, :gpu}} =
             Mechanism.validate(%{rung: :zk, boundary: :gpu, workload: :bounded_verification})

    assert {:error, {:unknown_workload, :whatever}} =
             Mechanism.validate(%{rung: :plain, boundary: :beam, workload: :whatever})

    assert {:error, {:not_a_descriptor, :plain}} = Mechanism.validate(:plain)
  end

  test "describe/1 fetches and validates backing metadata" do
    assert {:ok, %{rung: :zk, boundary: :sidecar}} = Mechanism.describe(SidecarProver)
    assert {:error, {:boundary_not_allowed, :fhe, :beam}} = Mechanism.describe(BeamFhe)
    assert {:error, {:descriptor_undeclared, Undeclared}} = Mechanism.describe(Undeclared)
  end

  test "the registry surface is total over its rungs" do
    for rung <- Mechanism.rungs() do
      allowed = Mechanism.allowed_boundaries(rung)
      assert allowed != []
      assert Enum.all?(allowed, &(&1 in Mechanism.boundaries()))
    end
  end
end
