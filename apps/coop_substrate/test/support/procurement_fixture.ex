defmodule CoopSubstrate.ProcurementTestClock do
  @moduledoc false
  def system_time(:millisecond), do: :persistent_term.get(__MODULE__, 1_800_000_000_000)
  def set(ms), do: :persistent_term.put(__MODULE__, ms)
end

defmodule CoopSubstrate.ProcurementFixture do
  @moduledoc false
  alias CoopSubstrate.{Log, LogCase, Procurement, ProcurementTestClock}
  @now 1_800_000_000_000
  def setup do
    ProcurementTestClock.set(@now)
    :ok = Procurement.register_types!()
    gov = LogCase.new_member("governance", "gov")
    operator = LogCase.new_member("procurement_operator", "operator-key")
    context = %{chapter_id: "procurement-test", cooperative_id: "coop",
      operator_id: "coordinator", key_id: operator.signer.key_id, seed: operator.seed,
      grant_version: 1, session_expires_at_ms: @now + 3_600_000}
    f = %{gov: gov, operator: operator, context: context, now: @now}
    genesis = LogCase.signed_event(gov, "RoleKeyDeclared",
      %{"role" => "governance", "key_id" => "gov", "pubkey" => {:bytes, gov.signer.pubkey}},
      chapter_id: context.chapter_id, timestamp_ms: @now)
    {:ok, [_]} = Log.append(genesis)
    {:ok, [_]} = Log.append(grant(f, true, 0))
    Enum.each(["buyer", "merchant"], fn business ->
      {:ok, [_]} = Log.append(event(f, "ProcurementBusinessEnrolledV1",
        %{"cooperative_id" => "coop", "business_id" => business, "active" => true,
          "evidence_ref" => "private-enrollment-" <> business, "expected_version" => 0}))
    end)
    f
  end
  def event(f, type, payload), do: LogCase.signed_event(f.gov, type, payload,
    chapter_id: f.context.chapter_id,
    timestamp_ms: div(Procurement.clock_ms(), 1_000) * 1_000)
  def grant(f, active, expected), do: event(f, "ProcurementOperatorGrantedV1",
    %{"cooperative_id" => "coop", "operator_id" => "coordinator", "active" => active,
      "key_id" => f.operator.signer.key_id, "pubkey" => {:bytes, f.operator.signer.pubkey},
      "expires_at_ms" => f.now + 7_200_000, "expected_version" => expected})
  def request(f), do: %{"buyer_business_id" => "buyer", "description" => "Bulk packaging",
    "quantity" => 4, "currency" => "USD", "needed_by_ms" => f.now + 86_400_000,
    "consent_ref" => "buyer-consent-private"}
  def quote(f), do: %{"quote_id" => "quote-1", "merchant_business_id" => "merchant",
    "revision" => 1, "total_minor" => 12000, "currency" => "USD",
    "expires_at_ms" => f.now + 600_000, "source_ref" => "merchant-quote-private"}
  def acceptance, do: %{"quote_id" => "quote-1", "revision" => 1,
    "buyer_business_id" => "buyer", "evidence_ref" => "buyer-acceptance-private"}
  def command(action, version, attrs, id \\ nil), do: %{"id" => id || "#{action}-#{version}",
    "action" => action, "expected_version" => version, "attrs" => attrs}
  def submit(f, action, version, attrs),
    do: Procurement.submit(f.context, "request-1", command(action, version, attrs))
  def quoted(f) do
    {:ok, _} = submit(f, "request", 0, request(f))
    {:ok, _} = submit(f, "qualify", 1, %{"evidence_ref" => "qualification"})
    {:ok, _} = submit(f, "quote", 2, quote(f))
    :ok
  end
end
