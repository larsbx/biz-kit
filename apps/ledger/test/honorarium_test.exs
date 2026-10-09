defmodule CoopSubstrate.HonorariumTest do
  @moduledoc """
  The honorarium rail (docs/honorarium_rail.md): payout unrepresentable
  before counsel clearance and after its withdrawal; over-attestation
  rejected at the exact boundary; the tracker is a fold; accrual and payout
  survive consent revocation (participation happened).
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Harness
  alias CoopSubstrate.Log

  @chapter "chapter-genesis"

  setup do
    steward = new_member("steward")
    author = new_member("author")
    alice = new_member("interviewee")

    {:ok, _} =
      Log.append(
        signed_event(alice, "InterviewConsentGranted", %{
          "interviewee_ref" => "IV-1",
          "pubkey" => {:bytes, alice.signer.pubkey},
          "key_id" => alice.signer.key_id,
          "classes" => ["synthesis"],
          "recording" => false
        })
      )

    %{steward: steward, author: author, alice: alice}
  end

  defp accrue(steward, ref, amount) do
    signed_event(steward, "HonorariumAccrued", %{
      "interviewee_ref" => ref,
      "amount_minor" => amount
    })
  end

  defp pay(steward, ref, amount) do
    signed_event(steward, "HonorariumPaid", %{
      "interviewee_ref" => ref,
      "amount_minor" => amount
    })
  end

  defp clearance!(author, value) do
    {:ok, _} =
      Log.append(
        signed_event(author, "CharterConstantDeclared", %{
          "name" => "honorarium/payout_cleared",
          "value" => value,
          "note" => "counsel ref [TEST]"
        })
      )
  end

  defp assert_rejected(envelope, expected_reason) do
    assert {:error, {:reject, _i, reason}} = Log.append(envelope)
    assert reason == expected_reason
  end

  test "payout is gated on clearance, reversible; over-attestation unrepresentable", ctx do
    {:ok, _} = Log.append(accrue(ctx.steward, "IV-1", 5_000))

    # Before clearance: unrepresentable.
    assert_rejected(pay(ctx.steward, "IV-1", 5_000), :payout_not_cleared)

    clearance!(ctx.author, 1)

    # Never-accrued ref and non-positive amounts still rejected.
    assert_rejected(pay(ctx.steward, "IV-404", 100), {:nothing_accrued, "IV-404"})
    assert_rejected(pay(ctx.steward, "IV-1", 0), :amount_must_be_positive)

    # The exact boundary: 5_001 over a 5_000 accrual rejected, 5_000 lands.
    assert_rejected(pay(ctx.steward, "IV-1", 5_001), {:overpayment, "IV-1", 5_000})
    {:ok, _} = Log.append(pay(ctx.steward, "IV-1", 3_000))
    assert_rejected(pay(ctx.steward, "IV-1", 2_001), {:overpayment, "IV-1", 2_000})
    {:ok, _} = Log.append(pay(ctx.steward, "IV-1", 2_000))
    assert_rejected(pay(ctx.steward, "IV-1", 1), {:overpayment, "IV-1", 0})

    # Withdrawing clearance stops payouts again (latest declaration wins).
    {:ok, _} = Log.append(accrue(ctx.steward, "IV-1", 1_000))
    clearance!(ctx.author, 0)
    assert_rejected(pay(ctx.steward, "IV-1", 1_000), :payout_not_cleared)
    assert :ok = Log.verify_chains()
  end

  test "the tracker is a fold: accrued/paid/outstanding, as_of-reproducible", ctx do
    clearance!(ctx.author, 1)
    {:ok, _} = Log.append(accrue(ctx.steward, "IV-1", 5_000))
    {:ok, [mid]} = Log.append(accrue(ctx.steward, "IV-1", 2_500))
    {:ok, _} = Log.append(pay(ctx.steward, "IV-1", 3_000))

    assert {:ok,
            [%{interviewee_ref: "IV-1", accrued_minor: 7_500, paid_minor: 3_000, outstanding_minor: 4_500}]} =
             Harness.honoraria(@chapter)

    assert {:ok, [%{accrued_minor: 7_500, paid_minor: 0, outstanding_minor: 7_500}]} =
             Harness.honoraria(@chapter, as_of: mid.global_seq)
  end

  test "accrual and payout survive consent revocation — participation happened", ctx do
    clearance!(ctx.author, 1)
    {:ok, _} = Log.append(accrue(ctx.steward, "IV-1", 5_000))

    {:ok, _} =
      Log.append(
        signed_event(ctx.alice, "InterviewConsentRevoked", %{"interviewee_ref" => "IV-1"})
      )

    {:ok, _} = Log.append(accrue(ctx.steward, "IV-1", 500))
    {:ok, _} = Log.append(pay(ctx.steward, "IV-1", 5_500))

    assert {:ok, [%{outstanding_minor: 0}]} = Harness.honoraria(@chapter)
  end

  test "task subcommands: accrue, clear, paid, list" do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    {:ok, _} = CoopSubstrate.Harness.Ops.gen_key("steward")
    {:ok, _} = CoopSubstrate.Harness.Ops.gen_key("governance")
    dir = Application.fetch_env!(:coop_substrate, :harness_keys_dir)
    on_exit(fn -> File.rm_rf(dir) end)

    dana = new_member("interviewee")

    {:ok, _} =
      Log.append(
        signed_event(dana, "InterviewConsentGranted", %{
          "interviewee_ref" => "IV-9",
          "pubkey" => {:bytes, dana.signer.pubkey},
          "key_id" => dana.signer.key_id,
          "classes" => ["synthesis"],
          "recording" => false
        })
      )

    Mix.Tasks.Harness.Honorarium.run(["accrue", "--interviewee", "IV-9", "--amount", "5000"])
    assert_received {:mix_shell, :info, ["event=" <> _]}

    # Payout before clearance: the task prints the gate's term and raises.
    assert_raise Mix.Error, fn ->
      Mix.Tasks.Harness.Honorarium.run(["paid", "--interviewee", "IV-9", "--amount", "5000"])
    end

    assert_received {:mix_shell, :error, ["REJECTED: {:reject, 0, :payout_not_cleared}"]}

    Mix.Tasks.Harness.Honorarium.run(["clear", "1", "--note", "counsel ref X", "--yes"])
    assert_received {:mix_shell, :info, ["event=" <> _]}

    Mix.Tasks.Harness.Honorarium.run([
      "paid", "--interviewee", "IV-9", "--amount", "5000", "--note", "cash, receipt #12"
    ])

    assert_received {:mix_shell, :info, ["event=" <> _]}

    Mix.Tasks.Harness.Honorarium.run(["list"])
    assert_received {:mix_shell, :info, ["interviewee=IV-9 accrued=5000 paid=5000 outstanding=0"]}
  end
end
