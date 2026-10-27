defmodule FederationCore.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias FederationCore.Subscriptions, as: S

  @buyer "https://buyer.example/actors/customer"
  @seller "https://seller.example/actors/shop"
  @follow_id "https://buyer.example/activities/follow-1"
  @accept_id "https://seller.example/activities/accept-1"
  @undo_id "https://buyer.example/activities/undo-1"

  defp follow! do
    {:ok, follow} = S.follow(@buyer, @seller, @follow_id)
    follow
  end

  defp context(actor, local_actor), do: %{verified_actor: actor, local_actor: local_actor}

  test "verified remote Follow yields a candidate, not a grant" do
    f = follow!()

    assert f["to"] == [@seller]
    assert {:ok, candidate} = S.decode_verified(f, context(@buyer, @seller))
    assert candidate.kind == :request
    assert candidate.follower == @buyer
    assert candidate.target == @seller
    assert candidate.follow_id == @follow_id
    assert candidate.authoritative == false
  end

  test "approved server reply and matched response are still nonauthoritative candidates" do
    f = follow!()

    for decision <- [:accept, :reject] do
      {:ok, reply} = S.respond(decision, @seller, f, @accept_id)
      assert reply["actor"] == @seller
      assert reply["to"] == [@buyer]
      assert reply["object"] == f

      assert {:ok, candidate} = S.decode_verified(reply, context(@seller, @buyer))
      assert candidate.kind == if(decision == :accept, do: :accepted, else: :rejected)
      assert candidate.follow_id == @follow_id
      assert candidate.authoritative == false
    end
  end

  test "only original follower can Undo their subscription request" do
    f = follow!()
    {:ok, undo} = S.undo(@buyer, f, @undo_id)
    assert {:ok, candidate} = S.decode_verified(undo, context(@buyer, @seller))
    assert candidate.kind == :withdraw
    assert candidate.follow_id == @follow_id

    assert {:error, :invalid_subscription_undo} =
             S.undo(@seller, f, "https://seller.example/activities/undo-2")
  end

  test "no remote actor can claim a local actor or recipient after transport verification" do
    f = follow!()

    assert {:error, :invalid_subscription_activity} =
             S.decode_verified(f, context(@seller, @seller))

    assert {:error, :invalid_subscription_activity} =
             S.decode_verified(Map.put(f, "actor", @seller), context(@buyer, @seller))

    assert {:error, :invalid_subscription_activity} =
             S.decode_verified(Map.put(f, "object", @buyer), context(@buyer, @seller))

    assert {:error, :invalid_subscription_activity} =
             S.decode_verified(Map.put(f, "to", [@buyer]), context(@buyer, @seller))
  end

  test "foreign activity IDs and embedded Follow substitution refuse authentication" do
    f = follow!()
    {:ok, reply} = S.respond(:accept, @seller, f, @accept_id)

    tampered =
      put_in(reply, ["object", "id"], "https://seller.example/activities/fake-follow")

    assert {:error, :invalid_subscription_activity} =
             S.decode_verified(tampered, context(@seller, @buyer))

    assert {:error, :invalid_subscription_activity} =
             S.decode_verified(Map.put(reply, "id", @follow_id), context(@seller, @buyer))

    assert {:error, :invalid_subscription_activity} =
             S.decode_verified(
               put_in(reply, ["object", "object"], @buyer),
               context(@seller, @buyer)
             )
  end

  test "no activity can embed business permissions or accept an unrelated object" do
    f = follow!()
    {:ok, reply} = S.respond(:accept, @seller, f, @accept_id)

    assert {:error, :invalid_subscription_activity} =
             S.decode_verified(Map.put(f, "grant", "merchant_admin"), context(@buyer, @seller))

    assert {:error, :invalid_subscription_activity} =
             S.decode_verified(Map.put(reply, "object", @follow_id), context(@seller, @buyer))

    assert {:error, :unsupported_subscription_activity} =
             S.decode_verified(Map.put(f, "type", "Offer"), context(@buyer, @seller))
  end

  test "rejects self-follow, non-HTTPS, private destinations and cross-host IDs" do
    assert {:error, :invalid_follow} = S.follow(@seller, @seller, @accept_id)
    assert {:error, :invalid_follow} = S.follow(@buyer, @seller, @accept_id)

    assert {:error, :invalid_follow} =
             S.follow("http://buyer.example/actors/x", @seller, @follow_id)

    assert {:error, :invalid_follow} = S.follow(@buyer, "https://127.0.0.1/actor", @follow_id)
    assert {:error, :invalid_follow} = S.follow(@buyer, "https://seller.local/actor", @follow_id)
  end

  test "accept and undo constructors require exact original Follow ownership" do
    f = follow!()

    assert {:error, :invalid_subscription_reply} =
             S.respond(:accept, @buyer, f, @follow_id)

    assert {:error, :invalid_subscription_reply} =
             S.respond(:accept, @seller, f, @follow_id)

    assert {:error, :invalid_subscription_reply} =
             S.respond(:approve_offer, @seller, f, @accept_id)

    assert {:error, :invalid_subscription_undo} =
             S.undo(@buyer, Map.put(f, "to", [@buyer]), @undo_id)
  end
end
