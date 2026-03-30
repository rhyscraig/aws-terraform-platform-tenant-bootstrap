#!/usr/bin/env bash
# tools/bootstrap-repo-secrets.sh
#
# Generic script that any repo can use to self-configure its GitHub secrets.
# Reads platform values from AWS SSM Parameter Store and sets them as
# GitHub environment secrets via the gh CLI.
#
# Prerequisites:
#   • aws CLI authenticated to the MANAGEMENT account (395101865577)
#   • gh CLI authenticated to GitHub (gh auth status)
#
# Usage:
#   # Bootstrap the current repo (auto-detects from git remote)
#   bash tools/bootstrap-repo-secrets.sh
#
#   # Bootstrap a specific repo + environment
#   REPO=rhyscraig/aws-terraform-solutions-terrorgem \
#   ENV_NAME=terrorgem-prd \
#     bash tools/bootstrap-repo-secrets.sh
#
# Idempotent — safe to re-run. Does not rotate PLAN_PASSPHRASE if it already exists.

set -euo pipefail

########################################
# RESOLVE REPO + ENVIRONMENT
########################################

# Auto-detect repo from git remote if not set
REPO="${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"
if [[ -z "$REPO" ]]; then
  echo "❌  Could not detect repo. Set REPO=owner/name or run from a git checkout."
  exit 1
fi

# Default environment name from the repo's short name (e.g. "terrorgem-prd" or "hoad-org")
ENV_NAME="${ENV_NAME:-hoad-org}"

echo "==> Bootstrapping: ${REPO} (environment: ${ENV_NAME})"

########################################
# PREFLIGHT CHECKS
########################################

for cmd in aws gh; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "❌  ${cmd} CLI not found"
    exit 1
  fi
done

# Verify AWS credentials are valid
CALLER=$(aws sts get-caller-identity --output json 2>&1) || {
  echo "❌  No valid AWS credentials. Authenticate to the management account first."
  exit 1
}
ACCOUNT=$(echo "$CALLER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])")
echo "✅  AWS account: ${ACCOUNT}"

# Verify gh CLI
gh auth status >/dev/null 2>&1 || {
  echo "❌  gh CLI not authenticated — run: gh auth login"
  exit 1
}
echo "✅  gh CLI authenticated"

########################################
# READ PLATFORM VALUES FROM SSM
########################################

ssm_get() {
  aws ssm get-parameter --name "$1" --query 'Parameter.Value' --output text 2>/dev/null
}

echo "==> Reading platform values from SSM..."

STATE_BUCKET=$(ssm_get "/platform/bootstrap/state-bucket") || {
  echo "❌  SSM parameter /platform/bootstrap/state-bucket not found."
  echo "    Has the tenant-bootstrap been applied?"
  exit 1
}

LOGS_BUCKET=$(ssm_get "/platform/bootstrap/logs-bucket")
KMS_KEY_ID=$(ssm_get "/platform/bootstrap/kms-key-id")
SEED_ROLE_ARN=$(ssm_get "/platform/bootstrap/seed-role-arn")

echo "✅  State bucket:  ${STATE_BUCKET}"
echo "✅  Logs bucket:   ${LOGS_BUCKET}"
echo "✅  KMS key ID:    ${KMS_KEY_ID}"
echo "✅  Seed role ARN: ${SEED_ROLE_ARN}"

########################################
# CREATE GITHUB ENVIRONMENTS
########################################

echo ""
echo "==> Creating GitHub environment: ${ENV_NAME}"
gh api \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  "/repos/${REPO}/environments/${ENV_NAME}" \
  >/dev/null

APPROVE_ENV_NAME="${ENV_NAME}-approve"
echo "==> Creating approval environment: ${APPROVE_ENV_NAME}"
gh api \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  "/repos/${REPO}/environments/${APPROVE_ENV_NAME}" \
  >/dev/null

########################################
# SET SECRETS
########################################

set_secret() {
  local name="$1"
  local value="$2"
  echo "    Setting ${name}..."
  gh secret set "$name" --env "$ENV_NAME" --repo "$REPO" --body "$value" >/dev/null
}

echo "==> Setting secrets in ${ENV_NAME}..."
set_secret "SEED_ROLE_ARN"   "${SEED_ROLE_ARN}"
set_secret "TF_STATE_BUCKET" "${STATE_BUCKET}"
set_secret "TF_LOGS_BUCKET"  "${LOGS_BUCKET}"
set_secret "KMS_KEY_ID"      "${KMS_KEY_ID}"

# Generate PLAN_PASSPHRASE only if it doesn't already exist
EXISTING_SECRETS=$(gh api "repos/${REPO}/environments/${ENV_NAME}/secrets" \
  --jq '[.secrets[].name]' 2>/dev/null || echo "[]")

if echo "$EXISTING_SECRETS" | grep -q '"PLAN_PASSPHRASE"'; then
  echo "    PLAN_PASSPHRASE already exists — not rotating"
else
  PLAN_PASSPHRASE="$(openssl rand -base64 32)"
  set_secret "PLAN_PASSPHRASE" "${PLAN_PASSPHRASE}"
fi

########################################
# SUMMARY
########################################

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  ✅  GitHub environments ready for ${REPO}"
echo ""
echo "  ${ENV_NAME}  →  secrets:"
echo "    SEED_ROLE_ARN, TF_STATE_BUCKET, TF_LOGS_BUCKET, KMS_KEY_ID, PLAN_PASSPHRASE"
echo ""
echo "  ${APPROVE_ENV_NAME}  →  approval gate (no secrets)"
echo ""
echo "  Next steps:"
echo "    1. Ensure your repo's deploy.yaml uses shared workflows"
echo "    2. Push to main to trigger the pipeline"
echo "════════════════════════════════════════════════════════════"
