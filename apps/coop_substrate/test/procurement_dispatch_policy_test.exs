defmodule CoopSubstrate.ProcurementDispatchPolicyTest do
  use ExUnit.Case, async: true

  alias CoopSubstrate.{Procurement, ProcurementDispatch}
  alias CoopSubstrate.Protocol.Envelope
  alias CommerceCore.MerchantPilot.Workflow

  @tenant "11111111-1111-1111-1111-111111111111"
  @pubkey <<1::256>>
  @scope {"chapter", "coop", "order"}
  @pick String.duplicate("a", 64)
  @drop String.duplicate("b", 64)

  test "the canonical order reaches fulfillment through the existing reducer" do
    trusted = %{
      authorized: true,
      chapter_id: "chapter",
      cooperative_id: "coop",
      request_id: "order",
      actor_id: "coordinator",
      now_ms: 1
    }

    commands = [
      {:request,
       %{
         buyer_business_id: "buyer",
         description: "packaging",
         quantity: 1,
         currency: "USD",
         needed_by_ms: 5,
         consent_ref: "consent"
       }},
      {:qualify, %{evidence_ref: "qualification"}},
      {:quote,
       %{
         quote_id: "q",
         merchant_business_id: "seller",
         revision: 1,
         total_minor: 1000,
         currency: "USD",
         expires_at_ms: 4,
         source_ref: "source"
       }},
      {:accept, %{quote_id: "q", revision: 1, buyer_business_id: "buyer", evidence_ref: "accept"}}
    ]

    accepted =
      commands
      |> Enum.with_index()
      |> Enum.reduce(nil, fn {{action, attrs}, v}, row ->
        {:ok, row, :accepted} =
          Workflow.apply_command(row, trusted, %{
            id: "business-#{v}",
            expected_version: v,
            action: action,
            attrs: attrs
          })

        row
      end)

    state = %{
      Procurement.init()
      | requests: %{@scope => accepted},
        businesses: %{
          {"chapter", "coop", "buyer"} => %{active: true},
          {"chapter", "coop", "seller"} => %{active: true}
        }
    }

    route =
      env(%{
        "tenant_id" => @tenant,
        "site" => "North dock",
        "key_id" => "dispatch",
        "pubkey" => {:bytes, @pubkey},
        "active" => true,
        "expected_version" => 0
      })

    assert {:ok, state} = ProcurementDispatch.configure(state, route)

    assert {:ok, state} =
             ProcurementDispatch.request(
               state,
               env(%{
                 "request_id" => "order",
                 "expected_version" => 4,
                 "pickup_digest" => @pick,
                 "dropoff_digest" => @drop
               })
             )

    assert {:error, :procurement_dispatch_route_in_use} =
             ProcurementDispatch.configure(state, %{
               route
               | payload:
                   Map.merge(
                     route.payload,
                     %{"site" => "different", "expected_version" => 1}
                   )
             })

    finish = fn row, signed ->
      command = %{
        id: "dispatch-finish",
        expected_version: row.version,
        action: :fulfill,
        attrs: %{evidence_ref: "dispatch:" <> signed.payload["proof_id"]}
      }

      assert {:ok, row, :accepted} = Workflow.apply_command(row, trusted, command)
      {:ok, row}
    end

    assert {:ok, accepted_handoff} = ProcurementDispatch.step(state, step("accept", 0), finish)

    assert {:error, :dispatch_custody_reconciliation_required} =
             ProcurementDispatch.permit_commercial(accepted_handoff, @scope, :cancel)

    assert {:ok, moving} =
             ProcurementDispatch.step(
               accepted_handoff,
               step("picked_up", 1, %{
                 "proof_id" => "44444444-4444-4444-4444-444444444444",
                 "proof_digest" => @pick
               }),
               finish
             )

    delivery =
      step("delivered", 2, %{
        "proof_id" => "55555555-5555-5555-5555-555555555555",
        "proof_digest" => @drop
      })

    assert {:ok, done} = ProcurementDispatch.step(moving, delivery, finish)
    assert map_size(done.requests) == 1

    assert %{scope: @scope, phase: :fulfilled, version: 6, payment_evidence: []} =
             done.requests[@scope]

    assert done.requests[@scope].accepted_quote == accepted.accepted_quote
    assert {:error, :duplicate_delivery_step} = ProcurementDispatch.step(done, delivery, finish)
  end

  defp step(op, version, extra \\ %{}) do
    env(
      Map.merge(
        %{
          "op" => op,
          "expected_version" => version,
          "command_id" => op,
          "order_id" => "order",
          "tenant_id" => @tenant,
          "load_id" => "22222222-2222-2222-2222-222222222222",
          "assignment_id" => "33333333-3333-3333-3333-333333333333",
          "automated" => true
        },
        extra
      )
    )
  end

  defp env(payload) do
    %Envelope{
      chapter_id: "chapter",
      event_id: "event",
      type: "test",
      timestamp_ms: 1,
      signers: [%{role: "procurement_dispatch", key_id: "dispatch", pubkey: @pubkey}],
      payload: Map.put(payload, "cooperative_id", "coop")
    }
  end
end
