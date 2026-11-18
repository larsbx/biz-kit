defmodule CoopSubstrate.AgentBackendRequestTest do
  @moduledoc """
  Pure protocol checks using constructed, unsigned fixtures.

  These tests establish structural binding, not signed admission provenance,
  receiver durability, backend execution or termination.
  """
  use ExUnit.Case, async: true

  alias AgentCore.Attempts
  alias CoopSubstrate.{AgentBackendRequest, AgentLaunchAdmission, Canonical}

  @store "agent-backend-store:0123456789abcdef0123456789abcdef"
  @other_store "agent-backend-store:fedcba9876543210fedcba9876543210"
  @backend "agent-backend:0123456789abcdef0123456789abcdef"
  @effect "agent-run:intent-1"
  @deadline ~U[2030-01-01 00:00:30.123456Z]
  @binding_keys ~w(backend_id admission_id plan_digest execution_deadline)

  setup do
    manifest = %{
      "id" => "profile-1",
      "version" => 1,
      "adapter_module" => Atom.to_string(__MODULE__),
      "parameters" => %{
        "host_private_value" => "must-not-leave-host",
        "capabilities" => %{"features" => ["text", "tool_calls"]}
      }
    }

    plan = %{
      effect_id: @effect,
      intent_event_id: "intent-1",
      run_id: "run-1",
      chapter_id: "chapter-1",
      tenant_id: "tenant-1",
      project_id: "project-1",
      execution_profile_id: "profile-1",
      execution_profile_digest: {:bytes, Canonical.hash!(manifest)},
      adapter: __MODULE__,
      profile: %{id: "profile-1", approved: true, adapter: __MODULE__, manifest: manifest},
      execution: %{
        run_id: "run-1",
        ticket: %{
          "chapter_id" => "chapter-1",
          "tenant_id" => "tenant-1",
          "project_id" => "project-1",
          "task_id" => "task-1",
          "task_version" => 7,
          "source_event_id" => "task-source-1",
          "definition_digest" => String.duplicate("a", 64)
        }
      },
      requirements: %{
        "features" => ["text"],
        "data_classes" => ["internal"],
        "region" => "local",
        "max_duration_ms" => 30_000,
        "max_output_bytes" => 4096
      }
    }

    assert {:ok, descriptor} = Attempts.descriptor_digest(plan)
    assert {:ok, digest} = AgentLaunchAdmission.plan_digest(plan)

    admission = %{
      admission_id: admission_id(@effect),
      effect_id: @effect,
      epoch: 1,
      claim_version: 2,
      version: 3,
      source_seq: 12,
      source_hash: :crypto.hash(:sha256, "constructed source"),
      descriptor_digest: descriptor,
      plan_digest: digest,
      admitted_at: ~U[2030-01-01 00:00:00.123456Z],
      execution_deadline: @deadline,
      disposition: :admitted
    }

    assert {:ok, request} = AgentBackendRequest.create(plan, admission, @store)
    %{plan: plan, admission: admission, request: request}
  end

  test "create is a closed JSON request bound to the exact plan without its private contents",
       c do
    assert c.request == %{
             "schema" => "bizkit.agent-backend-request.v1",
             "operation" => "create",
             "store_id" => @store,
             "effect_id" => @effect,
             "admission_id" => admission_id(@effect),
             "plan_digest" => Base.encode16(c.admission.plan_digest, case: :lower),
             "execution_deadline" => "2030-01-01T00:00:30.123456Z"
           }

    json = Jason.encode!(c.request)
    assert Jason.decode!(json) == c.request
    refute json =~ "must-not-leave-host"
    refute json =~ "source_hash"
    refute json =~ "descriptor_digest"
    refute json =~ "token"
  end

  test "the same original admitted or existing receipt builds the same request", c do
    assert {:ok, c.request} ==
             AgentBackendRequest.create(c.plan, %{c.admission | disposition: :existing}, @store)

    zero_precision = %{c.admission | execution_deadline: ~U[2030-01-01 00:00:30Z]}
    assert {:ok, request} = AgentBackendRequest.create(c.plan, zero_precision, @store)
    assert request["execution_deadline"] == "2030-01-01T00:00:30.000000Z"
  end

  test "fence and lookup are exact requests to a pinned store and bounded effect" do
    for {operation, builder} <- [
          {"fence", &AgentBackendRequest.fence/2},
          {"lookup", &AgentBackendRequest.lookup/2}
        ] do
      assert {:ok,
              %{
                "schema" => "bizkit.agent-backend-request.v1",
                "operation" => ^operation,
                "store_id" => @store,
                "effect_id" => @effect
              } = request} = builder.(@effect, @store)

      assert map_size(request) == 4
      assert {:ok, _} = builder.("agent-run:" <> String.duplicate("a", 128), @store)

      for effect <- [
            nil,
            1,
            "agent-run:",
            "agent-run:../escape",
            "agent-run:-prefix",
            "agent-run:a\n",
            "agent-run:é",
            "agent-run:" <> String.duplicate("a", 129)
          ] do
        assert {:error, :invalid_agent_backend_request} = builder.(effect, @store)
      end
    end
  end

  test "every builder refuses unpinned, noncanonical or overlong store identifiers", c do
    for store <- [
          nil,
          false,
          "",
          @backend,
          String.upcase(@store),
          @store <> "0",
          @store <> "\n",
          "agent-backend-store:" <> String.duplicate("g", 32)
        ] do
      assert {:error, :invalid_agent_backend_request} =
               AgentBackendRequest.create(c.plan, c.admission, store)

      assert {:error, :invalid_agent_backend_request} = AgentBackendRequest.fence(@effect, store)
      assert {:error, :invalid_agent_backend_request} = AgentBackendRequest.lookup(@effect, store)
    end
  end

  test "admission fields are closed and use the exact Log receipt types", c do
    for field <- Map.keys(c.admission) do
      assert {:error, :invalid_agent_backend_admission} =
               AgentBackendRequest.create(c.plan, Map.delete(c.admission, field), @store)
    end

    for admission <- [
          nil,
          %{},
          Map.put(c.admission, :token, <<0::256>>),
          Map.put(c.admission, "source_seq", 12),
          %{c.admission | disposition: "admitted"},
          %{c.admission | disposition: :accepted}
        ] do
      assert {:error, :invalid_agent_backend_admission} =
               AgentBackendRequest.create(c.plan, admission, @store)
    end
  end

  test "source and claim counters must fit positive SQL bigints with the exact next version", c do
    for field <- [:source_seq, :epoch, :claim_version, :version],
        value <- [0, -1, true, 1.0, "1", 9_223_372_036_854_775_808] do
      assert {:error, :invalid_agent_backend_admission} =
               AgentBackendRequest.create(c.plan, Map.put(c.admission, field, value), @store)
    end

    for version <- [1, 2, 4] do
      assert {:error, :invalid_agent_backend_admission} =
               AgentBackendRequest.create(c.plan, %{c.admission | version: version}, @store)
    end
  end

  test "source and both digests must be raw SHA-256 values", c do
    for field <- [:source_hash, :descriptor_digest, :plan_digest],
        value <- [nil, <<0::248>>, <<0::264>>, {:bytes, <<0::256>>}, String.duplicate("a", 64)] do
      assert {:error, :invalid_agent_backend_admission} =
               AgentBackendRequest.create(c.plan, Map.put(c.admission, field, value), @store)
    end
  end

  test "the receipt identity is derived from its effect and that effect must bind the plan", c do
    assert {:error, :invalid_agent_backend_admission} =
             AgentBackendRequest.create(
               c.plan,
               %{c.admission | admission_id: admission_id("agent-run:other")},
               @store
             )

    other = %{
      c.admission
      | effect_id: "agent-run:other",
        admission_id: admission_id("agent-run:other")
    }

    assert {:error, :agent_backend_admission_mismatch} =
             AgentBackendRequest.create(c.plan, other, @store)
  end

  test "full plan binding catches requirements changes omitted by the older descriptor", c do
    changed = put_in(c.plan, [:requirements, "features"], ["text", "tool_calls"])
    assert Attempts.descriptor_digest(changed) == Attempts.descriptor_digest(c.plan)
    refute AgentLaunchAdmission.plan_digest(changed) == AgentLaunchAdmission.plan_digest(c.plan)

    assert {:error, :agent_backend_admission_mismatch} =
             AgentBackendRequest.create(changed, c.admission, @store)

    for field <- [:descriptor_digest, :plan_digest] do
      assert {:error, :agent_backend_admission_mismatch} =
               AgentBackendRequest.create(c.plan, Map.put(c.admission, field, <<0::256>>), @store)
    end
  end

  test "malformed or extended plans cannot bypass either recomputation", c do
    for plan <- [
          nil,
          %{},
          Map.put(c.plan, :callback, fn -> :ok end),
          put_in(c.plan, [:profile, :approved], false),
          put_in(c.plan, [:execution, :ticket, "task_version"], false),
          put_in(c.plan, [:requirements, "unknown"], 1.5)
        ] do
      assert {:error, :invalid_agent_backend_request} =
               AgentBackendRequest.create(plan, c.admission, @store)
    end
  end

  test "receipt times must be genuine UTC DateTimes with admission before the deadline", c do
    for time <- [
          nil,
          "2030-01-01T00:00:30Z",
          ~N[2030-01-01 00:00:30],
          %{@deadline | utc_offset: 3600},
          %{@deadline | time_zone: "Elsewhere"},
          %{@deadline | day: 32},
          %{@deadline | year: 0},
          Map.put(@deadline, :untrusted, true)
        ] do
      for field <- [:admitted_at, :execution_deadline] do
        assert {:error, :invalid_agent_backend_admission} =
                 AgentBackendRequest.create(c.plan, Map.put(c.admission, field, time), @store)
      end
    end

    for deadline <- [c.admission.admitted_at, DateTime.add(c.admission.admitted_at, -1)] do
      assert {:error, :invalid_agent_backend_admission} =
               AgentBackendRequest.create(
                 c.plan,
                 %{c.admission | execution_deadline: deadline},
                 @store
               )
    end
  end

  test "construction does not pretend to check current-time expiry or fresh signed authority",
       c do
    old = %{
      c.admission
      | admitted_at: ~U[2000-01-01 00:00:00Z],
        execution_deadline: ~U[2000-01-01 00:00:30Z]
    }

    assert {:ok, request} = AgentBackendRequest.create(c.plan, old, @store)
    assert request["execution_deadline"] == "2000-01-01T00:00:30.000000Z"
  end

  test "create responses bind every request field including exact deadline spelling", c do
    for disposition <- ["created", "existing"] do
      receipt = accepted(c.request) |> Map.put("disposition", disposition)
      assert {:ok, ^receipt} = AgentBackendRequest.verify_response(c.request, receipt)

      normalized = Map.put(receipt, "execution_deadline", "2030-01-01T00:00:30.123456+00:00")

      assert {:error, :invalid_agent_backend_response} =
               AgentBackendRequest.verify_response(c.request, normalized)
    end

    for {field, value} <- [
          {"operation", "lookup"},
          {"store_id", @other_store},
          {"effect_id", "agent-run:other"},
          {"admission_id", admission_id("agent-run:other")},
          {"plan_digest", String.duplicate("0", 64)},
          {"execution_deadline", "2030-01-01T00:00:30.123457Z"}
        ] do
      assert {:error, :invalid_agent_backend_response} =
               AgentBackendRequest.verify_response(
                 c.request,
                 Map.put(accepted(c.request), field, value)
               )
    end
  end

  test "accepted responses cannot claim execution or termination or add opaque fields", c do
    for {field, value} <- [
          {"execution_started", true},
          {"execution_started", nil},
          {"termination_verified", true},
          {"future_creates_refused", true},
          {"verified", true},
          {:verified, true},
          {"state", "fenced"},
          {"state", "unknown"},
          {"disposition", "fenced"},
          {"backend_id", nil},
          {"backend_id", String.upcase(@backend)}
        ] do
      assert {:error, :invalid_agent_backend_response} =
               AgentBackendRequest.verify_response(
                 c.request,
                 Map.put(accepted(c.request), field, value)
               )
    end
  end

  test "response shape is closed and required nullable fields cannot be omitted", c do
    receipt = accepted(c.request)

    for key <- Map.keys(receipt) do
      assert {:error, :invalid_agent_backend_response} =
               AgentBackendRequest.verify_response(c.request, Map.delete(receipt, key))
    end

    for response <- [nil, [], "{}", %{}, Map.put(receipt, "schema", "other.v1")] do
      assert {:error, :invalid_agent_backend_response} =
               AgentBackendRequest.verify_response(c.request, response)
    end
  end

  test "wire deadlines reject offsets, excess precision and invalid calendar values", c do
    for deadline <- [
          nil,
          @deadline,
          "2030-01-01T00:00:30",
          "2030-01-01T00:00:30z",
          "2030-01-01T01:00:30.123456+01:00",
          "2030-01-01T00:00:30.1234567Z",
          "2030-02-30T00:00:30Z",
          "0000-01-01T00:00:30Z",
          "2030-01-01T00:00:30.123456Z\n"
        ] do
      assert {:error, :invalid_agent_backend_response} =
               AgentBackendRequest.verify_response(
                 c.request,
                 Map.put(accepted(c.request), "execution_deadline", deadline)
               )
    end
  end

  test "fence receipts permit a new tombstone or retain the complete existing binding", c do
    assert {:ok, request} = AgentBackendRequest.fence(@effect, @store)

    for receipt <- [fenced(c.request), fenced(c.request) |> Map.merge(empty_binding())] do
      assert {:ok, ^receipt} = AgentBackendRequest.verify_response(request, receipt)
      assert receipt["future_creates_refused"]
      refute receipt["termination_verified"]
      refute Map.has_key?(receipt, "verified")
    end

    for field <- @binding_keys do
      partial = Map.put(fenced(c.request), field, nil)

      assert {:error, :invalid_agent_backend_response} =
               AgentBackendRequest.verify_response(request, partial)
    end

    assert {:error, :invalid_agent_backend_response} =
             AgentBackendRequest.verify_response(
               request,
               Map.put(fenced(c.request), "future_creates_refused", false)
             )
  end

  test "lookup preserves accepted, fenced and unknown distinctions without proving absence", c do
    assert {:ok, request} = AgentBackendRequest.lookup(@effect, @store)

    found =
      accepted(c.request) |> Map.merge(%{"operation" => "lookup", "disposition" => "existing"})

    tombstone = fenced(c.request) |> Map.put("operation", "lookup")

    unknown =
      found
      |> Map.merge(empty_binding())
      |> Map.merge(%{"state" => "unknown", "disposition" => "unknown"})

    for receipt <- [found, tombstone, unknown] do
      assert {:ok, ^receipt} = AgentBackendRequest.verify_response(request, receipt)
      refute receipt["execution_started"]
      refute receipt["termination_verified"]
      refute Map.has_key?(receipt, "verified")
    end

    for response <- [
          Map.put(found, "disposition", "created"),
          Map.put(unknown, "state", "absent"),
          Map.put(unknown, "future_creates_refused", true),
          Map.put(unknown, "backend_id", @backend)
        ] do
      assert {:error, :invalid_agent_backend_response} =
               AgentBackendRequest.verify_response(request, response)
    end
  end

  test "provider errors use a finite mapping and require the exact pinned store", c do
    errors = [
      {"effect_fenced", :agent_backend_effect_fenced},
      {"binding_conflict", :agent_backend_binding_conflict},
      {"deadline_expired", :agent_backend_deadline_expired},
      {"invalid_request", :agent_backend_invalid_request},
      {"invalid_arguments", :agent_backend_invalid_arguments},
      {"invalid_store", :agent_backend_invalid_store},
      {"store_missing", :agent_backend_store_missing},
      {"store_exists", :agent_backend_store_exists},
      {"store_identity_mismatch", :agent_backend_store_identity_mismatch},
      {"database_busy", :agent_backend_database_busy},
      {"database_unavailable", :agent_backend_database_unavailable}
    ]

    for {code, atom} <- errors do
      error = %{
        "schema" => "bizkit.agent-backend-error.v1",
        "error" => code,
        "store_id" => @store
      }

      assert {:error, ^atom} = AgentBackendRequest.verify_response(c.request, error)

      for wrong <- [
            Map.delete(error, "store_id"),
            Map.put(error, "store_id", nil),
            Map.put(error, "store_id", @other_store),
            Map.put(error, "retry", true)
          ] do
        assert {:error, :invalid_agent_backend_response} =
                 AgentBackendRequest.verify_response(c.request, wrong)
      end
    end

    unrecognized = "unrecognized_backend_error_#{System.unique_integer([:positive])}"

    error = %{
      "schema" => "bizkit.agent-backend-error.v1",
      "error" => unrecognized,
      "store_id" => @store
    }

    assert {:error, :invalid_agent_backend_response} =
             AgentBackendRequest.verify_response(c.request, error)

    assert_raise ArgumentError, fn -> String.to_existing_atom(unrecognized) end
  end

  test "response validation refuses altered or nonclosed requests before interpreting a reply",
       c do
    for request <- [
          nil,
          %{},
          Map.put(c.request, "schema", "other.v1"),
          Map.put(c.request, "operation", "execute"),
          Map.put(c.request, "callback", "opaque"),
          Map.put(c.request, "admission_id", admission_id("agent-run:other")),
          Map.put(c.request, "plan_digest", String.duplicate("A", 64)),
          Map.put(c.request, "execution_deadline", "not-a-time")
        ] do
      assert {:error, :invalid_agent_backend_request} =
               AgentBackendRequest.verify_response(request, accepted(c.request))
    end
  end

  defp admission_id(effect),
    do: "agent-admission:" <> Base.encode16(:crypto.hash(:sha256, effect), case: :lower)

  defp accepted(request) do
    request
    |> Map.put("schema", "bizkit.agent-backend-receipt.v1")
    |> Map.merge(%{
      "state" => "accepted",
      "backend_id" => @backend,
      "disposition" => "created",
      "execution_started" => false,
      "termination_verified" => false,
      "future_creates_refused" => false
    })
  end

  defp fenced(request) do
    accepted(request)
    |> Map.merge(%{
      "operation" => "fence",
      "state" => "fenced",
      "disposition" => "fenced",
      "future_creates_refused" => true
    })
  end

  defp empty_binding, do: Map.new(@binding_keys, &{&1, nil})
end
