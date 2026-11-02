defmodule Mix.Tasks.Coop.Owner.BackfillTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Coop.Owner.Backfill

  @scope {"chapter-A", "tenant-1", "project-1"}
  @principal "alice"

  defp envelope(type, payload) do
    %{"chapter_id" => "chapter-A", "type" => type, "payload" => payload}
  end

  defp kind do
    envelope("TaskPrincipalKindDeclaredV1", %{
      "principal_id" => @principal,
      "kind" => "human"
    })
  end

  defp assignment do
    envelope("TaskProjectOwnerAssignedV1", %{
      "tenant_id" => "tenant-1",
      "project_id" => "project-1",
      "principal_id" => @principal
    })
  end

  defp grant(device) do
    envelope("TaskOperatorGrantedV1", %{
      "tenant_id" => "tenant-1",
      "project_id" => "project-1",
      "principal_id" => @principal,
      "key_id" => device.key_id,
      "pubkey" => {:bytes, device.pubkey}
    })
  end

  test "signer permits only expected existing-owner backfill sequences" do
    device = %{key_id: "k1", pubkey: :crypto.strong_rand_bytes(32)}

    assert Backfill.matches?([assignment()], @scope, @principal, nil)
    assert Backfill.matches?([kind(), assignment()], @scope, @principal, nil)
    assert Backfill.matches?([grant(device), assignment()], @scope, @principal, device)
    assert Backfill.matches?([kind(), grant(device), assignment()], @scope, @principal, device)
    refute Backfill.matches?([kind(), assignment()], @scope, @principal, device)
    refute Backfill.matches?([grant(device), assignment()], @scope, @principal, nil)
  end

  test "signer refuses cross-chapter, cross-tenant and swapped principals" do
    refute Backfill.matches?(
             [Map.put(assignment(), "chapter_id", "chapter-other")],
             @scope,
             @principal,
             nil
           )

    refute Backfill.matches?(
             [put_in(assignment(), ["payload", "tenant_id"], "tenant-2")],
             @scope,
             @principal,
             nil
           )

    refute Backfill.matches?(
             [put_in(assignment(), ["payload", "principal_id"], "mallory")],
             @scope,
             @principal,
             nil
           )
  end

  test "signer refuses agent declarations, extra commands and wrong key" do
    device = %{key_id: "k1", pubkey: :crypto.strong_rand_bytes(32)}

    refute Backfill.matches?(
             [put_in(kind(), ["payload", "kind"], "agent"), assignment()],
             @scope,
             @principal,
             nil
           )

    refute Backfill.matches?([assignment(), assignment()], @scope, @principal, nil)
    refute Backfill.matches?([assignment(), kind()], @scope, @principal, nil)

    refute Backfill.matches?(
             [put_in(grant(device), ["payload", "key_id"], "bad"), assignment()],
             @scope,
             @principal,
             device
           )
  end
end
