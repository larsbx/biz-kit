#!/usr/bin/env bash
# Approve a device / administrator enrolment on the bizops-dev ledger with the
# genesis governance seed (the bootstrap step; later approvals happen in the
# view). Without --yes it only shows the request.
#   ~/ops/bizops-dev/approve.sh ABCD-EFGH-JKLM [--yes]
set -euo pipefail
code=${1:?usage: approve.sh CODE [--yes]}
yes=${2:-}
base=$HOME/ops/bizops-dev
expr='
alias CoopSubstrate.Enrolments.Approver
alias CoopSubstrate.Harness.Ops
:inets.start(); :ssl.start()
base = "http://127.0.0.1:4001"
{:ok, signer} = Ops.load_signer("governance")
{:ok, d} = Approver.fetch(base, System.get_env("CODE"))
IO.puts("request #{d["code"]}: role=#{d["role"]} principal=#{d["principal_id"]} signed_in=#{d["identity"]["subject"]}@#{d["identity"]["issuer"]}")
IO.puts("  project #{d["chapter_id"]} / #{d["tenant_id"]} / #{d["project_id"]}  device #{d["label"]} (#{d["key_id"]})  governance #{signer.key_id}")
if System.get_env("APPROVE") == "yes" do
  IO.inspect(Approver.approve(base, d, signer), label: "approve")
else
  IO.puts("not approved (pass --yes)")
end
'
systemd-run --user --wait --pipe --quiet \
  -p EnvironmentFile="$base/env" -p WorkingDirectory="$base/state" \
  --setenv=CODE="$code" --setenv=APPROVE="$([ "$yes" = --yes ] && echo yes || echo no)" \
  "$base/release/bin/orchestration" eval "$expr"
