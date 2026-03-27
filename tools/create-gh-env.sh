#!/usr/bin/env bash
set -euo pipefail

########################################
# AUTO GENERATE PLAN PASSPHRASE
########################################

if [[ -z "${PLAN_PASSPHRASE:-}" ]]; then
  echo "[INFO] Generating PLAN_PASSPHRASE"
  PLAN_PASSPHRASE="$(openssl rand -base64 32)"
  export PLAN_PASSPHRASE
fi

########################################
# INPUT
########################################

TFVARS_FILE="${TFVARS_FILE:-}"

if [[ -z "${TFVARS_FILE}" ]]; then
  echo "[ERROR] TFVARS_FILE not set"
  exit 1
fi

if [[ ! -f "${TFVARS_FILE}" ]]; then
  echo "[ERROR] tfvars not found: ${TFVARS_FILE}"
  exit 1
fi

########################################
# PARSE TFVARS (SINGLE SOURCE OF TRUTH)
########################################

get_var() {
  local key="$1"
  awk -F= -v k="$key" '
    $1 ~ "^[[:space:]]*"k"[[:space:]]*$" {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
      gsub(/^"|"$/, "", $2)
      print $2
      exit
    }
  ' "$TFVARS_FILE"
}

ORG="$(get_var org)"
ENVIRONMENT="$(get_var environment)"
PARTITION="$(get_var partition)"
AWS_REGION="$(get_var aws_region)"

if [[ -z "$ORG" || -z "$ENVIRONMENT" || -z "$PARTITION" || -z "$AWS_REGION" ]]; then
  echo "[ERROR] Missing required values in tfvars"
  exit 1
fi

########################################
# DERIVED VALUES (MINIMAL, NO DUPLICATION)
########################################

TFVARS_BASENAME="$(basename "${TFVARS_FILE}" .tfvars)"
ENV_NAME="${TFVARS_BASENAME}"

########################################
# CHECK GH CLI
########################################

if ! command -v gh >/dev/null 2>&1; then
  echo "[ERROR] GitHub CLI (gh) not installed"
  exit 1
fi

########################################
# CREATE ENVIRONMENT
########################################

echo "[INFO] Creating GitHub environment: ${ENV_NAME}"

gh api \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  "/repos/$(gh repo view --json nameWithOwner -q .nameWithOwner)/environments/${ENV_NAME}" \
  >/dev/null

########################################
# SET SECRETS
########################################

required_vars=(
  SEED_ROLE_ARN
  TF_STATE_BUCKET
  TF_LOGS_BUCKET
  KMS_KEY_ID
  PLAN_PASSPHRASE
)

for v in "${required_vars[@]}"; do
  if [[ -z "${!v:-}" ]]; then
    echo "[ERROR] Missing required env var: $v"
    exit 1
  fi
done

set_secret() {
  local name="$1"
  local value="$2"

  if [[ -z "$value" ]]; then
    echo "[WARN] Skipping empty secret: $name"
    return
  fi

  echo "[INFO] Setting secret: $name"

  gh secret set "$name" \
    --env "$ENV_NAME" \
    --body "$value" >/dev/null
}

########################################
# REQUIRED SECRETS (FROM ENV)
########################################

set_secret "SEED_ROLE_ARN"    "${SEED_ROLE_ARN:-}"
set_secret "TF_STATE_BUCKET"  "${TF_STATE_BUCKET:-}"
set_secret "TF_LOGS_BUCKET"   "${TF_LOGS_BUCKET:-}"
set_secret "KMS_KEY_ID"       "${KMS_KEY_ID:-}"
set_secret "PLAN_PASSPHRASE"  "${PLAN_PASSPHRASE:-}"

# ORG_GITHUB_TOKEN — sourced from local GITHUB_TOKEN (same token used during bootstrap).
# Used by the pipeline to configure git for private Terraform module downloads.
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  set_secret "ORG_GITHUB_TOKEN" "${GITHUB_TOKEN}"
else
  echo "[WARN] GITHUB_TOKEN not set in local env — ORG_GITHUB_TOKEN was not created"
  echo "[WARN] Add it manually: GitHub → Settings → Environments → ${ENV_NAME} → Add secret"
fi

########################################
# CREATE APPROVAL GATE ENVIRONMENT  ({org}-approve)
#
# Why a second environment?
#   The plan job uses the secrets environment so it can run immediately.
#   Putting an approval gate on the same environment would block the plan
#   itself — approvers would be approving blind before seeing any plan output.
#   The separate -approve environment gates only the step between plan and apply.
########################################

APPROVE_ENV_NAME="${ENV_NAME}-approve"
REPO_NWO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
REPO_OWNER="${REPO_NWO%%/*}"

# Parse github_approver_teams list from tfvars
# Handles:  github_approver_teams = ["team-a", "team-b"]
RAW_TEAMS="$(awk -F'=' '/^[[:space:]]*github_approver_teams[[:space:]]*=/{
  sub(/.*=/, ""); gsub(/[\[\]" \t]/, ""); gsub(/,/, "\n"); print
}' "$TFVARS_FILE" | grep -v '^$' || true)"

if [[ -z "$RAW_TEAMS" ]]; then
  echo "[WARN] github_approver_teams not set — creating ${APPROVE_ENV_NAME} with no reviewers"
  gh api --method PUT \
    -H "Accept: application/vnd.github+json" \
    "/repos/${REPO_NWO}/environments/${APPROVE_ENV_NAME}" >/dev/null
else
  echo "[INFO] Creating approval environment: ${APPROVE_ENV_NAME}"

  # Build reviewers JSON array from team slugs
  REVIEWERS_JSON="["
  SEP=""
  while IFS= read -r TEAM_SLUG; do
    [[ -z "$TEAM_SLUG" ]] && continue
    TEAM_ID="$(gh api "orgs/${REPO_OWNER}/teams" \
      --jq ".[] | select(.slug == \"${TEAM_SLUG}\") | .id" 2>/dev/null || true)"
    if [[ -z "$TEAM_ID" ]]; then
      echo "[WARN]   Team not found: ${TEAM_SLUG} — skipping"
      continue
    fi
    echo "[INFO]   Reviewer: ${TEAM_SLUG} (id=${TEAM_ID})"
    REVIEWERS_JSON+="${SEP}{\"type\":\"Team\",\"id\":${TEAM_ID}}"
    SEP=","
  done <<< "$RAW_TEAMS"
  REVIEWERS_JSON+="]"

  # GitHub environments API requires reviewers nested under the JSON body
  printf '{"prevent_self_review":false,"reviewers":%s}' "$REVIEWERS_JSON" \
    | gh api --method PUT \
        -H "Accept: application/vnd.github+json" \
        "/repos/${REPO_NWO}/environments/${APPROVE_ENV_NAME}" \
        --input - >/dev/null
fi

########################################
# INFO OUTPUT
########################################

echo ""
echo "✅ GitHub environments ready"
echo "----------------------------------------"
echo "  ${ENV_NAME}  (secrets — no approval gate)"
echo "    Org:       ${ORG}"
echo "    Partition: ${PARTITION}"
echo "    Region:    ${AWS_REGION}"
echo "    Secrets:   SEED_ROLE_ARN, TF_STATE_BUCKET, TF_LOGS_BUCKET, KMS_KEY_ID, PLAN_PASSPHRASE, ORG_GITHUB_TOKEN"
echo ""
echo "  ${APPROVE_ENV_NAME}  (approval gate — no secrets)"
echo "    Approver teams: ${RAW_TEAMS:-<none set>}"
echo "    (gates the step between plan and apply)"
echo "----------------------------------------"
