defmodule Mix.Tasks.Coop.Owner.SucceedTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Coop.Owner.Succeed

  @principal "owner"
  @chapter "chapter-1"

  defp details do
    %{
      "principal_id" => @principal,
      "projects" => [
        %{
          "chapter_id" => @chapter,
          "tenant_id" => "tenant-1",
          "project_id" => "project-1",
          "accountable_owner" => @principal,
          "successor_required" => true
        },
        %{
          "chapter_id" => @chapter,
          "tenant_id" => "tenant-1",
          "project_id" => "project-2",
          "accountable_owner" => "someone-else",
          "successor_required" => false
        },
        %{
          "chapter_id" => "other-chapter",
          "tenant_id" => "tenant-4",
          "project_id" => "foreign",
          "accountable_owner" => @principal,
          "successor_required" => true
        }
      ],
      "keys" => [
        %{"chapter_id" => @chapter, "key_id" => "governance-A"},
        %{"chapter_id" => @chapter, "key_id" => "governance-B"},
        %{"chapter_id" => "other-chapter", "key_id" => "foreign-key"}
      ]
    }
  end

  defp successors, do: %{{"tenant-1", "project-1"} => "alice"}

  defp commands do
    [
      {"TaskPrincipalOffboardedV1",
       %{
         "tenant_id" => "tenant-1",
         "project_id" => "project-1",
         "principal_id" => @principal
       }},
      {"TaskPrincipalOffboardedV1",
       %{
         "tenant_id" => "tenant-1",
         "project_id" => "project-2",
         "principal_id" => @principal
       }},
      {"TaskProjectOwnerAssignedV1",
       %{
         "tenant_id" => "tenant-1",
         "project_id" => "project-1",
         "principal_id" => "alice"
       }},
      {"RoleKeyRevoked", %{"role" => "governance", "key_id" => "governance-B"}},
      {"RoleKeyRevoked", %{"role" => "governance", "key_id" => "governance-A"}}
    ]
  end

  defp cores do
    for {type, payload} <- commands() do
      %{"type" => type, "payload" => payload, "chapter_id" => @chapter}
    end
  end

  test "parse repeated successor selections with no collisions" do
    assert Succeed.parse_successors(["tenant-1/project-1=alice", "tenant-2/project-2=bob"]) ==
             {:ok, %{{"tenant-1", "project-1"} => "alice", {"tenant-2", "project-2"} => "bob"}}

    for selections <- [
          ["tenant-1/project-1=alice", "tenant-1/project-1=mallory"],
          ["tenant-1/project-1"],
          ["tenant-1/project-1="],
          ["../project-1=bob"],
          ["tenant-1//project-1=bob"]
        ] do
      assert {:error, :invalid_successor_selection} = Succeed.parse_successors(selections)
    end
  end

  test "complete succession covers exactly projects actually owned in one chapter" do
    assert Succeed.complete?(details(), @principal, @chapter, successors()) == :ok

    assert {:error, :invalid_chapter_holdings} =
             Succeed.complete?(
               Map.put(details(), "principal_id", "mallory"),
               @principal,
               @chapter,
               successors()
             )

    assert {:error, _} = Succeed.complete?(details(), @principal, @chapter, %{})

    assert {:error, _} =
             Succeed.complete?(
               details(),
               @principal,
               @chapter,
               Map.put(successors(), {"tenant-4", "foreign"}, "bob")
             )
  end

  test "sign only exact scoped offboard/assignment/key-revocation sequence" do
    assert Succeed.expected?(
             cores(),
             details(),
             @principal,
             @chapter,
             "governance-A",
             successors()
           )

    for candidate <- [
          tl(cores()),
          Enum.reverse(cores()),
          cores() ++ [hd(cores())],
          [put_in(hd(cores()), ["payload", "principal_id"], "mallory") | tl(cores())],
          [Map.put(hd(cores()), "chapter_id", "other-chapter") | tl(cores())],
          List.replace_at(
            cores(),
            2,
            put_in(Enum.at(cores(), 2), ["payload", "project_id"], "foreign")
          ),
          List.replace_at(
            cores(),
            3,
            put_in(Enum.at(cores(), 3), ["payload", "key_id"], "attacker")
          )
        ] do
      refute Succeed.expected?(
               candidate,
               details(),
               @principal,
               @chapter,
               "governance-A",
               successors()
             )
    end
  end
end
