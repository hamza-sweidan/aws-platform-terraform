#!/usr/bin/env bash
#
# Mirror a public container image into private ECR, so the zero-egress EKS
# cluster can pull it through the ECR VPC endpoints.
#
# Usage:
#   scripts/mirror-image.sh <source-image:tag> [ecr-repository] [region]
#
# Examples:
#   scripts/mirror-image.sh docker.io/nginxinc/nginx-unprivileged:1.30-alpine
#   IMAGE=$(scripts/mirror-image.sh docker.io/nginxinc/nginx-unprivileged:1.30-alpine mirror/nginx-unprivileged)
#
# Output: the digest-pinned reference (<registry>/<repo>@sha256:...) on stdout.
#         Progress goes to stderr, so $(...) captures only the reference.
# Needs:  aws CLI v2, and crane (preferred) or skopeo. Run from a machine
#         with internet access (your laptop), not from inside the VPC.
# Env:    PLATFORM (default linux/amd64, matching the AL2023 x86_64 nodes)

set -euo pipefail

log() { printf '==> %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# Print the header comment (lines 3-17) as help text.
usage() {
  sed -n '3,17s/^# \{0,1\}//p' "$0" >&2
  exit "${1:-1}"
}

# The aws CLI on Windows (Git Bash) can end text output with \r.
aws_text() { aws "$@" --output text | tr -d '\r'; }

[[ $# -ge 1 && $# -le 3 ]] || usage
[[ "$1" == "-h" || "$1" == "--help" ]] && usage 0

SRC="$1"
REPO="${2:-}"
REGION="${3:-${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-central-1}}}"
PLATFORM="${PLATFORM:-linux/amd64}"

# --- Validate the source reference ------------------------------------------
[[ "$SRC" != *@* ]] || die "pass a tagged reference (repo:tag); the script pins the digest for you"
last_segment="${SRC##*/}"
[[ "$last_segment" == *:* ]] || die "source image needs an explicit tag, e.g. nginx:1.30-alpine"
TAG="${last_segment##*:}"
[[ "$TAG" != "latest" ]] || die "refusing ':latest'. Mirror a versioned tag so the mirror is reproducible"

# Default repository: mirror/<image name>, e.g. mirror/nginx-unprivileged
if [[ -z "$REPO" ]]; then
  REPO="mirror/${last_segment%%:*}"
fi

# --- Pick a copy tool ------------------------------------------------------
command -v aws >/dev/null || die "aws CLI not found"
if command -v crane >/dev/null; then
  TOOL=crane
elif command -v skopeo >/dev/null; then
  TOOL=skopeo
else
  die "install crane (github.com/google/go-containerregistry) or skopeo"
fi

ACCOUNT_ID="$(aws_text sts get-caller-identity --query Account)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
DEST="${REGISTRY}/${REPO}:${TAG}"

log "source:      ${SRC} (${PLATFORM})"
log "destination: ${DEST} (using ${TOOL})"

# Repositories are created by Terraform (envs/dev ecr_repositories), not here,
# so their settings (immutability, scanning, encryption) stay in code.
aws ecr describe-repositories --region "$REGION" --repository-names "$REPO" >/dev/null 2>&1 ||
  die "ECR repository '${REPO}' doesn't exist in ${REGION}; add it to ecr_repositories in envs/dev"

# Tags are immutable. If this tag was mirrored before, return its digest
# instead of failing on the push.
existing="$(aws_text ecr describe-images --region "$REGION" --repository-name "$REPO" \
  --image-ids imageTag="$TAG" --query 'imageDetails[0].imageDigest' 2>/dev/null || true)"
if [[ -n "$existing" && "$existing" != "None" ]]; then
  log "tag ${TAG} is already in ECR; reusing it"
  echo "${REGISTRY}/${REPO}@${existing}"
  exit 0
fi

# --- Copy ------------------------------------------------------------------
# Single platform on purpose: a multi-arch index stores each architecture as
# an untagged image in ECR, and a lifecycle rule could expire them and break
# the tag. The platform manifest is copied byte for byte, so its digest
# matches upstream and can be verified against the source registry.
log "authenticating to ${REGISTRY}"
case "$TOOL" in
  crane)
    aws ecr get-login-password --region "$REGION" |
      crane auth login "$REGISTRY" --username AWS --password-stdin >&2
    crane copy --platform "$PLATFORM" "$SRC" "$DEST" >&2
    ;;
  skopeo)
    aws ecr get-login-password --region "$REGION" |
      skopeo login --username AWS --password-stdin "$REGISTRY" >&2
    skopeo copy --preserve-digests \
      --override-os "${PLATFORM%%/*}" --override-arch "${PLATFORM##*/}" \
      "docker://${SRC}" "docker://${DEST}" >&2
    ;;
esac

# Ask ECR, not the copy tool, what it stored under the tag.
DIGEST="$(aws_text ecr describe-images --region "$REGION" --repository-name "$REPO" \
  --image-ids imageTag="$TAG" --query 'imageDetails[0].imageDigest')"
[[ "$DIGEST" == sha256:* ]] || die "could not read the pushed digest from ECR"

log "done: ${SRC} -> ${REGISTRY}/${REPO}@${DIGEST}"
echo "${REGISTRY}/${REPO}@${DIGEST}"
