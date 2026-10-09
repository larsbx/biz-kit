defmodule Dispatch.IdempotencyTest do
  @moduledoc """
  Section 24's ledger, at the level the HTTP tests cannot reach: what happens
  when a mutation fails, when two copies arrive together, and when the process
  running one dies partway.

  The last is the reason `execute/4` uses a transaction. A claim written
  separately from the mutation it guards has a window in which a key is taken
  and nothing records whether the work happened — and no later reader can tell.
  """

  use ExUnit.Case, async: false

  alias Dispatch.Idempotency
  alias Dispatch.Operations.ParticipantStatusEvent
  alias Dispatch.Support.Fixtures

  require Ash.Query

  @moduletag :integration

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)

    org = Fixtures.carrier()
    driver = Fixtures.participant(org.id, org)

    %{
      org: org,
      tenant: org.id,
      driver: driver,
      actor: Fixtures.actor(org.id, org, driver, "DRIVER")
    }
  end

  defp key, do: "key-" <> Ash.UUID.generate()

  # A mutation that actually writes, so "did the work survive?" is a question
  # the database can answer rather than one the test asserts about itself.
  defp declare(ctx, status) do
    fn ->
      case Dispatch.Operations.Declarations.declare(ctx.actor, %{
             status: status,
             occurred_at: DateTime.utc_now()
           }) do
        {:ok, _how, event} -> {:ok, 201, %{"id" => event.id}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp events(ctx) do
    ParticipantStatusEvent
    |> Ash.Query.filter(participant_id == ^ctx.driver.id)
    |> Ash.read!(authorize?: false, tenant: ctx.tenant)
  end

  describe "running a mutation under a key" do
    test "the first call runs it and a replay returns the stored response", ctx do
      k = key()
      body = %{"status" => "AT_PICKUP"}

      assert {:ok, 201, %{"id" => id}} =
               Idempotency.execute(ctx.actor, k, body, declare(ctx, :AT_PICKUP))

      # The replay must not run the mutation again, and must answer with what
      # the first call stored rather than with a fresh result that resembles it.
      assert {:ok, 201, %{"id" => ^id}} =
               Idempotency.execute(ctx.actor, k, body, fn ->
                 flunk("the mutation ran a second time")
               end)

      assert length(events(ctx)) == 1
    end

    test "a key reused for different content is refused without running", ctx do
      k = key()

      assert {:ok, 201, _body} =
               Idempotency.execute(
                 ctx.actor,
                 k,
                 %{"status" => "AT_PICKUP"},
                 declare(ctx, :AT_PICKUP)
               )

      assert {:error, :key_reused} =
               Idempotency.execute(ctx.actor, k, %{"status" => "LOADING"}, fn ->
                 flunk("the mutation ran under a reused key")
               end)

      assert length(events(ctx)) == 1
    end

    test "a rejected mutation releases the key and leaves nothing behind", ctx do
      k = key()

      # DELAYED without a note is refused by Section 24.1's validation.
      assert {:error, _reason} =
               Idempotency.execute(ctx.actor, k, %{"status" => "DELAYED"}, declare(ctx, :DELAYED))

      assert events(ctx) == []

      # The same key, now carrying work that succeeds. Storing the failure would
      # have made a transient client error permanent for twenty-four hours.
      assert {:ok, 201, _body} =
               Idempotency.execute(
                 ctx.actor,
                 k,
                 %{"status" => "AT_PICKUP"},
                 declare(ctx, :AT_PICKUP)
               )
    end

    test "two actors may hold the same key string", ctx do
      other = Fixtures.participant(ctx.tenant, ctx.org)
      theirs = Fixtures.actor(ctx.tenant, ctx.org, other, "DRIVER")

      assert {:ok, 201, _mine} =
               Idempotency.execute(ctx.actor, "shared", %{}, fn -> {:ok, 201, %{}} end)

      assert {:ok, 201, _theirs} =
               Idempotency.execute(theirs, "shared", %{}, fn -> {:ok, 201, %{}} end)
    end

    test "a key is optional; without one the mutation simply runs", ctx do
      assert {:ok, 201, _first} =
               Idempotency.execute(ctx.actor, nil, %{}, declare(ctx, :AT_PICKUP))

      assert {:ok, 201, _second} =
               Idempotency.execute(ctx.actor, nil, %{}, declare(ctx, :LOADING))

      assert length(events(ctx)) == 2
    end
  end

  describe "a process that dies partway" do
    test "leaves neither a claimed key nor a half-finished mutation", ctx do
      k = key()
      body = %{"status" => "AT_PICKUP"}

      # The window that a separate claim-then-record design cannot close: the
      # mutation committed, the response was never written. Here the transaction
      # takes both down together, so there is nothing to reconcile afterwards.
      assert catch_exit(
               Idempotency.execute(ctx.actor, k, body, fn ->
                 Dispatch.Operations.Declarations.declare(ctx.actor, %{
                   status: :AT_PICKUP,
                   occurred_at: DateTime.utc_now()
                 })

                 exit(:killed)
               end)
             ) == :killed

      assert events(ctx) == []

      # And the key is free, because nothing was ever durably claimed under it.
      assert {:ok, 201, _body} = Idempotency.execute(ctx.actor, k, body, declare(ctx, :AT_PICKUP))
      assert length(events(ctx)) == 1
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

      assert {:ok, 201, %{"id" => first}} =
               Idempotency.execute(ctx.actor, k, body, declare(ctx, :AT_PICKUP))

      # Age the row past its window without sweeping. If expiry were enforced
      # only by the sweep, a paused job would leave a day-old response replaying
      # forever — a correctness bug wearing a housekeeping costume.
      expire(ctx, k)

      assert {:ok, 201, %{"id" => second}} =
               Idempotency.execute(ctx.actor, k, body, declare(ctx, :AT_PICKUP))

      refute first == second
    end

    test "purges records past their window and keeps the rest", ctx do
      assert {:ok, 201, _body} =
               Idempotency.execute(ctx.actor, key(), %{}, fn -> {:ok, 201, %{}} end)

      assert Idempotency.purge_expired(DateTime.utc_now()) == 0

      later = DateTime.add(DateTime.utc_now(), 24 * 60 * 60 + 60, :second)
      assert Idempotency.purge_expired(later) == 1
    end
  end

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
end
