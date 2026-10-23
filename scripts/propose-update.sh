#!/usr/bin/env bash
# Opens a pull request for what a refresh job changed in the working tree,
# once per branch: a branch that has (or had) a pull request is left alone,
# and one pushed earlier without a pull request gets one now.
#
#   scripts/propose-update.sh BRANCH TITLE BODY
#
# The pull request targets BASE, by default the repository's default branch.
# GH_TOKEN opens the pull request. Changes pushed and opened with the default
# GITHUB_TOKEN do not start other workflows, so set the VENDOR_PR_TOKEN secret
# (a fine-grained token with contents and pull-requests write) for the pull
# request's own CI to run.

set -euo pipefail
cd "$(dirname "$0")/.."

branch=$1 title=$2 body=$3
git diff --quiet && git diff --cached --quiet && [ -z "$(git ls-files --others --exclude-standard)" ] && exit 0
if [ -n "$(gh pr list --head "$branch" --state all --json number --jq '.[].number')" ]; then
  echo "$branch is already proposed."
  exit 0
fi

# A push whose pull request failed to open (an API error, or Actions not yet
# allowed to open one) is not pushed again: only its pull request is missing.
if ! git ls-remote --exit-code --heads origin "$branch" >/dev/null; then
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git switch -c "$branch"
  git add -A
  git commit -m "$title" -m "$body"
  git push origin "$branch"
fi
gh pr create --base "${BASE:-$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)}" --head "$branch" --title "$title" --body "$body"
