#!/usr/bin/env bash
#
# Manage which public IPs may reach the Azure Terraform state blobs.
#
# Usage:
#   scripts/azure-state-firewall.sh status        allowed IPs, and whether yours is one
#   scripts/azure-state-firewall.sh allow         add your current public IP
#   scripts/azure-state-firewall.sh revoke [IP]   remove an IP (default: your current one)
#   scripts/azure-state-firewall.sh reset         allow ONLY your current public IP
#
# Needs:  az CLI (logged in), curl, and the azure/bootstrap state on this
#         machine (or STATE_ACCOUNT and STATE_RESOURCE_GROUP set).
# Env:    STATE_ACCOUNT, STATE_RESOURCE_GROUP override the bootstrap outputs.

# The firewall's default-Deny is enforced by Terraform. The allowlist is
# day-to-day state (home and office IPs change), so azure/bootstrap ignores
# it after creation and this script manages it. Changes go through the ARM
# control plane, which the storage firewall doesn't gate, so this works from
# a new network before its IP is allowed.

set -euo pipefail

log() { printf '==> %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# Print the header comment (lines 3-13) as help text.
usage() {
  sed -n '3,13s/^# \{0,1\}//p' "$0" >&2
  exit "${1:-1}"
}

[[ $# -ge 1 && $# -le 2 ]] || usage
[[ "$1" == "-h" || "$1" == "--help" ]] && usage 0

command -v az >/dev/null || die "az CLI not found"
command -v curl >/dev/null || die "curl not found"

# az on Windows (Git Bash) can end text output with \r.
az_text() { az "$@" --output tsv | tr -d '\r'; }

bootstrap_dir="$(cd "$(dirname "$0")/../azure/bootstrap" && pwd)"
bootstrap_output() {
  local value
  # Before the first apply, `terraform output -raw` prints nothing and still
  # exits 0, so check the value rather than the exit code.
  value="$(terraform -chdir="$bootstrap_dir" output -raw "$1" 2>/dev/null || true)"
  [[ -n "$value" ]] ||
    die "no '$1' output in azure/bootstrap; apply it first, or set STATE_ACCOUNT and STATE_RESOURCE_GROUP"
  echo "$value"
}

ACCOUNT="${STATE_ACCOUNT:-$(bootstrap_output storage_account_name)}"
RG="${STATE_RESOURCE_GROUP:-$(bootstrap_output resource_group_name)}"

my_ip() {
  local ip
  ip="$(curl -fsS --max-time 10 https://api.ipify.org)" || die "couldn't look up your public IP"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "unexpected public IP lookup result: '$ip'"
  echo "$ip"
}

allowed_ips() {
  az_text storage account network-rule list -g "$RG" --account-name "$ACCOUNT" \
    --query 'ipRules[].ipAddressOrRange'
}

is_allowed() { allowed_ips | grep -qxF "$1"; }

add_ip() {
  if is_allowed "$1"; then
    log "$1 is already allowed"
  else
    log "allowing $1 on ${ACCOUNT}"
    az storage account network-rule add -g "$RG" --account-name "$ACCOUNT" --ip-address "$1" --output none
  fi
}

remove_ip() {
  if is_allowed "$1"; then
    log "revoking $1 on ${ACCOUNT}"
    az storage account network-rule remove -g "$RG" --account-name "$ACCOUNT" --ip-address "$1" --output none
  else
    log "$1 isn't in the allowlist"
  fi
}

case "$1" in
  status)
    ip="$(my_ip)"
    default_action="$(az_text storage account show -g "$RG" -n "$ACCOUNT" --query networkRuleSet.defaultAction)"
    log "account:        ${ACCOUNT} (default action: ${default_action})"
    log "allowed IPs:    $(allowed_ips | paste -sd ' ' -)"
    if is_allowed "$ip"; then
      log "your IP ${ip} is allowed"
    else
      log "your IP ${ip} is NOT allowed; run: $0 allow"
      exit 2
    fi
    ;;
  allow)
    add_ip "$(my_ip)"
    ;;
  revoke)
    remove_ip "${2:-$(my_ip)}"
    ;;
  reset)
    ip="$(my_ip)"
    add_ip "$ip"
    for old in $(allowed_ips); do
      [[ "$old" == "$ip" ]] || remove_ip "$old"
    done
    ;;
  *)
    usage
    ;;
esac

# Storage firewall changes can take a short while to reach every front end.
# If terraform init still gets AuthorizationFailure, wait a minute and retry.
[[ "$1" == "status" ]] || log "done; allow a minute before retrying a 403"
