defmodule Keel.ReleaseReviewTest do
  use ExUnit.Case, async: true

  alias Keel.{Body, Org, Party, ReleaseReview, Role, Seat, Unit}

  @date ~D[2026-11-12]
  @body "release-committee"

  defp organization(grants) do
    Org.new([
      %Party{id: :biz_kit, kind: :entity},
      %Party{id: :reviewer, kind: :person},
      %Unit{id: :engineering, of: :biz_kit},
      %Role{id: :review, unit: :engineering},
      %Seat{party: :reviewer, role: :review},
      %Body{id: @body, of: :biz_kit, members: {:seats, [:review]}, grants: grants}
    ])
  end

  defp request_binding do
    %{
      "request_id" => "3c404f19-b31f-4709-a203-262d551ac925",
      "action" => "deploy",
      "target" => "biz-kit-test",
      "inventory" => String.duplicate("a", 64),
      "generation" => 3,
      "release" => "fixture-v1",
      "release_sha256" => String.duplicate("b", 64),
      "graft_evidence" => String.duplicate("c", 64)
    }
  end

  test "signed result binds the exact request, release, and Graft evidence" do
    {public, seed} = :crypto.generate_key(:eddsa, :ed25519)
    org = organization([:deploy_release])

    assert {:ok, %{"verdict" => "carried"} = record} =
             ReleaseReview.issue(org, @body, %{reviewer: :yes}, @date, request_binding(), "review-key", seed)

    signature = Base.decode16!(record["signature"], case: :lower)
    assert :crypto.verify(:eddsa, :none, ReleaseReview.signing_bytes(record), signature, [
             public,
             :ed25519
           ])

    for field <- Map.keys(request_binding()) ++ ~w(verdict policy_sha256 ballots_sha256) do
      changed = Map.put(record, field, "substituted")

      refute :crypto.verify(:eddsa, :none, ReleaseReview.signing_bytes(changed), signature, [
               public,
               :ed25519
             ])
    end
  end

  test "OpenSSL verifies the producer output using the Ship wire format" do
    {public, seed} = :crypto.generate_key(:eddsa, :ed25519)
    binding = request_binding()

    assert {:ok, record} =
             ReleaseReview.issue(
               organization([:deploy_release]),
               @body,
               %{reviewer: :yes},
               @date,
               binding,
               "review-key",
               seed
             )

    # Build the verifier's preimage independently from the producer encoder.
    fields =
      ~w(schema repository key_id body verdict decision_date policy_sha256 ballots_sha256) ++
        ~w(request_id action target inventory generation release release_sha256 graft_evidence)

    message = Enum.map_join(fields, "", &(to_string(Map.fetch!(record, &1)) <> "\n"))
    directory = Path.join(System.tmp_dir!(), Base.url_encode64(:crypto.strong_rand_bytes(16)))
    File.mkdir!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    key_path = Path.join(directory, "issuer.der")
    signature_path = Path.join(directory, "signature")
    message_path = Path.join(directory, "message")
    File.write!(key_path, Base.decode16!("302A300506032B6570032100") <> public)
    File.write!(signature_path, Base.decode16!(record["signature"], case: :lower))
    File.write!(message_path, message)

    arguments = [
      "pkeyutl", "-verify", "-pubin", "-keyform", "DER", "-inkey", key_path,
      "-rawin", "-in", message_path, "-sigfile", signature_path
    ]

    assert {_, 0} = System.cmd("openssl", arguments, stderr_to_stdout: true)
    File.write!(message_path, String.replace(message, "fixture-v1", "fixture-v2"))
    assert {_, status} = System.cmd("openssl", arguments, stderr_to_stdout: true)
    assert status != 0
  end

  test "Keel computes the outcome and rejects malformed bindings or ballots" do
    {_, seed} = :crypto.generate_key(:eddsa, :ed25519)
    org = organization([:deploy_release])

    assert {:ok, %{"verdict" => "failed"}} =
             ReleaseReview.issue(org, @body, %{reviewer: :no}, @date, request_binding(), "review-key", seed)

    assert {:ok, %{"verdict" => "ultra_vires"}} =
             ReleaseReview.issue(
               org,
               @body,
               %{reviewer: :yes},
               @date,
               Map.put(request_binding(), "action", "rollback"),
               "review-key",
               seed
             )

    for binding <- [Map.put(request_binding(), "verdict", "carried"), Map.delete(request_binding(), "action"),
                    Map.put(request_binding(), "target", "other\ntarget")] do
      assert {:error, :invalid_release_review_input} =
               ReleaseReview.issue(org, @body, %{reviewer: :yes}, @date, binding, "review-key", seed)
    end

    assert {:error, :invalid_release_review_input} =
             ReleaseReview.issue(org, @body, %{unknown: :yes}, @date, request_binding(), "review-key", seed)
  end
end
