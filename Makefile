# ============================================================
# HELP
# ============================================================

help:
	@echo ""
	@echo "Usage: make <target> [ORG=<org>] [ENV=<env>]"
	@echo ""
	@echo "Core:"
	@echo "  setup                      Install tooling (terraform, uv, pre-commit)"
	@echo ""
	@echo "Terraform — local dev (no backend, for validation / formatting):"
	@echo "  tf-init                    Init without backend (local dev / lint)"
	@echo "  tf-check                   fmt + validate"
	@echo "  tf-validate                Validate templates"
	@echo "  tf-lock                    Regenerate .terraform.lock.hcl (all platforms)"
	@echo ""
	@echo "Terraform — real backend (CI + cloudshell):"
	@echo "  tf-init-ci                 Init with S3 backend; lockfile=readonly (CI)"
	@echo "  tf-init-seed               Init with S3 backend; no lockfile guard (cloudshell)"
	@echo "  tf-plan-ci                 Plan only — call tf-init-ci first"
	@echo "  tf-apply                   Apply saved tfplan"
	@echo "  tf-destroy                 Destroy resources (use with caution)"
	@echo ""
	@echo "Quality:"
	@echo "  precommit                  Run pre-commit checks"
	@echo "  tf-scan                    Run checkov scan"
	@echo "  pip-audit                  Audit Python deps for CVEs"
	@echo ""
	@echo "Tenant bootstrap:"
	@echo "  generate-cloudshell-script       Generate cloudshell/<org>/<org>-bootstrap.sh"
	@echo "  generate-cloudshell-delete-script Generate cloudshell/<org>/delete.sh"
	@echo "  create-github-environment        Create GH env + secrets (requires exports)"
	@echo ""
	@echo "Config:"
	@echo "  ORG=<org>   (required for most targets)"
	@echo "  ENV=<env>   (default: prd)"
	@echo ""
	@echo "Backend secrets (set in env for CI/cloudshell targets):"
	@echo "  TF_STATE_BUCKET   — state S3 bucket name"
	@echo "  KMS_KEY_ID        — KMS key ARN for state encryption"
	@echo "  AWS_REGION        — derived from tfvars if not set"
	@echo ""

# ============================================================
# CONFIG
# ============================================================

# Minimum Terraform version required (must be >= 1.10.0 for S3 native locking)
TERRAFORM_VERSION := 1.10.0

TF_DIR := seed-terraform

ORG ?=
ENV ?= prd

OS   := $(shell uname -s | tr '[:upper:]' '[:lower:]')
ARCH := $(shell uname -m)

ifeq ($(ARCH),x86_64)
  ARCH := amd64
endif
ifeq ($(ARCH),arm64)
  ARCH := arm64
endif

TF_PLUGIN_CACHE_DIR := $(HOME)/.terraform.d/plugin-cache
export TF_PLUGIN_CACHE_DIR

# --- TFVARS PATHS (single source of truth for all targets) ---
TFVARS_ROOT := configs/orgs/$(ORG).tfvars
TFVARS_TF   := ../configs/orgs/$(ORG).tfvars

# --- BACKEND CONFIG (derived from tfvars; can be overridden by env) ---
# AWS_REGION and PARTITION are parsed at make-parse time so backend config
# targets can use them without requiring the caller to set them manually.
_TF_AWS_REGION := $(shell awk -F'"' '/^[[:space:]]*aws_region[[:space:]]*=/{print $$2}' $(TFVARS_ROOT) 2>/dev/null)
_TF_PARTITION  := $(shell awk -F'"' '/^[[:space:]]*partition[[:space:]]*=/{print $$2}' $(TFVARS_ROOT) 2>/dev/null)

# Environment overrides take precedence (configure-aws-credentials sets AWS_REGION)
AWS_REGION ?= $(_TF_AWS_REGION)
PARTITION  ?= $(or $(_TF_PARTITION),aws)

# State key convention: <org>/<partition>/control-plane/terraform.tfstate
# Never use workspaces — the key path already encodes org + partition.
BACKEND_KEY := $(ORG)/$(PARTITION)/control-plane/terraform.tfstate

