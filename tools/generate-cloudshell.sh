#!/usr/bin/env bash
set -euo pipefail

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
# PARSE TFVARS (SIMPLE VALUES)
########################################

get_var() {
  local key="$1"
  grep -E "^${key}[[:space:]]*=" "${TFVARS_FILE}" | head -n1 | sed -E 's/.*=[[:space:]]*"?([^"]+)"?/\1/'
}

ORG="$(get_var org)"
ENVIRONMENT="$(get_var environment)"
PARTITION="$(get_var partition)"
AWS_REGION="$(get_var aws_region)"
SYSTEM="$(get_var system)"

if [[ -z "$ORG" || -z "$ENVIRONMENT" || -z "$PARTITION" || -z "$AWS_REGION" || -z "$SYSTEM" ]]; then
  echo "[ERROR] Missing required values in tfvars"
  exit 1
fi

########################################
# GITHUB ORG (from git remote)
########################################

REMOTE_URL="$(git remote get-url origin 2>/dev/null || git ls-remote --get-url origin)"
GITHUB_ORG="$(echo "${REMOTE_URL}" | sed 's|.*github\.com[:/]\([^/]*\)/.*|\1|')"

if [[ -z "$GITHUB_ORG" ]]; then
  echo "[ERROR] Could not derive GitHub org from git remote URL: ${REMOTE_URL}"
  exit 1
fi

########################################
# DERIVED (MATCH TERRAFORM locals.tf)
########################################

case "${PARTITION}" in
  aws) partition_short="cmc" ;;
  aws-us-gov) partition_short="gvc" ;;
  *) echo "[ERROR] Invalid partition"; exit 1 ;;
esac

case "${AWS_REGION}" in
  us-east-1) region_short="use1" ;;
  us-west-1) region_short="usw1" ;;
  us-west-2) region_short="usw2" ;;
  eu-west-1) region_short="euw1" ;;
  eu-west-2) region_short="euw2" ;;
  us-gov-west-1) region_short="usgw1" ;;
  us-gov-east-1) region_short="usge1" ;;
  *) echo "[ERROR] Invalid region"; exit 1 ;;
esac

NAME_PREFIX="${ORG}-${partition_short}-${region_short}-${SYSTEM}"

ROLE_NAME="${NAME_PREFIX}-oidc-role"
TF_STATE_BUCKET="${NAME_PREFIX}-tfstate-${ENVIRONMENT}"
TF_LOGS_BUCKET="${NAME_PREFIX}-logs-${ENVIRONMENT}"
KMS_ALIAS="alias/${NAME_PREFIX}-tfstate"

TFVARS_BASENAME="$(basename "${TFVARS_FILE}" .tfvars)"
# Convention: TFVARS_BASENAME (the filename, e.g. fdr-cmc) is used as the S3 state key prefix.
# The workflow terraform-deploy.yml uses inputs.org for the same key.
# These must always match — name your tfvars file after the org slug used in the workflow input.

REPO_REMOTE=$(git remote get-url origin 2>/dev/null || echo "")
if [[ "$REPO_REMOTE" == git@github.com:* ]]; then
  REPO_HTTPS="https://github.com/${REPO_REMOTE#git@github.com:}"
else
  REPO_HTTPS="$REPO_REMOTE"
fi
REPO_HTTPS="${REPO_HTTPS%.git}"

if [[ -z "$REPO_HTTPS" ]]; then
  echo "[ERROR] Could not determine repo URL from git remote. Ensure you are in the repo root."
  exit 1
fi

# Derive OIDC subjects from known values — never rely on github_oidc_subjects in tfvars
# which can contain copy-paste errors (e.g. wrong environment name).
GITHUB_REPO="${REPO_HTTPS##*/}"
SUBJECT_JSON="[\"repo:${GITHUB_ORG}/${GITHUB_REPO}:ref:refs/heads/main\", \"repo:${GITHUB_ORG}/${GITHUB_REPO}:environment:${TFVARS_BASENAME}\"]"

OUTPUT_DIR="cloudshell/${TFVARS_BASENAME}"
mkdir -p "${OUTPUT_DIR}"

OUTPUT_BOOTSTRAP="${OUTPUT_DIR}/${TFVARS_BASENAME}-bootstrap.sh"

########################################
# GENERATE bootstrap.sh
########################################

