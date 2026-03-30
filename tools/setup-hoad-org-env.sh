#!/usr/bin/env bash
# tools/setup-hoad-org-env.sh
#
# Populates the 'hoad-org' and 'hoad-org-approve' GitHub environments with the
# secrets needed to run the terraform-hoad-org.yml pipeline.
#
# Run from your LOCAL terminal (not CloudShell) where:
#   • aws CLI is authenticated to the MANAGEMENT account (395101865577)
#   • gh CLI is authenticated to GitHub (gh auth status)
#
# Usage:
#   bash tools/setup-hoad-org-env.sh
#
# Idempotent — safe to re-run.

set -euo pipefail

REPO="rhyscraig/aws-terraform-platform-tenant-bootstrap"
ENV_NAME="hoad-org"
APPROVE_ENV_NAME="hoad-org-approve"
EXPECTED_ACCOUNT="395101865577"
KMS_ALIAS="alias/terrorgem-cmc-euw2-platform-tfstate"

# ── Preflight ─────────────────────────────────────────────────────────────────

echo "==> Checking prerequisites..."

if ! command -v aws >/dev/null 2>&1; then
  echo "❌  aws CLI not found"
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "❌  gh CLI not found"
  exit 1
fi

# Verify we're in the management account
CALLER=$(aws sts get-caller-identity --output json 2>&1) || {
  echo "❌  No AWS credentials found — configure credentials for account ${EXPECTED_ACCOUNT}"
  exit 1
}
ACTUAL_ACCOUNT=$(echo "$CALLER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])")
if [ "$ACTUAL_ACCOUNT" != "$EXPECTED_ACCOUNT" ]; then
  echo "❌  Wrong account: got ${ACTUAL_ACCOUNT}, need ${EXPECTED_ACCOUNT} (management)"
  exit 1
fi
echo "✅  Management account: ${ACTUAL_ACCOUNT}"

# Verify gh CLI is authenticated
gh auth status >/dev/null 2>&1 || {
  echo "❌  gh CLI not authenticated — run: gh auth login"
  exit 1
}
echo "✅  gh CLI authenticated"

# ── Derive secret values ──────────────────────────────────────────────────────

echo "==> Fetching KMS key ID from alias ${KMS_ALIAS}..."
KMS_KEY_ID=$(aws kms list-aliases \
  --query "Aliases[?AliasName=='${KMS_ALIAS}'].TargetKeyId | [0]" \
  --output text 2>&1) || {
  echo "❌  Could not list KMS aliases — check permissions"
  exit 1
}

if [ -z "$KMS_KEY_ID" ] || [ "$KMS_KEY_ID" = "None" ]; then
  echo "❌  KMS alias '${KMS_ALIAS}' not found in account ${ACTUAL_ACCOUNT}"
  echo "    Has the bootstrap cloudshell script been run for this account?"
  exit 1
fi
echo "✅  KMS key ID: ${KMS_KEY_ID}"

SEED_ROLE_ARN="arn:aws:iam::${ACTUAL_ACCOUNT}:role/terrorgem-cmc-euw2-platform-oidc-role"
TF_STATE_BUCKET="terrorgem-cmc-euw2-platform-tfstate-prd"
TF_LOGS_BUCKET="terrorgem-cmc-euw2-platform-logs-prd"
PLAN_PASSPHRASE="$(openssl rand -base64 32)"

# Check if PLAN_PASSPHRASE already exists (don't rotate it unnecessarily)
EXISTING_SECRETS=$(gh api "repos/${REPO}/environments/${ENV_NAME}/secrets" \
  --jq '[.secrets[].name]' 2>/dev/null || echo "[]")
if echo "$EXISTING_SECRETS" | grep -q '"PLAN_PASSPHRASE"'; then
  echo "ℹ️   PLAN_PASSPHRASE already exists — not rotating (delete it manually to regenerate)"
  ROTATE_PASSPHRASE="false"
else
  ROTATE_PASSPHRASE="true"
fi

# ── Create / update environments ──────────────────────────────────────────────

echo ""
echo "==> Creating environment: ${ENV_NAME}..."
gh api \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  "/repos/${REPO}/environments/${ENV_NAME}" \
  >/dev/null

echo "==> Creating approval environment: ${APPROVE_ENV_NAME}..."
gh api \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  "/repos/${REPO}/environments/${APPROVE_ENV_NAME}" \
  >/dev/null

# ── Set secrets ───────────────────────────────────────────────────────────────

set_secret() {
  local name="$1"
  local value="$2"
  echo "    Setting ${name}..."
  gh secret set "$name" --env "$ENV_NAME" --repo "$REPO" --body "$value" >/dev/null
}

echo "==> Setting secrets in ${ENV_NAME}..."
set_secret "SEED_ROLE_ARN"   "${SEED_ROLE_ARN}"
set_secret "TF_STATE_BUCKET" "${TF_STATE_BUCKET}"
set_secret "TF_LOGS_BUCKET"  "${TF_LOGS_BUCKET}"
set_secret "KMS_KEY_ID"      "${KMS_KEY_ID}"

if [ "$ROTATE_PASSPHRASE" = "true" ]; then
  set_secret "PLAN_PASSPHRASE" "${PLAN_PASSPHRASE}"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  ✅  GitHub environments ready"
echo ""
echo "  ${ENV_NAME}  →  secrets:"
echo "    SEED_ROLE_ARN   = ${SEED_ROLE_ARN}"
echo "    TF_STATE_BUCKET = ${TF_STATE_BUCKET}"
echo "    TF_LOGS_BUCKET  = ${TF_LOGS_BUCKET}"
echo "    KMS_KEY_ID      = ${KMS_KEY_ID}"
echo "    PLAN_PASSPHRASE = (set)"
echo ""
echo "  ${APPROVE_ENV_NAME}  →  no secrets (approval gate only)"
echo ""
echo "  Next: push any change to main branch of:"
echo "  https://github.com/${REPO}"
echo "  to trigger the terraform-hoad-org.yml pipeline."
echo "════════════════════════════════════════════════════════════"
