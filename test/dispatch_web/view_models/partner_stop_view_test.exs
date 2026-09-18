defmodule DispatchWeb.ViewModels.PartnerStopViewTest do
  @moduledoc """
  What a shipper or receiver page may carry (Sections 4.3, 26.5).

  Section 4.3 is a prohibition list, and a prohibition list is exactly the kind
  of requirement that rots quietly: a field added to the underlying resource
  next month appears on the page by default, and nothing fails. So these tests
  assert over the *whole* view model rather than over named fields — a leak is
  then caught by its presence, not by someone having remembered to test for it.

  > Shipper and receiver pages never expose the full driver timeline, continuous
  > route trace, unrelated stops, negotiated rate, internal carrier notes, or
  > other parties' communications. Their status and ETA summaries retain source
  > and freshness labels.

  Acceptance criterion 19 adds the part that is easiest to get wrong: an
  unrelated load "returns no existence-bearing metadata". Refusing with a
  message that admits the row exists is itself the leak.
  """

  use ExUnit.Case, async: false

  alias Dispatch.Support.Fixtures
  alias DispatchWeb.ViewModels.PartnerStopView

  @moduletag :integration

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)

    carrier = Fixtures.carrier()
    tenant = carrier.id
    shipper_org = Fixtures.organization(tenant, :SHIPPER)

    load =
      Fixtures.load(tenant, carrier,
        agreed_rate_minor: 250_000,
        currency: "USD",
        commodity_text: "Palletised goods"
      )

    pickup = Fixtures.stop(tenant, load, :PICKUP, sequence: 1)
    delivery = Fixtures.stop(tenant, load, :DELIVERY, sequence: 2)

    Fixtures.stop_party(tenant, pickup, shipper_org, :SHIPPER)

    %{participant: person} = Fixtures.person(tenant, shipper_org)
    actor = Fixtures.actor(tenant, shipper_org, person, "SHIPPER", scope_id: pickup.id)

    %{
      tenant: tenant,
      carrier: carrier,
      shipper_org: shipper_org,
      load: load,
      pickup: pickup,
      delivery: delivery,
      actor: actor
    }
  end

  # Every string reachable anywhere in the view model, however nested. A field
  # added later is covered without anyone updating this.
  defp all_strings(term, acc \\ [])
  defp all_strings(%DateTime{}, acc), do: acc
  defp all_strings(%_struct{} = value, acc), do: value |> Map.from_struct() |> all_strings(acc)

  defp all_strings(%{} = map, acc),
    do: Enum.reduce(map, acc, fn {_key, value}, acc -> all_strings(value, acc) end)

  defp all_strings(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, fn value, acc -> all_strings(value, acc) end)

  defp all_strings(value, acc) when is_binary(value), do: [value | acc]
  defp all_strings(_other, acc), do: acc

  # Substring, over every string anywhere in the structure. Equality would miss
  # a value formatted into a longer one, which is how a leak usually looks.
  defp mentions?(view, needle) do
    Enum.any?(all_strings(view), &String.contains?(&1, needle))
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

  describe "the stop a partner is party to" do
    test "renders readiness, window and instructions", ctx do
      assert {:ok, view} = PartnerStopView.build(ctx.actor, ctx.pickup.id)

      assert view.stop_id == ctx.pickup.id
      assert view.kind == :PICKUP
      assert view.address_text == ctx.pickup.address_text
      assert view.window_start == ctx.pickup.window_start
    end
  end

  describe "Section 4.3: what a partner page never carries" do
    test "does not carry the negotiated rate, as a value or anywhere nested", ctx do
      {:ok, view} = PartnerStopView.build(ctx.actor, ctx.pickup.id)

      # Asserted over every number in the structure rather than over a named
      # field, so a rate reintroduced under a different name is still caught.
      refute 250_000 in all_numbers(view)

      # And over substrings, not equality: a leak that formats the rate into a
      # larger string — "USD 250000" — is the same leak, and an equality check
      # would wave it through. This test did exactly that until a planted leak
      # took that shape and it stayed green.
      refute mentions?(view, "USD")
      refute mentions?(view, "250000")
    end

    test "does not carry the other stop on the same load", ctx do
      {:ok, view} = PartnerStopView.build(ctx.actor, ctx.pickup.id)

      refute mentions?(view, ctx.delivery.id)
      refute mentions?(view, ctx.delivery.address_text)
    end

    test "does not carry a continuous route trace or any driver position", ctx do
      {:ok, view} = PartnerStopView.build(ctx.actor, ctx.pickup.id)

      # A route trace is a list of positions; the view model has nowhere to put
      # one, and this asserts that rather than trusting it.
      refute Map.has_key?(view, :route)
      refute Map.has_key?(view, :positions)
      refute Map.has_key?(view, :timeline)
    end

    test "does not carry internal carrier notes", ctx do
      {:ok, view} = PartnerStopView.build(ctx.actor, ctx.pickup.id)

      refute mentions?(view, ctx.load.commodity_text)
    end
  end

  describe "acceptance criterion 19: an unrelated subject bears no existence" do
    test "a stop the partner is not party to is indistinguishable from one that does not exist",
         ctx do
      unrelated = PartnerStopView.build(ctx.actor, ctx.delivery.id)
      absent = PartnerStopView.build(ctx.actor, Ash.UUID.generate())

      # Identical, not merely both errors. "Forbidden" for one and "not found"
      # for the other is an existence oracle: it answers a question the caller
      # is not entitled to ask.
      assert unrelated == absent
      assert unrelated == {:error, :not_found}
    end

    test "a stop in another tenant is equally indistinguishable", ctx do
      elsewhere = Fixtures.carrier()
      their_load = Fixtures.load(elsewhere.id, elsewhere)
      their_stop = Fixtures.stop(elsewhere.id, their_load, :PICKUP, sequence: 1)

      assert PartnerStopView.build(ctx.actor, their_stop.id) == {:error, :not_found}
    end

    test "revoking the role assignment removes access immediately", ctx do
      assert {:ok, _view} = PartnerStopView.build(ctx.actor, ctx.pickup.id)

      Fixtures.revoke(ctx.tenant, ctx.actor.role_assignment)

      # An Actor holds its assignment as a value, so this only fails closed if
      # the view re-reads it. The HTTP path resolves an actor per request and
      # would mask the omission entirely — which is how it went missing here
      # once already, and why the check belongs at this level too.
      assert PartnerStopView.build(ctx.actor, ctx.pickup.id) == {:error, :not_found}
    end

    test "ending the party relationship removes access immediately", ctx do
      assert {:ok, _view} = PartnerStopView.build(ctx.actor, ctx.pickup.id)

      Fixtures.end_stop_party(ctx.tenant, ctx.pickup, ctx.shipper_org)

      # Section 33.2: removing a stop_parties relationship invalidates related
      # access immediately, not at the next login.
      assert PartnerStopView.build(ctx.actor, ctx.pickup.id) == {:error, :not_found}
    end
  end

  describe "acceptance criterion 17: the selected scope bounds the stop, not the organization" do
    setup ctx do
      # The case the earlier tests could not reach: the same partner
      # organization is party to *both* stops. Being party is then no longer
      # enough to tell them apart — only the assignment's scope does.
      Fixtures.stop_party(ctx.tenant, ctx.delivery, ctx.shipper_org, :RECEIVER)
      ctx
    end

    test "a stop the organization is party to but the assignment is not scoped to", ctx do
      # Criterion 17: a shipper "sees one pickup stop ... but cannot view a
      # delivery stop". Party-to-the-organization would show both.
      assert PartnerStopView.build(ctx.actor, ctx.delivery.id) == {:error, :not_found}
    end

    test "the scoped stop still resolves", ctx do
      assert {:ok, view} = PartnerStopView.build(ctx.actor, ctx.pickup.id)
      assert view.stop_id == ctx.pickup.id
    end

    test "an assignment scoped to the other stop sees that one and not this one", ctx do
      %{participant: receiver} = Fixtures.person(ctx.tenant, ctx.shipper_org)

      other_actor =
        Fixtures.actor(ctx.tenant, ctx.shipper_org, receiver, "RECEIVER",
          scope_id: ctx.delivery.id
        )

      assert {:ok, view} = PartnerStopView.build(other_actor, ctx.delivery.id)
      assert view.stop_id == ctx.delivery.id
      assert PartnerStopView.build(other_actor, ctx.pickup.id) == {:error, :not_found}
    end
  end

  describe "every stop kind the resource permits" do
    test "an OTHER stop builds like any other", ctx do
      # Section 22.2 allows PICKUP, DELIVERY and OTHER. A view or component that
      # handles two of the three turns valid persisted data into a 500.
      other = Fixtures.stop(ctx.tenant, ctx.load, :OTHER, sequence: 3)
      Fixtures.stop_party(ctx.tenant, other, ctx.shipper_org, :SHIPPER)

      %{participant: person} = Fixtures.person(ctx.tenant, ctx.shipper_org)
      actor = Fixtures.actor(ctx.tenant, ctx.shipper_org, person, "SHIPPER", scope_id: other.id)

      assert {:ok, view} = PartnerStopView.build(actor, other.id)
      assert view.kind == :OTHER
    end
  end

  describe "Section 4.3: summaries keep their provenance" do
    test "a status summary carries source and freshness or is absent", ctx do
      {:ok, view} = PartnerStopView.build(ctx.actor, ctx.pickup.id)

      case view.arrival_summary do
        nil ->
          :ok

        summary ->
          # Section 1 keeps a declaration distinct from an observation; a
          # summary that has lost its source has lost the distinction.
          assert summary.source
          assert summary.occurred_at
      end
    end
  end
end
