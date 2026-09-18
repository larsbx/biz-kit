defmodule Dispatch.IdempotencyTest do
  @moduledoc """
  Section 24's ledger, at the level the HTTP tests cannot reach: concurrency and
  the twenty-four hour bound.

  The race is the reason this module exists. A handset retrying over a flaky
  link is the normal case (Section 14's offline outbox), so two copies of one
  request arriving together is not a corner case to note — it is the case.
  """

  use ExUnit.Case, async: false

  alias Dispatch.Idempotency
  alias Dispatch.Support.Fixtures

  @moduletag :integration

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)

    org = Fixtures.carrier()
    driver = Fixtures.participant(org.id, org)

    %{org: org, tenant: org.id, actor: Fixtures.actor(org.id, org, driver, "DRIVER")}
  end

  defp key, do: "key-" <> Ash.UUID.generate()

  # Ages a stored record past its retention window without invoking the sweep,
  # so the test is about the read path rather than about the sweep.
  defp expire(ctx, key) do
    import Ecto.Query, only: [from: 2]

    past = DateTime.add(DateTime.utc_now(), -60, :second)

    from(r in Dispatch.Idempotency.Record,
      where:
        r.idempotency_key == ^key and
          r.role_assignment_id == type(^ctx.actor.role_assignment.id, :binary_id)
    )
    |> Dispatch.Repo.update_all(set: [expires_at: past])
  end

  describe "claiming a key" do
    test "the first claim proceeds and a replay returns the stored response", ctx do
      k = key()
      body = %{"status" => "AT_PICKUP"}

      assert {:proceed, claim_id} = Idempotency.claim(ctx.actor, k, body)
      assert :ok = Idempotency.complete(claim_id, 201, %{"event" => %{"id" => "abc"}})

      assert {:replay, 201, %{"event" => %{"id" => "abc"}}} =
               Idempotency.claim(ctx.actor, k, body)
    end

    test "a key reused for different content is refused", ctx do
      k = key()

      assert {:proceed, claim_id} = Idempotency.claim(ctx.actor, k, %{"status" => "AT_PICKUP"})
      :ok = Idempotency.complete(claim_id, 201, %{})

      assert {:error, :key_reused} = Idempotency.claim(ctx.actor, k, %{"status" => "LOADING"})
    end

    test "a second claim before the first completes is refused, not run twice", ctx do
      k = key()
      body = %{"status" => "AT_PICKUP"}

      assert {:proceed, _claim_id} = Idempotency.claim(ctx.actor, k, body)
      # This is the race: the same request, arriving while the first is still in
      # flight. Letting it proceed would execute the mutation twice.
      assert {:error, :in_progress} = Idempotency.claim(ctx.actor, k, body)
    end

    test "an abandoned claim frees the key for a retry", ctx do
      k = key()

      assert {:proceed, claim_id} = Idempotency.claim(ctx.actor, k, %{"status" => "DELAYED"})
      :ok = Idempotency.abandon(claim_id)

      assert {:proceed, _again} = Idempotency.claim(ctx.actor, k, %{"status" => "DELAYED"})
    end

    test "two actors may hold the same key string", ctx do
      other = Fixtures.participant(ctx.tenant, ctx.org)
      theirs = Fixtures.actor(ctx.tenant, ctx.org, other, "DISPATCHER")
      k = "shared"

      assert {:proceed, _mine} = Idempotency.claim(ctx.actor, k, %{})
      assert {:proceed, _theirs} = Idempotency.claim(theirs, k, %{})
    end
  end

  describe "the request hash" do
    test "ignores key order, which JSON does not consider significant" do
      assert Idempotency.request_hash(%{"a" => 1, "b" => %{"c" => 2, "d" => 3}}) ==
               Idempotency.request_hash(%{"b" => %{"d" => 3, "c" => 2}, "a" => 1})
    end

    test "distinguishes different values" do
      refute Idempotency.request_hash(%{"status" => "AT_PICKUP"}) ==
               Idempotency.request_hash(%{"status" => "LOADING"})
    end

    test "distinguishes a nested difference" do
      refute Idempotency.request_hash(%{"a" => [1, 2, 3]}) ==
               Idempotency.request_hash(%{"a" => [1, 3, 2]})
    end
  end

  describe "retention (Section 24: twenty-four hours)" do
    test "an expired record does not replay, even before a sweep runs", ctx do
      k = key()
      body = %{"status" => "AT_PICKUP"}

      {:proceed, claim_id} = Idempotency.claim(ctx.actor, k, body)
      :ok = Idempotency.complete(claim_id, 201, %{"event" => %{"id" => "old"}})

      # Age the row past its window without sweeping. If expiry were enforced
      # only by the sweep, a paused job would leave a day-old response replaying
      # forever — which is a correctness bug wearing a housekeeping costume.
      expire(ctx, k)

      assert {:proceed, _fresh} = Idempotency.claim(ctx.actor, k, body)
    end

    test "an expired record does not block a key's reuse for other content", ctx do
      k = key()

      {:proceed, claim_id} = Idempotency.claim(ctx.actor, k, %{"status" => "AT_PICKUP"})
      :ok = Idempotency.complete(claim_id, 201, %{})
      expire(ctx, k)

      assert {:proceed, _fresh} = Idempotency.claim(ctx.actor, k, %{"status" => "LOADING"})
    end

    test "purges records past their window and keeps the rest", ctx do
      {:proceed, claim_id} = Idempotency.claim(ctx.actor, key(), %{})
      :ok = Idempotency.complete(claim_id, 201, %{})

      # Nothing is expired yet, so a sweep now must leave it alone.
      assert Idempotency.purge_expired(DateTime.utc_now()) == 0

      # A day and a minute later it is past the bound.
      later = DateTime.add(DateTime.utc_now(), 24 * 60 * 60 + 60, :second)
      assert Idempotency.purge_expired(later) == 1
    end
  end
end
