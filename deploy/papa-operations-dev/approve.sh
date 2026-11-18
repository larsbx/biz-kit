#!/usr/bin/env bash
# Approve a device / administrator enrolment on the bizops-dev ledger with the
# genesis governance seed (the bootstrap step; later approvals happen in the
# view). Without --yes it only shows the request.
#   ~/ops/bizops-dev/approve.sh ABCD-EFGH-JKLM [--yes]
set -euo pipefail
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ] || [ -z "$1" ] ||
  { [ "$#" -eq 2 ] && [ "$2" != --yes ]; }; then
  echo 'Usage: approve.sh CODE [--yes]' >&2
  exit 2
fi
code=$1
approve=no
if [ "${2:-}" = --yes ]; then
  approve=yes
fi
base=$HOME/ops/bizops-dev
expr='
alias CoopSubstrate.Enrolments.Approver
alias CoopSubstrate.Harness.Ops
:inets.start(); :ssl.start()
base = "http://127.0.0.1:4001"
d =
  case Approver.fetch(base, System.fetch_env!("CODE")) do
    {:ok, details} -> details
    {:error, reason} ->
      IO.puts(:stderr, "Could not fetch enrolment request: #{inspect(reason)}")
      System.halt(1)
  end
{:ok, signer} = Ops.load_signer("governance")
IO.puts("request #{d["code"]}: role=#{d["role"]} principal=#{d["principal_id"]} signed_in=#{d["identity"]["subject"]}@#{d["identity"]["issuer"]}")
IO.puts("  project #{d["chapter_id"]} / #{d["tenant_id"]} / #{d["project_id"]}  device #{d["label"]} (#{d["key_id"]})  governance #{signer.key_id}")
if System.get_env("APPROVE") == "yes" do
  case Approver.approve(base, d, signer) do
    {:ok, result} -> IO.inspect(result, label: "approved")
    {:error, reason} ->
      IO.puts(:stderr, "Approval failed: #{inspect(reason)}")
      System.halt(1)
  end
else
  IO.puts("not approved (pass --yes)")
end
'
systemd-run --user --wait --pipe --quiet \
  -p EnvironmentFile="$base/env" -p WorkingDirectory="$base/state" \
  --setenv=CODE="$code" --setenv=APPROVE="$approve" \
  "$base/release/bin/orchestration" eval "$expr"
