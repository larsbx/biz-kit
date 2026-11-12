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

  defp binding do
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
             ReleaseReview.issue(org, @body, %{reviewer: :yes}, @date, binding(), "review-key", seed)

    signature = Base.decode16!(record["signature"], case: :lower)
    assert :crypto.verify(:eddsa, :none, ReleaseReview.signing_bytes(record), signature, [
             public,
             :ed25519
           ])

    for field <- Map.keys(binding()) ++ ~w(verdict policy_sha256 ballots_sha256) do
      changed = Map.put(record, field, "substituted")

      refute :crypto.verify(:eddsa, :none, ReleaseReview.signing_bytes(changed), signature, [
               public,
               :ed25519
             ])
    end
  end

  test "Keel computes the outcome and rejects malformed bindings or ballots" do
    {_, seed} = :crypto.generate_key(:eddsa, :ed25519)
    org = organization([:deploy_release])

    assert {:ok, %{"verdict" => "failed"}} =
             ReleaseReview.issue(org, @body, %{reviewer: :no}, @date, binding(), "review-key", seed)

    assert {:ok, %{"verdict" => "ultra_vires"}} =
             ReleaseReview.issue(
               org,
               @body,
               %{reviewer: :yes},
               @date,
               Map.put(binding(), "action", "rollback"),
               "review-key",
               seed
             )

    for binding <- [Map.put(binding(), "verdict", "carried"), Map.delete(binding(), "action"),
                    Map.put(binding(), "target", "other\ntarget")] do
      assert {:error, :invalid_release_review_input} =
               ReleaseReview.issue(org, @body, %{reviewer: :yes}, @date, binding, "review-key", seed)
    end

    assert {:error, :invalid_release_review_input} =
             ReleaseReview.issue(org, @body, %{unknown: :yes}, @date, binding(), "review-key", seed)
  end
end