# TF_STATE_BUCKET, KMS_KEY_ID — set from environment (GH secrets or cloudshell exports)
TF_STATE_BUCKET ?=
KMS_KEY_ID      ?=

TERRAFORM_ZIP := terraform_$(TERRAFORM_VERSION)_$(OS)_$(ARCH).zip

# ============================================================
# SETUP
# ============================================================

setup:
	@echo "⚙️  Installing uv..."
	@if ! command -v uv >/dev/null 2>&1; then \
		curl -Ls https://astral.sh/uv/install.sh | sh; \
	else \
		echo "   uv already installed"; \
	fi

	@if ! command -v terraform >/dev/null 2>&1; then \
		echo "⚙️  Downloading Terraform $(TERRAFORM_VERSION) for $(OS)/$(ARCH)..."; \
		curl -Lo terraform.zip \
		  "https://releases.hashicorp.com/terraform/$(TERRAFORM_VERSION)/$(TERRAFORM_ZIP)"; \
		unzip -o terraform.zip; \
		sudo mv terraform /usr/local/bin/; \
		rm terraform.zip; \
	else \
		echo "⚙️  terraform already installed: $$(terraform version | head -1)"; \
	fi

	@echo "⚙️  Installing pre-commit..."
	@if ! command -v pre-commit >/dev/null 2>&1; then \
		uv tool install pre-commit; \
	else \
		echo "   pre-commit already installed"; \
	fi

	@pre-commit install
	@mkdir -p $(TF_PLUGIN_CACHE_DIR)
	@echo "✅ Setup complete"

# ============================================================
# UV / DEPENDENCIES
# ============================================================

install:
	@echo "📦 Installing dependencies..."
	@if [ -f uv.lock ]; then \
		uv sync --extra dev --frozen; \
	else \
		uv sync --extra dev; \
	fi

lock:
	@uv lock

# ============================================================
# VERSION GUARD
# ============================================================

# Require Terraform >= 1.10.0 (minimum for S3 native state locking via use_lockfile)
tf-version:
	@terraform version | head -1 | grep -E "Terraform v([2-9]|1\.[1-9][0-9])" >/dev/null || \
	( echo "❌ Terraform >= 1.10.0 required (found: $$(terraform version | head -1))"; exit 1 )

# ============================================================
# TERRAFORM — LOCAL DEV (no backend)
# ============================================================

# Lightweight init for local validation, formatting, and scanning.
# Does NOT connect to the S3 backend — state is not read/written.
tf-init: tf-version
	@rm -rf $(TF_DIR)/.terraform
	@mkdir -p $(TF_PLUGIN_CACHE_DIR)
	@terraform -chdir=$(TF_DIR) init -upgrade -input=false -backend=false

# ============================================================
# TERRAFORM — CI (S3 backend, lockfile=readonly)
# ============================================================
# Requires these env vars (set from GH environment secrets):
#   TF_STATE_BUCKET  — S3 bucket name
#   KMS_KEY_ID       — KMS key ARN
#   AWS_REGION       — derived from tfvars if configure-aws-credentials not used
#
tf-init-ci: tf-version
	@test -n "$(ORG)"          || (echo "❌ ORG not set. e.g. make tf-init-ci ORG=terrorgem"; exit 1)
	@test -n "$${TF_STATE_BUCKET}" || (echo "❌ TF_STATE_BUCKET not set in environment"; exit 1)
	@test -n "$${KMS_KEY_ID}"      || (echo "❌ KMS_KEY_ID not set in environment"; exit 1)
	@test -n "$${AWS_REGION}"      || (echo "❌ AWS_REGION not set in environment"; exit 1)
	@rm -rf $(TF_DIR)/.terraform
	@echo "[INFO] Backend: s3://$${TF_STATE_BUCKET}/$(ORG)/$(PARTITION)/control-plane/terraform.tfstate"
	@export TF_PLUGIN_CACHE_DIR=; \
	terraform -chdir=$(TF_DIR) init \
	  -input=false \
	  -lockfile=readonly \
	  -backend-config="bucket=$${TF_STATE_BUCKET}" \
	  -backend-config="key=$(ORG)/$(PARTITION)/control-plane/terraform.tfstate" \
	  -backend-config="region=$${AWS_REGION}" \
	  -backend-config="kms_key_id=$${KMS_KEY_ID}" \
	  -backend-config="encrypt=true"

