defmodule CoopSubstrate.CharterConstantAuthorityTest do
  @moduledoc """
  Charter constants set finance caps, cure windows and harness gates, so
  declaring one is a governance act. Phase 1A left `CharterConstantDeclared`
  ungated, to be "enforceable by the 1D governance workflow later"
  (docs/phase1b_plan.md); the runbook already signs it with the governance
  key in the `author` slot (Harness.Ops.declare_constants/5).

  The gate: before a chapter's governance genesis, bootstrap as before.
  After it, the author key must be a currently declared governance key.
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Log
  alias CoopSubstrate.Projections.Membership

  @chapter "chapter-genesis"

  setup do
    %{gov: new_member("governance")}
  end

  defp genesis!(gov) do
    {:ok, _} =
      Log.append(
        signed_event(gov, "RoleKeyDeclared", %{
          "role" => "governance",
          "key_id" => gov.signer.key_id,
          "pubkey" => {:bytes, gov.signer.pubkey}
        })
      )
  end

  defp as_author(member), do: put_in(member, [:signer, :role], "author")

  defp declare(author, name, value),
    do: signed_event(author, "CharterConstantDeclared", %{"name" => name, "value" => value})

  defp constant(name) do
    {:ok, state} = Log.replay(Membership)
    state.charter_constants[{@chapter, name}]
  end

  test "before governance genesis any author may declare (bootstrap)" do
    assert {:ok, _} = Log.append(declare(new_member("author"), "cockpit/open_cap", 8))
    assert constant("cockpit/open_cap") == 8
  end

  test "after genesis an author key that is not declared governance is refused", %{gov: gov} do
    genesis!(gov)
    rogue = new_member("author")
    before = Log.head()

    assert {:error, {:reject, _, reason}} =
             Log.append(declare(rogue, "finance/borrower_cap_minor", 999_999_999))

    assert reason == {:charter_constant_requires_governance, rogue.signer.key_id}
    assert Log.head() == before
    assert constant("finance/borrower_cap_minor") == nil
  end

  test "after genesis the declared governance key, signing as author, may declare and redeclare",
       %{gov: gov} do
    genesis!(gov)
    assert {:ok, _} = Log.append(declare(as_author(gov), "honorarium/payout_cleared", 0))
    assert {:ok, _} = Log.append(declare(as_author(gov), "honorarium/payout_cleared", 1))
    assert constant("honorarium/payout_cleared") == 1
  end

  test "a revoked governance key can no longer declare", %{gov: gov} do
    genesis!(gov)
    successor = new_member("governance")

    {:ok, _} =
      Log.append(
        signed_event(gov, "RoleKeyDeclared", %{
          "role" => "governance",
          "key_id" => successor.signer.key_id,
          "pubkey" => {:bytes, successor.signer.pubkey}
        })
      )

    {:ok, _} =
      Log.append(
        signed_event(successor, "RoleKeyRevoked", %{
          "role" => "governance",
          "key_id" => gov.signer.key_id
        })
      )

    assert {:error, {:reject, _, {:charter_constant_requires_governance, _}}} =
             Log.append(declare(as_author(gov), "cockpit/open_cap", 99))

    assert {:ok, _} = Log.append(declare(as_author(successor), "cockpit/open_cap", 9))
    assert constant("cockpit/open_cap") == 9
  end
end
