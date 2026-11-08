ExUnit.start()

defmodule ProcurementMVPTest do
  use ExUnit.Case, async: true
  alias CommerceCore.MerchantPilot.Workflow, as: W

  defp trusted(overrides \\ %{}), do: Map.merge(%{authorized: true, chapter_id: "ch", cooperative_id: "coop", request_id: "req", actor_id: "operator", now_ms: 1000}, overrides)
  defp request, do: %{buyer_business_id: "buyer", description: "100 cartons", quantity: 100, currency: "USD", needed_by_ms: 10_000, consent_ref: "private:consent"}
  defp quote(rev \\ 1), do: %{quote_id: "q", merchant_business_id: "merchant", revision: rev, total_minor: 9000, currency: "USD", expires_at_ms: 2000, source_ref: "private:quote:#{rev}"}
  defp accept(rev \\ 1), do: %{quote_id: "q", revision: rev, buyer_business_id: "buyer", evidence_ref: "private:acceptance"}
  defp evidence, do: %{evidence_ref: "private:evidence"}
  defp command(s, action, attrs, id \\ nil), do: %{id: id || "#{action}:#{if(s, do: s.version, else: 0)}", expected_version: if(s, do: s.version, else: 0), action: action, attrs: attrs}
  defp take(s, action, attrs) do
    {:ok, next, :accepted} = W.apply_command(s, trusted(), command(s, action, attrs))
    next
  end
  defp prepared do
    nil |> take(:request, request()) |> take(:qualify, evidence()) |> take(:quote, quote())
  end

  test "request through fulfillment; payment is separate and explicitly unverified" do
    s = prepared() |> take(:accept, accept()) |> take(:fulfill, evidence())
    assert s.phase == :fulfilled
    assert s.version == 5
    assert s.payment_evidence == []
    paid = take(s, :payment_evidence, evidence())
    assert [%{status: :operator_attestation, bank_verified: false}] = paid.payment_evidence
    assert paid.accepted_quote == s.accepted_quote
    assert paid.phase == :fulfilled
  end

  test "same command is idempotent even after a later transition" do
    s = prepared()
    c = command(s, :accept, accept())
    {:ok, a, :accepted} = W.apply_command(s, trusted(), c)
    f = take(a, :fulfill, evidence())
    assert {:ok, ^f, :duplicate} = W.apply_command(f, trusted(), c)
  end

  test "same command id with changed content is refused" do
    s = prepared()
    c = command(s, :accept, accept())
    {:ok, a, :accepted} = W.apply_command(s, trusted(), c)
    changed = put_in(c, [:attrs, :evidence_ref], "different")
    assert {:error, :idempotency_conflict} = W.apply_command(a, trusted(), changed)
  end

  test "revocation is checked before duplicate handling" do
    s = prepared()
    c = command(s, :accept, accept())
    {:ok, a, :accepted} = W.apply_command(s, trusted(), c)
    assert {:error, :forbidden} = W.apply_command(a, trusted(%{authorized: false}), c)
  end

  test "all three scope components must match" do
    s = prepared()
    for key <- [:chapter_id, :cooperative_id, :request_id] do
      assert {:error, :scope_mismatch} = W.apply_command(s, trusted(%{key => "other"}), command(s, :accept, accept()))
    end
  end

  test "sequential admission rejects a competing command at the old version" do
    s = prepared()
    a = take(s, :accept, accept())
    assert {:error, :stale_version} = W.apply_command(a, trusted(), command(s, :cancel, evidence()))
  end

  test "acceptance requires the exact latest quote revision" do
    s = take(prepared(), :quote, quote(2))
    assert {:error, :quote_revision_conflict} = W.apply_command(s, trusted(), command(s, :accept, accept(1)))
    a = take(s, :accept, accept(2))
    assert a.accepted_quote.revision == 2
    assert a.accepted_quote.source_ref == "private:quote:2"
    assert {:error, :illegal_transition} = W.apply_command(a, trusted(), command(a, :quote, quote(3)))
  end

  test "quote revision cannot change its merchant owner or skip a revision" do
    s = prepared()
    assert {:error, :quote_owner_mismatch} = W.apply_command(s, trusted(), command(s, :quote, %{quote(2) | merchant_business_id: "other"}))
    assert {:error, :quote_revision_conflict} = W.apply_command(s, trusted(), command(s, :quote, quote(3)))
  end

  test "acceptance cannot substitute another buyer" do
    s = prepared()
    assert {:error, :buyer_mismatch} = W.apply_command(s, trusted(), command(s, :accept, %{accept() | buyer_business_id: "other"}))
  end

  test "expiration boundary uses trusted admission time" do
    s = prepared()
    assert {:error, :quote_expired} = W.apply_command(s, trusted(%{now_ms: 2000}), command(s, :accept, accept()))
    assert {:ok, _, :accepted} = W.apply_command(s, trusted(%{now_ms: 1999}), command(s, :accept, accept()))
  end

  test "unknown payment is not zero and acceptance creates no payment observation" do
    s = take(prepared(), :accept, accept())
    assert s.payment_evidence == []
    refute Map.has_key?(s, :paid_minor)
    refute Map.has_key?(s, :settled)
  end

  test "fulfillment requires acceptance; terminal outcomes cannot be reopened" do
    s = prepared()
    assert {:error, :illegal_transition} = W.apply_command(s, trusted(), command(s, :fulfill, evidence()))
    c = take(s, :cancel, evidence())
    assert {:error, :illegal_transition} = W.apply_command(c, trusted(), command(c, :accept, accept()))
  end

  test "dispute after fulfillment preserves the accepted snapshot" do
    a = take(prepared(), :accept, accept())
    d = a |> take(:fulfill, evidence()) |> take(:dispute, evidence())
    assert d.phase == :disputed
    assert d.accepted_quote == a.accepted_quote
    assert d.acceptance_ref == a.acceptance_ref
  end

  test "cancellation after acceptance preserves the accepted snapshot" do
    a = take(prepared(), :accept, accept())
    c = take(a, :cancel, evidence())
    assert c.accepted_quote == a.accepted_quote
  end

  test "malformed and additional attributes fail closed" do
    s = prepared()
    assert {:error, :invalid_command} = W.apply_command(s, trusted(), %{})
    assert {:error, :invalid_acceptance} = W.apply_command(s, trusted(), command(s, :accept, %{}))
    assert {:error, :invalid_acceptance} = W.apply_command(s, trusted(), command(s, :accept, Map.put(accept(), :authorized, true)))
    assert {:error, :invalid_evidence} = W.apply_command(s, trusted(), command(s, :cancel, %{evidence_ref: " "}))
  end

  test "quote currency cannot change and request consent is mandatory" do
    s = prepared()
    assert {:error, :invalid_quote} = W.apply_command(s, trusted(), command(s, :quote, %{quote(2) | currency: "EUR"}))
    assert {:error, :invalid_request} = W.apply_command(nil, trusted(), command(nil, :request, Map.delete(request(), :consent_ref)))
  end

  test "payload authorization cannot replace trusted authority" do
    assert {:error, :forbidden} = W.apply_command(nil, %{}, command(nil, :request, Map.put(request(), :authorized, true)))
  end

  test "fixed-context command replay reconstructs exactly the same state" do
    commands = [{:request, request()}, {:qualify, evidence()}, {:quote, quote()}, {:accept, accept()}, {:fulfill, evidence()}]
    replay = fn -> Enum.reduce(commands, nil, fn {a, p}, s -> take(s, a, p) end) end
    assert replay.() == replay.()
  end

  defp action_attrs("quote" <> r), do: {:quote, quote(String.to_integer(r))}
  defp action_attrs("accept" <> r), do: {:accept, accept(String.to_integer(r))}
  defp action_attrs("payment"), do: {:payment_evidence, evidence()}
  defp action_attrs(name), do: {Map.fetch!(%{"qualify" => :qualify, "fulfill" => :fulfill, "cancel" => :cancel, "dispute" => :dispute}, name), evidence()}
  defp projection(s) do
    phases = %{requested: 0, qualified: 1, accepted: 2, fulfilled: 3, cancelled: 4, disputed: 5}
    q = Map.get(s.quotes, "q")
    [Integer.to_string(phases[s.phase]), Integer.to_string(if(q, do: q.revision, else: 0)),
      Integer.to_string(if(s.accepted_quote, do: s.accepted_quote.revision, else: 0)),
      to_string(s.payment_evidence != [])]
  end

  test "Python reachable-state matrix agrees with the actual Elixir reducer" do
    lines = System.fetch_env!("PROCUREMENT_CONFORMANCE_TSV") |> File.read!() |> String.split("\n", trim: true)
    assert length(lines) > 0
    Enum.each(lines, fn line ->
      [path, action, authorized, current, result | expected] = String.split(line, "\t")
      s = take(nil, :request, request())
      s = Enum.reduce(if(path == "-", do: [], else: String.split(path, ",")), s, fn token, acc ->
        {a, attrs} = action_attrs(token)
        take(acc, a, attrs)
      end)
      {a, attrs} = action_attrs(action)
      c = command(s, a, attrs)
      c = if current == "true", do: c, else: %{c | expected_version: s.version - 1}
      actual = W.apply_command(s, trusted(%{authorized: authorized == "true"}), c)
      case result do
        "ok" ->
          assert {:ok, next, :accepted} = actual
          assert projection(next) == expected, line
          assert next.version == s.version + 1
        "error" ->
          assert {:error, _} = actual, line
      end
    end)
  end
end