# ============================================================
# TERRAFORM — CLOUDSHELL/SEED (S3 backend, no lockfile guard)
# ============================================================
# Same as tf-init-ci but without -lockfile=readonly so terraform can
# download modules fresh (cloudshell has no local module cache).
# Also used for local dev when you want a real backend connection.
#
tf-init-seed: tf-version
	@test -n "$(ORG)"            || (echo "❌ ORG not set. e.g. make tf-init-seed ORG=terrorgem"; exit 1)
	@test -n "$${TF_STATE_BUCKET}" || (echo "❌ TF_STATE_BUCKET not set in environment"; exit 1)
	@test -n "$${KMS_KEY_ID}"      || (echo "❌ KMS_KEY_ID not set in environment"; exit 1)
	@test -n "$${AWS_REGION}"      || (echo "❌ AWS_REGION not set in environment"; exit 1)
	@rm -rf $(TF_DIR)/.terraform
	@echo "[INFO] Backend: s3://$${TF_STATE_BUCKET}/$(ORG)/$(PARTITION)/control-plane/terraform.tfstate"
	@terraform -chdir=$(TF_DIR) init \
	  -input=false \
	  -reconfigure \
	  -backend-config="bucket=$${TF_STATE_BUCKET}" \
	  -backend-config="key=$(ORG)/$(PARTITION)/control-plane/terraform.tfstate" \
	  -backend-config="region=$${AWS_REGION}" \
	  -backend-config="kms_key_id=$${KMS_KEY_ID}" \
	  -backend-config="encrypt=true"

# ============================================================
# TERRAFORM WORKFLOW
# ============================================================

# Plan only — assumes tf-init-ci or tf-init-seed was already called.
# Saves plan to seed-terraform/tfplan for apply step.
tf-plan-ci:
	@test -f $(TFVARS_ROOT) || (echo "❌ Missing tfvars: $(TFVARS_ROOT)" && exit 1)
	@terraform -chdir=$(TF_DIR) plan \
	  -var-file=$(TFVARS_TF) \
	  -input=false \
	  -out=tfplan

# Apply the saved tfplan (no re-plan, no backend re-init needed).
tf-apply:
	@if [ "$(ENV)" = "prd" ]; then \
		echo "⚠️  Applying to PROD ($(ORG))"; \
	fi
	@terraform -chdir=$(TF_DIR) apply \
	  -input=false \
	  tfplan

# Plan + apply in one shot (local dev shortcut, not used in CI)
tf-plan: tf-init tf-workspace
	@test -f $(TFVARS_ROOT) || (echo "❌ Missing tfvars: $(TFVARS_ROOT)" && exit 1)
	@terraform -chdir=$(TF_DIR) plan \
	  -var-file=$(TFVARS_TF) \
	  -input=false \
	  -out=tfplan

tf-workspace:
	@terraform -chdir=$(TF_DIR) workspace select $(ENV) 2>/dev/null || \
	terraform -chdir=$(TF_DIR) workspace new $(ENV)

tf-destroy: tf-init-seed
	@terraform -chdir=$(TF_DIR) destroy \
	  -var-file=$(TFVARS_TF) \
	  -input=false

# ============================================================
# LOCK FILE
# ============================================================

# Regenerate .terraform.lock.hcl for all supported platforms.
# Run this after any provider/module version change, then commit the result.
tf-lock: tf-version
	@mkdir -p $(TF_PLUGIN_CACHE_DIR)
	@rm -rf $(TF_DIR)/.terraform $(TF_DIR)/.terraform.lock.hcl
	@terraform -chdir=$(TF_DIR) init -backend=false -upgrade -input=false
	@terraform -chdir=$(TF_DIR) providers lock \
	  -platform=linux_amd64 \
	  -platform=darwin_amd64 \
	  -platform=darwin_arm64

