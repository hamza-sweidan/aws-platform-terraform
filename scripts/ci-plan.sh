#!/usr/bin/env bash
#
# Run a speculative terraform plan in CI and publish a redacted summary.
#
# Usage (from a root module directory, after terraform init):
#   scripts/ci-plan.sh "<title>"
#
# The plan runs with -lock=false (CI identities are read-only), and its full
# output stays in a local file: in a public repository it would expose
# account IDs, ARNs and subscription IDs. Only the "Plan: ..." line and each
# changed resource's address and action go into $GITHUB_STEP_SUMMARY.
# Needs: terraform, jq.

set -euo pipefail

title="${1:?usage: ci-plan.sh <title>}"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

# -detailed-exitcode: 0 = no changes, 1 = error, 2 = changes present.
set +e
terraform plan -lock=false -input=false -no-color -detailed-exitcode -out=tfplan >plan.log 2>&1
rc=$?
set -e

if [[ $rc -eq 1 ]]; then
  echo "::error::terraform plan failed for ${title}"
  # Error blocks only, not the whole log.
  grep -A4 -E '^Error' plan.log | head -40 >&2 || true
  # shellcheck disable=SC2016 # the backticks are Markdown, not a command substitution
  printf '### %s\n\n:x: `terraform plan` failed. The error is in the job log.\n' "$title" >>"$summary"
  rm -f tfplan plan.log
  exit 1
fi

result="$(grep -E '^(Plan:|No changes\.)' plan.log | head -1)"

{
  printf '### %s\n\n**%s**\n' "$title" "${result:-No changes.}"
  if [[ $rc -eq 2 ]]; then
    printf '\n| Action | Resource |\n|---|---|\n'
    terraform show -json tfplan | jq -r '
      .resource_changes[]
      | select(.change.actions != ["no-op"] and .change.actions != ["read"])
      | "| \(.change.actions | join(" + ")) | `\(.address)` |"'
  fi
} >>"$summary"

rm -f tfplan plan.log
