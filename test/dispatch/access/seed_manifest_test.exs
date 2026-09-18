defmodule Dispatch.Access.SeedManifestTest do
  @moduledoc """
  Section 33.1 requires the seed manifests for `ADMIN`, `DISPATCHER`, `SHIPPER`,
  `RECEIVER`, and `BROKER` to match the normative capability matrix of Section
  23.2 *exactly*. These transcribe that table independently of
  `Dispatch.Access.SeedManifest`, so a transcription error in the source and a
  matching error in the test cannot cancel out.
  """

  use ExUnit.Case, async: true

  alias Dispatch.Access.{Capabilities, SeedManifest}

  # Transcribed from the Section 23.2 table "Included capabilities beyond shared
  # authenticated access". Independent of the implementation on purpose.
  @normative %{
    "DRIVER" => ~w(
      profile.read.self assignment.read.self status.declare.self
      location.share.self proposal.decide.self communications.read.self
    ),
    "ADMIN" => ~w(
      tenant.configure membership.manage role_assignment.manage
      integration.configure retention.manage audit.read
    ),
    "DISPATCHER" => ~w(
      operations.participant.read load.read stop.read load.update.nonbinding
      proposal.create appointment.propose instruction.propose
      communications.read.scoped
    ),
    "SHIPPER" => ~w(
      load.read stop.read stop.update.readiness appointment.propose
      instruction.propose document_reference.read document_reference.add
      communications.read.scoped proposal.create
    ),
    "RECEIVER" => ~w(
      load.read stop.read stop.update.readiness appointment.propose
      instruction.propose document_reference.read document_reference.add
      communications.read.scoped proposal.create
    ),
    "BROKER" => ~w(
      load.read stop.read appointment.propose instruction.propose
      document_reference.read communications.read.scoped proposal.create
    )
  }

  test "the six seeded profiles are exactly those Section 23.2 names" do
    assert Enum.sort(SeedManifest.keys()) ==
             ~w(ADMIN BROKER DISPATCHER DRIVER RECEIVER SHIPPER)
  end

  for {key, expected} <- @normative do
    test "#{key} grants exactly the Section 23.2 capability bundle" do
      {:ok, manifest} = SeedManifest.fetch(unquote(key))

      assert Enum.sort(manifest.capabilities) == Enum.sort(unquote(expected))
    end
  end

  test "every seeded capability is canonical" do
    assert SeedManifest.unknown_capabilities() == []
  end

  describe "what the manifests must NOT grant" do
    test "no seeded profile can execute a consequential action" do
      # Section 23.2: no seeded role may accept a load, alter a rate, change a
      # confirmed appointment, bind another organization, or execute a
      # consequential action because of its profile.
      for manifest <- SeedManifest.all() do
        refute "action.execute.approved" in manifest.capabilities,
               "#{manifest.key} must not carry action.execute.approved"
      end
    end

    test "ADMIN has no operational read" do
      # Section 23.3: an administrative role does not satisfy an operational
      # read check. Acceptance criterion 14 requires a separate scoped role.
      {:ok, admin} = SeedManifest.fetch("ADMIN")

      for forbidden <- ~w(
            operations.participant.read
            operations.location.precise.read
            load.read
            stop.read
            communications.read.scoped
          ) do
        refute forbidden in admin.capabilities, "ADMIN must not carry #{forbidden}"
      end
    end

    test "no seeded profile carries precise location by default" do
      # Section 23.2 makes precise location a separate capability that also
      # requires active consent; Section 23.3 admits a broker only inside the
      # sharing window with a separately granted capability.
      for manifest <- SeedManifest.all() do
        refute "operations.location.precise.read" in manifest.capabilities,
               "#{manifest.key} must not carry operations.location.precise.read"
      end
    end

    test "only DRIVER carries self-service capabilities" do
      for manifest <- SeedManifest.all(), manifest.key != "DRIVER" do
        self_service = Enum.filter(manifest.capabilities, &Capabilities.self_service?/1)

        assert self_service == [],
               "#{manifest.key} must not carry self-service capabilities: #{inspect(self_service)}"
      end
    end

    test "a counterparty profile cannot update a load in a binding way" do
      # load.update.nonbinding is the dispatcher's, and its name is the point:
      # Section 23.2 leaves binding change to the proposal and approval flow.
      for key <- ~w(SHIPPER RECEIVER BROKER) do
        {:ok, manifest} = SeedManifest.fetch(key)
        refute "load.update.nonbinding" in manifest.capabilities
      end
    end
  end

  describe "constraints" do
    test "every constrained capability is one the profile actually grants" do
      for manifest <- SeedManifest.all(),
          {capability, _constraints} <- manifest.constraints do
        assert capability in manifest.capabilities,
               "#{manifest.key} constrains #{capability}, which it does not grant"
      end
    end

    test "every constraint key is one Section 23.2 names" do
      known = Capabilities.constraints() |> Enum.map(&Atom.to_string/1)

      for manifest <- SeedManifest.all(),
          {_capability, constraints} <- manifest.constraints,
          constraint <- constraints do
        assert constraint in known, "#{manifest.key} uses unknown constraint #{constraint}"
      end
    end

    test "the driver's location sharing requires consent" do
      # Section 6.1: location sharing is explicit, visible, and revocable.
      {:ok, driver} = SeedManifest.fetch("DRIVER")

      assert "requires_consent" in driver.constraints["location.share.self"]
    end

    test "the driver's proposal decision requires biometric confirmation" do
      # Section 23.1 gates the approval screen and the signing of a
      # consequential approval behind Android system biometric authentication.
      {:ok, driver} = SeedManifest.fetch("DRIVER")

      assert "requires_biometric" in driver.constraints["proposal.decide.self"]
    end
  end
end