# ============================================================
# TERRAFORM QUALITY
# ============================================================

tf-check:
	@terraform fmt -recursive $(TF_DIR)
	@terraform -chdir=$(TF_DIR) validate

tf-scan:
	@uv run checkov -d $(TF_DIR)

pip-audit:
	@uv run pip-audit --ignore-vuln CVE-2026-4539

tf-validate:
	@set -euo pipefail; \
	test -n "$(ORG)" || (echo "[ERROR] ORG not set (e.g. make tf-validate ORG=terrorgem)"; exit 1); \
	test -f "$(TFVARS_ROOT)" || (echo "[ERROR] tfvars not found: $(TFVARS_ROOT)"; exit 1); \
	echo "[INFO] Validating with $(TFVARS_ROOT)"; \
	terraform -chdir=$(TF_DIR) init -backend=false -input=false >/dev/null; \
	terraform -chdir=$(TF_DIR) validate

# ============================================================
# PRE-COMMIT
# ============================================================

precommit:
	@uv run pre-commit run --all-files

# ============================================================
# CLEAN
# ============================================================

tf-clean:
	@find . -type d -name ".terraform" -prune -exec rm -rf {} +
	@find . -type f -name "*.tfplan" -delete
	@find . -type f -name "*.tfstate*" -delete
	@echo "✅ Terraform clean complete"

# ============================================================
# MANIFEST
# ============================================================

manifest:
	@uv run python tools/create_manifest.py

# ============================================================
# TENANT BOOTSTRAP HELPERS
# ============================================================

# Generate the tailored CloudShell bootstrap script for a given org.
# Usage: make generate-cloudshell-script ORG=terrorgem
generate-cloudshell-script:
	@test -n "$(ORG)"       || (echo "❌ ORG not set. e.g. make generate-cloudshell-script ORG=terrorgem"; exit 1)
	@test -f "$(TFVARS_ROOT)" || (echo "❌ tfvars not found: $(TFVARS_ROOT)"; exit 1)
	@echo "[INFO] Generating bootstrap script for $(ORG)"
	@TFVARS_FILE="$(TFVARS_ROOT)" bash tools/generate-cloudshell.sh

# Generate teardown script (testing / offboarding only).
generate-cloudshell-delete-script:
	@test -n "$(ORG)"       || (echo "❌ ORG not set"; exit 1)
	@test -f "$(TFVARS_ROOT)" || (echo "❌ tfvars not found: $(TFVARS_ROOT)"; exit 1)
	TFVARS_FILE="$(TFVARS_ROOT)" bash tools/generate-delete.sh

# Create the GitHub environment and store secrets.
# Requires: SEED_ROLE_ARN, TF_STATE_BUCKET, TF_LOGS_BUCKET, KMS_KEY_ID in env.
# Usage: make create-github-environment ORG=terrorgem
create-github-environment:
	@test -n "$(ORG)" || (echo "❌ ORG not set"; exit 1)
	@set -e; \
	for v in SEED_ROLE_ARN TF_STATE_BUCKET TF_LOGS_BUCKET KMS_KEY_ID; do \
		if [ -z "$${!v}" ]; then echo "❌ Missing env var: $$v"; exit 1; fi; \
	done
	@test -f "$(TFVARS_ROOT)" || (echo "❌ tfvars not found: $(TFVARS_ROOT)"; exit 1)
	@echo "[INFO] Creating GitHub environment for $(ORG)"
	@TFVARS_FILE="$(TFVARS_ROOT)" bash tools/create-gh-env.sh

# ============================================================
# CI ENTRYPOINT (quality gate — separate from plan/apply pipeline)
# ============================================================

check: install precommit tf-check tf-scan
	@echo "✅ All checks passed"

ci: check
