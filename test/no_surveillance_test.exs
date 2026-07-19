defmodule CoopSubstrate.NoSurveillanceTest do
  @moduledoc """
  Phase 1C step 9 (docs/phase1c_plan.md P9; hand-off acceptance item 14 and
  invariant §0.6): the substrate exposes system aggregates and a member's own
  data — never one member's detail to another. Tested as an ABSENCE: every
  public function on the query surface must be classified below; an
  unclassified function fails this test, forcing the classification review
  at the moment of addition.

  Classes (07 §5 disclosure classes, applied to the query side):

    * `:own_data`   — keyed by the subject member; returns that member's
      detail only. V0 shape note: queries are subject-keyed and there is no
      authn layer yet — requesting-member enforcement is 1D middleware, and
      THIS map is the contract it will enforce. (The plan sketched an
      explicit `for_member:` context param now; deviation: a parameter
      nothing checks is ceremony, the classification is the substance.)
    * `:bilateral`  — the two parties' co-signed relationship (netting: every
      input obligation already carries both signatures). Fourth class beyond
      the plan's three, mirroring the rail's disclosure class.
    * `:aggregate`  — cross-member summation; returns a bare total through
      the privacy seam, never a breakdown.
    * `:system`     — non-member-keyed system data (entity funds, boolean
      proof verdicts — a verifier learns one bit, which is the point).
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Capital
  alias CoopSubstrate.Finance
  alias CoopSubstrate.Floor
  alias CoopSubstrate.Log
  alias CoopSubstrate.Privacy
  alias CoopSubstrate.Throughput

  @surface %{
    Capital => %{
      {:account, 3} => :own_data,
      {:account, 4} => :own_data,
      {:balance, 3} => :own_data,
      {:balance, 4} => :own_data,
      {:sinking_fund, 2} => :system,
      {:sinking_fund, 3} => :system,
      {:sinking_fund_total, 1} => :aggregate,
      {:sinking_fund_total, 2} => :aggregate
    },
    Throughput => %{
      {:value, 4} => :own_data,
      {:value, 5} => :own_data,
      {:entries, 3} => :own_data,
      {:entries, 4} => :own_data,
      {:system_value, 2} => :aggregate,
      {:system_value, 3} => :aggregate,
      {:federation_value, 2} => :aggregate,
      {:federation_value, 3} => :aggregate
    },
    Floor => %{
      {:cleared?, 4} => :own_data
    },
    CoopSubstrate.Harness => %{
      # Section-level gate verdicts and counts — no member/interviewee detail.
      {:gate, 2} => :system,
      {:gate, 3} => :system,
      {:counts, 2} => :system,
      {:counts, 3} => :system,
      # Intake of the interviewee's own bilateral material.
      {:collect_document, 6} => :bilateral,
      # The honorarium tracker: interviewee-keyed money trail.
      {:honoraria, 1} => :bilateral,
      {:honoraria, 2} => :bilateral
    },
    CoopSubstrate.Harness.Artifacts => %{
      # Raw interview material — bilateral; access middleware is 1D-shaped.
      {:put, 1} => :bilateral,
      {:get, 1} => :bilateral
    },
    CoopSubstrate.Cockpit => %{
      # The operator's own queue + boards: process-level, no member detail.
      {:queue, 1} => :system,
      {:queue, 2} => :system,
      {:boards, 2} => :system,
      {:boards, 3} => :system
    },
    CoopSubstrate.Harness.Anonymization => %{
      # Pure predicate over caller-supplied text.
      {:violations, 1} => :system,
      {:violations, 2} => :system,
      {:anonymized?, 1} => :system,
      {:anonymized?, 2} => :system
    },
    CoopSubstrate.Harness.Fixtures => %{
      # Publishes predicate-passed (anonymized) bundles.
      {:publish, 7} => :system
    },
    CoopSubstrate.Harness.Synthesis => %{
      # Section-level compiled artifacts; the synthesis consent class covers
      # the verbatim finding bodies they carry (11 P2); anonymization applies
      # at fixtures (2D), not here.
      {:compile_model, 2} => :system,
      {:compile_model, 3} => :system,
      {:publish_model, 4} => :system,
      {:compile_spec, 2} => :system,
      {:publish_spec, 3} => :system
    },
    CoopSubstrate.Harness.Instrument => %{
      # Instrument trees are commons content.
      {:validate, 1} => :system,
      {:hash, 1} => :system,
      {:publish, 4} => :system,
      {:fetch, 3} => :system,
      {:diff, 2} => :system,
      {:seed_d, 0} => :system
    },
    CoopSubstrate.Export => %{
      # The member-departure bundle (6B): the subject's own streams only.
      {:member_bundle, 2} => :own_data,
      # Pure offline verification over a caller-supplied bundle.
      {:verify, 1} => :system
    },
    Finance => %{
      {:netting, 2} => :bilateral,
      {:netting, 3} => :bilateral,
      # netting's pure core, exposed for property tests — same data class.
      {:compute, 3} => :bilateral
    },
    Privacy.Aggregate => %{
      {:sum, 1} => :aggregate,
      # Mechanism metadata (Phase 6A): what the seam runs on, never member data.
      {:descriptor, 0} => :system
    },
    Privacy.Proof => %{
      # A member proves facts about their own standing...
      {:prove, 1} => :own_data,
      {:prove, 2} => :own_data,
      # ...and anyone may verify: one boolean crosses the boundary, no detail.
      {:verify, 2} => :system,
      {:descriptor, 0} => :system
    },
    Privacy.JointCompute => %{
      {:descriptor, 0} => :system
    }
  }

  @classes [:own_data, :bilateral, :aggregate, :system]

  test "every public query function is classified; no other class exists" do
    for {module, classified} <- @surface do
      public = module.__info__(:functions)

      unclassified = public -- Map.keys(classified)
      stale = Map.keys(classified) -- public

      assert unclassified == [],
             "#{inspect(module)} exports unclassified functions #{inspect(unclassified)} — " <>
               "classify them here (own_data | bilateral | aggregate | system) before shipping"

      assert stale == [], "#{inspect(module)} classification is stale: #{inspect(stale)}"
      assert Enum.all?(Map.values(classified), &(&1 in @classes))
    end
  end

  test "aggregate paths return bare totals; bilateral paths only the pair's positions" do
    steward = new_member("steward")
    member = new_member("member")
    :ok = seed_membership!(steward, member, "M-ada", "E-carrier-1")

    {:ok, _} =
      Log.append(
        signed_event(steward, "SinkingFundContributed", %{
          "entity_id" => "E-carrier-1",
          "amount_minor" => 500
        })
      )

    # Aggregates: a single integer crosses the boundary, never a breakdown.
    assert {:ok, total} = Capital.sinking_fund_total("chapter-genesis")
    assert is_integer(total)

    assert {:ok, system} = Throughput.system_value("chapter-genesis", {0, 1})
    assert is_integer(system)

    # Bilateral: the report's shape is closed — pair positions only.
    bob = new_member("member")
    {:ok, _} = Log.append(signed_event(bob, "MemberRegistered", registration_payload("M-bob", bob)))

    as_role = fn actor, role -> %{actor | signer: %{actor.signer | role: role}} end

    {:ok, _} =
      Log.append(
        multi_signed_event([as_role.(member, "debtor"), as_role.(bob, "creditor")],
          "ObligationRecorded",
          %{
            "obligation_id" => "OB-1",
            "debtor_id" => "M-ada",
            "creditor_id" => "M-bob",
            "amount_minor" => 100,
            "denomination" => "USD"
          }
        )
      )

    assert {:ok, [report]} = Finance.netting("chapter-genesis", {"M-ada", "M-bob"})
    assert Enum.sort(Map.keys(report)) == [:a_to_b, :b_to_a, :denomination, :net, :setoff]

    # A third party's netting view of themselves against Ada contains none of
    # the Ada↔Bob relationship.
    assert {:ok, []} = Finance.netting("chapter-genesis", {"M-ada", "M-carol"})
  end
end