cat > "${OUTPUT_BOOTSTRAP}" <<EOF
#!/usr/bin/env bash
# ============================================================
# BOOTSTRAP + IMPORT — ${TFVARS_BASENAME}
#
# Phase 1: Creates AWS seed resources (runs anywhere — CloudShell,
#          local machine, CI).
# Phase 2: Imports resources into Terraform state.  Auto-installs
#          terraform if needed and clones the repo into /tmp/seed-repo.
#          Requires GITHUB_TOKEN env var for private repos.
#
# Usage (CloudShell or local):
#   export GITHUB_TOKEN=ghp_yourtoken
#   bash ${TFVARS_BASENAME}-bootstrap.sh
# ============================================================
set -euo pipefail

########################################
# CONFIG (generated from configs/orgs/${TFVARS_BASENAME}.tfvars)
########################################

AWS_REGION="${AWS_REGION}"
PARTITION="${PARTITION}"
ORG="${ORG}"
ROLE_NAME="${ROLE_NAME}"
TF_STATE_BUCKET="${TF_STATE_BUCKET}"
TF_LOGS_BUCKET="${TF_LOGS_BUCKET}"
KMS_ALIAS="${KMS_ALIAS}"
NAME_PREFIX="${NAME_PREFIX}"
TFVARS_BASENAME="${TFVARS_BASENAME}"

ACCOUNT_ID=\$(aws sts get-caller-identity --query Account --output text)

########################################
# PHASE 1 — AWS RESOURCE CREATION
########################################

echo ""
echo "════════════════════════════════════════"
echo " PHASE 1: AWS resource creation"
echo "════════════════════════════════════════"

OIDC_URL="https://token.actions.githubusercontent.com"
OIDC_HOST="token.actions.githubusercontent.com"

echo "[INFO] Ensuring OIDC provider exists"

if aws iam get-open-id-connect-provider \
  --open-id-connect-provider-arn "arn:\${PARTITION}:iam::\${ACCOUNT_ID}:oidc-provider/\${OIDC_HOST}" >/dev/null 2>&1; then
  echo "[INFO] OIDC provider already exists"
else
  THUMBPRINT="6938fd4d98bab03faadb97b34396831e3780aea1"  # pragma: allowlist secret

  aws iam create-open-id-connect-provider \
    --url "\$OIDC_URL" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "\$THUMBPRINT" \
    >/dev/null

  echo "[INFO] OIDC provider created"
fi

cat > trust-policy.json <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:\${PARTITION}:iam::\${ACCOUNT_ID}:oidc-provider/\${OIDC_HOST}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "\${OIDC_HOST}:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "\${OIDC_HOST}:sub": ${SUBJECT_JSON}
        }
      }
    }
  ]
}
POLICY

echo "[INFO] Ensuring role exists: \$ROLE_NAME"

if aws iam get-role --role-name "\$ROLE_NAME" >/dev/null 2>&1; then
  echo "[INFO] Role exists, updating trust policy"
  aws iam update-assume-role-policy \
    --role-name "\$ROLE_NAME" \
    --policy-document file://trust-policy.json
else
  echo "[INFO] Creating role"
  aws iam create-role \
    --role-name "\$ROLE_NAME" \
    --assume-role-policy-document file://trust-policy.json \
    --description "OIDC bootstrap role for Terraform" >/dev/null
fi

cat > seed-policy.json <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["iam:*", "sts:*", "s3:*", "kms:*", "cloudformation:*", "organizations:*"],
      "Resource": "*"
    }
  ]
}
POLICY

echo "[INFO] Attaching bootstrap policy"
aws iam put-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-name "terraform-bootstrap" \
  --policy-document file://seed-policy.json \
  >/dev/null

echo "[INFO] Ensuring KMS key exists"
KMS_KEY_ID=\$(aws kms list-aliases \
  --query "Aliases[?AliasName=='\${KMS_ALIAS}'].TargetKeyId | [0]" \
  --output text)

if [[ "\$KMS_KEY_ID" == "None" || -z "\$KMS_KEY_ID" ]]; then
  echo "[INFO] Creating KMS key"
  KMS_KEY_ID=\$(aws kms create-key \
    --description "\${NAME_PREFIX}-tf-state-key" \
    --query KeyMetadata.KeyId \
    --output text)
  echo "[INFO] Creating KMS alias"
  aws kms create-alias \
    --alias-name "\${KMS_ALIAS}" \
    --target-key-id "\$KMS_KEY_ID"
else
  echo "[INFO] KMS key exists"
fi

