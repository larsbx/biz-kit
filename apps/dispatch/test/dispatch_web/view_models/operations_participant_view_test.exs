defmodule DispatchWeb.ViewModels.OperationsParticipantViewTest do
  @moduledoc """
  What an operations page may show about a participant (Sections 4.3, 23.2).

  Two prohibitions meet here, and they are different in kind.

  Acceptance criterion 15 is about *rows*: "a dispatcher sees only
  carrier-related participants and loads; removing the assignment relationship
  terminates REST, page, and SSE access."

  Acceptance criterion 14 is about *fields*: an administrator "cannot view
  precise location, message content, or negotiated load data without a separate
  scoped operational role". Section 23.2 goes further and withholds
  `operations.location.precise.read` from `DISPATCHER` too — precise location is
  a separate capability that additionally requires active consent, so the
  dispatcher's own page must show a coarse summary and not coordinates.

  A test that only checked "the admin gets denied" would miss the second
  entirely, because the dispatcher is allowed the page and still not allowed the
  coordinates.
  """

  use ExUnit.Case, async: false

  alias Dispatch.Support.Fixtures
  alias DispatchWeb.ViewModels.OperationsParticipantView

  @moduletag :integration

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)

    carrier = Fixtures.carrier()
    tenant = carrier.id

    %{participant: driver} = Fixtures.person(tenant, carrier)
    %{participant: dispatcher} = Fixtures.person(tenant, carrier)
    %{participant: admin} = Fixtures.person(tenant, carrier)

    %{
      tenant: tenant,
      carrier: carrier,
      driver: driver,
      dispatcher_actor: Fixtures.actor(tenant, carrier, dispatcher, "DISPATCHER"),
      admin_actor: Fixtures.actor(tenant, carrier, admin, "ADMIN")
    }
  end

  defp all_numbers(term, acc \\ [])
  defp all_numbers(%DateTime{}, acc), do: acc
  defp all_numbers(%_struct{} = value, acc), do: value |> Map.from_struct() |> all_numbers(acc)

  defp all_numbers(%{} = map, acc),
    do: Enum.reduce(map, acc, fn {_key, value}, acc -> all_numbers(value, acc) end)

  defp all_numbers(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, fn value, acc -> all_numbers(value, acc) end)

  defp all_numbers(value, acc) when is_number(value), do: [value | acc]
  defp all_numbers(_other, acc), do: acc

  describe "acceptance criterion 15: a dispatcher sees carrier-related participants" do
    test "builds for a participant in its own carrier", ctx do
      assert {:ok, view} =
               OperationsParticipantView.build(ctx.dispatcher_actor, ctx.driver.id)

      assert view.participant_id == ctx.driver.id
    end

    test "a participant in another carrier bears no existence", ctx do
      elsewhere = Fixtures.carrier()
      %{participant: stranger} = Fixtures.person(elsewhere.id, elsewhere)

      assert OperationsParticipantView.build(ctx.dispatcher_actor, stranger.id) ==
               {:error, :not_found}

      assert OperationsParticipantView.build(ctx.dispatcher_actor, Ash.UUID.generate()) ==
               {:error, :not_found}
    end

    test "a revoked assignment terminates page access", ctx do
      assert {:ok, _view} = OperationsParticipantView.build(ctx.dispatcher_actor, ctx.driver.id)

      Fixtures.revoke(ctx.tenant, ctx.dispatcher_actor.role_assignment)

      # Section 33.2: the relationship ending must terminate access, not defer
      # it to the next sign-in. The actor still holds its struct; the grant is
      # what has gone.
      assert OperationsParticipantView.build(ctx.dispatcher_actor, ctx.driver.id) ==
               {:error, :not_found}
    end
  end

  describe "acceptance criterion 14: an administrator gets no operational data" do
    test "an ADMIN-only principal cannot build the view at all", ctx do
      # Section 23.2: ADMIN carries no operational read. Membership management
      # is not operational visibility, and the manifest says so by omission.
      assert OperationsParticipantView.build(ctx.admin_actor, ctx.driver.id) ==
               {:error, :not_found}
    end
  end

  describe "Section 23.2: precise location is a separate capability" do
    test "a dispatcher does not hold the precise-location capability", ctx do
      # The manifest is the thing the page will depend on when Slice 2 adds
      # location samples, so it is worth pinning now: Section 23.2 withholds
      # this from DISPATCHER deliberately, and a page built against the
      # assumption that "dispatcher implies location" would be wrong from its
      # first line.
      refute Dispatch.Access.Actor.can?(ctx.dispatcher_actor, "operations.location.precise.read")
      assert Dispatch.Access.Actor.can?(ctx.dispatcher_actor, "operations.participant.read")
    end

    test "the view model has nowhere to put coordinates", ctx do
      {:ok, view} = OperationsParticipantView.build(ctx.dispatcher_actor, ctx.driver.id)

      # Structural rather than value-based, because there are no location
      # samples yet — Slice 2 owns those. Asserting the shape now means the
      # slice that adds them has to widen this struct deliberately, in a diff
      # that shows it, rather than finding a convenient field already waiting.
      refute Map.has_key?(view, :lat)
      refute Map.has_key?(view, :lng)
      refute Map.has_key?(view, :position)
      refute Map.has_key?(view, :route)

      assert all_numbers(view) == []
    end

    test "the freshness summary says what it is and how old, or is absent", ctx do
      {:ok, view} = OperationsParticipantView.build(ctx.dispatcher_actor, ctx.driver.id)

      case view.location_freshness do
        nil ->
          :ok

        summary ->
          assert summary.source
          assert summary.occurred_at
      end
    end
  end
end