create_bucket() {
  local bucket="\$1"
  if aws s3api head-bucket --bucket "\$bucket" >/dev/null 2>&1; then
    echo "[INFO] Bucket exists: \$bucket"
  else
    echo "[INFO] Creating bucket: \$bucket"
    aws s3api create-bucket \
      --bucket "\$bucket" \
      --region "${AWS_REGION}" \
      \$( [[ "${AWS_REGION}" != "us-east-1" ]] && echo "--create-bucket-configuration LocationConstraint=${AWS_REGION}" ) \
      >/dev/null
  fi
}

create_bucket "${TF_STATE_BUCKET}"
create_bucket "${TF_LOGS_BUCKET}"

echo "[INFO] Enabling versioning on state bucket"
aws s3api put-bucket-versioning \
  --bucket "${TF_STATE_BUCKET}" \
  --versioning-configuration Status=Enabled \
  >/dev/null

echo "[INFO] Enabling KMS encryption on state bucket"
aws s3api put-bucket-encryption \
  --bucket "${TF_STATE_BUCKET}" \
  --server-side-encryption-configuration "{
    \"Rules\": [{
      \"ApplyServerSideEncryptionByDefault\": {
        \"SSEAlgorithm\": \"aws:kms\",
        \"KMSMasterKeyID\": \"\$KMS_KEY_ID\"
      },
      \"BucketKeyEnabled\": true
    }]
  }" \
  >/dev/null

########################################
# HELPER — print exports (called at end and on token error)
########################################

print_exports() {
  echo ""
  echo "════════════════════════════════════════"
  echo " Copy these exports to your local terminal"
  echo "════════════════════════════════════════"
  echo "export SEED_ROLE_ARN=\"arn:\${PARTITION}:iam::\${ACCOUNT_ID}:role/\${ROLE_NAME}\""
  echo "export TF_STATE_BUCKET=\"\${TF_STATE_BUCKET}\""
  echo "export TF_LOGS_BUCKET=\"\${TF_LOGS_BUCKET}\""
  echo "export KMS_ALIAS=\"\${KMS_ALIAS}\""
  echo "export KMS_KEY_ID=\"\${KMS_KEY_ID}\""
  echo "export AWS_REGION=\"\${AWS_REGION}\""
  echo "export AWS_DEFAULT_REGION=\"\${AWS_REGION}\""
  echo ""
}

########################################
# PHASE 2 — TERRAFORM IMPORTS
########################################

echo ""
echo "════════════════════════════════════════"
echo " PHASE 2: Terraform state imports"
echo "════════════════════════════════════════"

########################################
# INSTALL TERRAFORM (if needed)
########################################

TF_VERSION="1.10.0"
if ! command -v terraform >/dev/null 2>&1 || ! terraform version | grep -qE "v([2-9]|1\.[1-9][0-9])"; then
  echo "[INFO] Installing terraform \${TF_VERSION}..."
  TF_ARCH="\$(uname -m)"
  [[ "\${TF_ARCH}" == "x86_64" ]] && TF_ARCH="amd64" || TF_ARCH="arm64"
  curl -sLo /tmp/terraform.zip \
    "https://releases.hashicorp.com/terraform/\${TF_VERSION}/terraform_\${TF_VERSION}_linux_\${TF_ARCH}.zip"
  mkdir -p "\${HOME}/bin"
  unzip -q -o /tmp/terraform.zip -d "\${HOME}/bin"
  rm /tmp/terraform.zip
  export PATH="\${HOME}/bin:\${PATH}"
  echo "[INFO] Installed: \$(terraform version | head -1)"
else
  echo "[INFO] Terraform already available: \$(terraform version | head -1)"
fi

########################################
# CLONE REPO (if needed)
########################################

REPO_HTTPS="${REPO_HTTPS}"
REPO_DIR="/tmp/seed-repo"

GITHUB_TOKEN="\${GITHUB_TOKEN:-}"
if [[ -z "\${GITHUB_TOKEN}" ]]; then
  echo ""
  echo "════════════════════════════════════════"
  echo " ❌  GITHUB_TOKEN required for Phase 2"
  echo "════════════════════════════════════════"
  echo ""
  echo "Run this command on your LOCAL machine to get the exact export:"
  echo ""
  echo '   echo "export GITHUB_TOKEN=\$(gh auth token)"'
  echo ""
  echo "Copy the output it prints, paste it here in CloudShell, then re-run:"
  echo ""
  echo "   bash \$0"
  echo ""
  print_exports
  echo "✅ Phase 1 complete. Re-run with GITHUB_TOKEN set to complete Phase 2."
  exit 0
fi

if [[ ! -d "\${REPO_DIR}/seed-terraform" ]]; then
  echo "[INFO] Cloning repository..."
  git clone "https://\${GITHUB_TOKEN}@\${REPO_HTTPS#https://}" "\${REPO_DIR}"
  echo "[INFO] Repository cloned to \${REPO_DIR}"
else
  echo "[INFO] Repository already present at \${REPO_DIR}, pulling latest..."
  git -C "\${REPO_DIR}" remote set-url origin "https://\${GITHUB_TOKEN}@\${REPO_HTTPS#https://}"
  git -C "\${REPO_DIR}" pull
fi

cd "\${REPO_DIR}"

echo "[INFO] Configuring git credentials for private modules..."
git config --global url."https://\${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"

echo "[INFO] Waiting 10s for IAM propagation..."
sleep 10

echo "[INFO] Initialising Terraform backend via make tf-init-seed"
# Export the values Phase 1 produced so the Makefile backend-config targets can use them.
export TF_STATE_BUCKET="\${TF_STATE_BUCKET}"
export KMS_KEY_ID="\${KMS_KEY_ID}"
export AWS_REGION="\${AWS_REGION}"

make tf-init-seed ORG="${TFVARS_BASENAME}"

VARFILE="\$(pwd)/configs/orgs/\${TFVARS_BASENAME}.tfvars"

tf_import() {
  local address="\$1"
  local id="\$2"
  if terraform -chdir=seed-terraform state show "\${address}" >/dev/null 2>&1; then
    echo "  [SKIP] already in state: \${address}"
  else
    echo "  [IMPORT] \${address}"
    terraform -chdir=seed-terraform import \
      -input=false \
      -var-file="\${VARFILE}" \
      "\${address}" "\${id}"
  fi
}

echo "[INFO] Importing 7 bootstrap resources..."

echo "[1/7] OIDC provider"
tf_import \
  "module.oidc_provider.aws_iam_openid_connect_provider.this[0]" \
  "arn:\${PARTITION}:iam::\${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

echo "[2/7] OIDC role"
tf_import \
  "module.workloads_oidc_role.aws_iam_role.this[0]" \
  "\${NAME_PREFIX}-oidc-role"

echo "[3/7] State bucket"
tf_import \
  "module.state_bucket[0].aws_s3_bucket.this[0]" \
  "\${TF_STATE_BUCKET}"

echo "[4/7] Logs bucket"
tf_import \
  "module.logs_bucket[0].aws_s3_bucket.this[0]" \
  "\${TF_LOGS_BUCKET}"

echo "[5/7] KMS key"
tf_import \
  "module.kms_key.aws_kms_key.this[0]" \
  "\${KMS_KEY_ID}"

echo "[6/7] KMS alias"
tf_import \
  "module.kms_key.aws_kms_alias.this[\"${NAME_PREFIX}-tfstate\"]" \
  "alias/${NAME_PREFIX}-tfstate"

echo "[7/7] Assume member roles policy (only if pre-existing from a failed apply)"
POLICY_ARN="arn:\${PARTITION}:iam::\${ACCOUNT_ID}:policy/${NAME_PREFIX}-assume-member-roles"
if aws iam get-policy --policy-arn "\${POLICY_ARN}" >/dev/null 2>&1; then
  tf_import \
    "module.assume_member_roles_policy.aws_iam_policy.policy[0]" \
    "\${POLICY_ARN}"
else
  echo "  [SKIP] policy does not exist yet, Terraform will create it"
fi

echo ""
echo "[INFO] Resources in state:"
terraform -chdir=seed-terraform state list

echo ""
echo "✅ Bootstrap + imports complete."
print_exports
echo "Next steps (on your local machine):"
echo "  1. Copy the 'export ...' lines above into your terminal"
echo "  2. Store them in GitHub:"
echo "       make create-github-environment ORG=${TFVARS_BASENAME}"
echo "  3. Push to main — the GitHub Actions pipeline will plan → approve → apply"
EOF

chmod +x "${OUTPUT_BOOTSTRAP}"

########################################
# DONE
########################################

echo ""
echo "✅ Script generated: ${OUTPUT_BOOTSTRAP}"
echo ""
echo "Workflow (from repo root):"
echo "  1. bash ${OUTPUT_BOOTSTRAP}"
echo "  2. make create-github-environment ORG=${TFVARS_BASENAME}"
echo "  3. Trigger GitHub Actions: terraform-deploy.yml"
echo ""
echo "CloudShell usage:"
echo "  1. export GITHUB_TOKEN=ghp_yourtoken"
echo "  2. bash ${OUTPUT_BOOTSTRAP}"
echo "     — terraform auto-installed, repo auto-cloned, imports run automatically"
