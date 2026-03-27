# ============================================================
# HELP
# ============================================================

help:
	@echo ""
	@echo "Usage: make <target> [ORG=<org>] [ENV=<env>]"
	@echo ""
	@echo "Core:"
	@echo "  setup                      Install tooling (terraform, uv, pre-commit)"
	@echo "  bootstrap                  Full setup + init"
	@echo ""
	@echo "Terraform:"
	@echo "  tf-init                    Init terraform (local dev)"
	@echo "  tf-init-ci                 Init terraform (CI strict mode)"
	@echo "  tf-plan                    Run plan"
	@echo "  tf-plan-strict             Plan with readonly lockfile"
	@echo "  tf-apply                   Apply plan"
	@echo "  tf-destroy                 Destroy resources"
	@echo "  tf-workspace               Create/select workspace"
	@echo "  tf-clean                   Remove terraform artifacts"
	@echo "  tf-validate                Validates terraform templates"
	@echo ""
	@echo "Quality:"
	@echo "  precommit                  Run pre-commit checks"
	@echo "  tf-check                   fmt + validate"
	@echo "  tf-scan                    Run checkov scan"
	@echo "  pip-audit                  Audit Python deps for CVEs"
	@echo ""
	@echo "Environment:"
	@echo "  create-github-environment  Create GH env + secrets from tfvars"
	@echo "  generate-cloudshell-script Generate cloudshell/<org>/<org>-bootstrap.sh"
	@echo "  generate-cloudshell-delete-script Generate cloudshell/<org>/delete.sh (teardown — testing only)"
	@echo ""
	@echo "Config:"
	@echo "  ORG=<org> (default: fdr-cmc)"
	@echo "  ENV=<env> (default: prd)"
	@echo ""

# ============================================================
# CONFIG
# ============================================================

TERRAFORM_VERSION := 1.14.5
TF_DIR := seed-terraform

ORG ?= fdr-cmc
ENV ?= prd

OS := $(shell uname -s | tr '[:upper:]' '[:lower:]')
ARCH := $(shell uname -m)

# Normalize arch
ifeq ($(ARCH),x86_64)
  ARCH := amd64
endif
ifeq ($(ARCH),arm64)
  ARCH := arm64
endif

TF_PLUGIN_CACHE_DIR := $(HOME)/.terraform.d/plugin-cache
export TF_PLUGIN_CACHE_DIR

# --- TFVARS PATHS (SINGLE SOURCE OF TRUTH) ---
TFVARS_ROOT := configs/orgs/$(ORG).tfvars
TFVARS_TF   := ../configs/orgs/$(ORG).tfvars

TERRAFORM_ZIP := terraform_$(TERRAFORM_VERSION)_$(OS)_$(ARCH).zip

# ============================================================
# SETUP / BOOTSTRAP
# ============================================================

setup:
	@echo "⚙️ Installing uv..."
	@if ! command -v uv >/dev/null 2>&1; then \
		curl -Ls https://astral.sh/uv/install.sh | sh; \
	else \
		echo "uv already installed"; \
	fi

	@if ! command -v terraform >/dev/null 2>&1; then \
		echo "Downloading Terraform $(TERRAFORM_VERSION) for $(OS)/$(ARCH)..."; \
		curl -Lo terraform.zip https://releases.hashicorp.com/terraform/$(TERRAFORM_VERSION)/$(TERRAFORM_ZIP); \
		unzip -o terraform.zip; \
		sudo mv terraform /usr/local/bin/; \
		rm terraform.zip; \
	else \
		echo "terraform already installed"; \
	fi

	@echo "⚙️ Installing pre-commit..."
	@if ! command -v pre-commit >/dev/null 2>&1; then \
		uv tool install pre-commit; \
	else \
		echo "pre-commit already installed"; \
	fi

	@echo "⚙️ Installing git hooks..."
	@pre-commit install

	@mkdir -p $(TF_PLUGIN_CACHE_DIR)

	@echo "⚙️ Setup complete"

bootstrap: setup install tf-init

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
# PRE-COMMIT
# ============================================================

precommit:
	@uv run pre-commit run --all-files

# ============================================================
# TERRAFORM CORE
# ============================================================

tf-version:
	@terraform version | grep -E "Terraform v1\.(1[4-9]|[5-9])" >/dev/null || \
	( echo "❌ Terraform >= 1.14.0 required"; exit 1 )

tf-init: tf-version
	@rm -rf $(TF_DIR)/.terraform
	@if grep -q "REPLACE_ME" $(TF_DIR)/versions.tf; then \
		echo "❌ Backend not configured"; exit 1; \
	fi
	@terraform -chdir=$(TF_DIR) init -upgrade -input=false -backend=false

tf-init-ci: tf-version
	@rm -rf $(TF_DIR)/.terraform
	@export TF_PLUGIN_CACHE_DIR=; \
	if grep -q "REPLACE_ME" $(TF_DIR)/versions.tf; then \
		echo "❌ Backend not configured"; exit 1; \
	fi; \
	terraform -chdir=$(TF_DIR) init -input=false -lockfile=readonly

tf-lock:
	@mkdir -p $(TF_PLUGIN_CACHE_DIR)
	@rm -rf $(TF_DIR)/.terraform $(TF_DIR)/.terraform.lock.hcl
	@terraform -chdir=$(TF_DIR) init -backend=false -upgrade -input=false
	@terraform -chdir=$(TF_DIR) providers lock \
		-platform=linux_amd64 \
		-platform=darwin_amd64 \
		-platform=darwin_arm64

# ============================================================
# TERRAFORM WORKFLOW
# ============================================================

tf-workspace:
	@terraform -chdir=$(TF_DIR) workspace select $(ENV) 2>/dev/null || \
	terraform -chdir=$(TF_DIR) workspace new $(ENV)

tf-plan: tf-init tf-workspace
	@test -f $(TFVARS_ROOT) || (echo "❌ Missing tfvars: $(TFVARS_ROOT)" && exit 1)
	@terraform -chdir=$(TF_DIR) plan \
		-var-file=$(TFVARS_TF) \
		-input=false \
		-out=tfplan

tf-plan-strict: tf-version
	@rm -rf $(TF_DIR)/.terraform
	@unset TF_PLUGIN_CACHE_DIR; \
	terraform -chdir=$(TF_DIR) init -input=false -lockfile=readonly
	@terraform -chdir=$(TF_DIR) plan \
		-var-file=$(TFVARS_TF) \
		-input=false

tf-apply:
	@if [ "$(ENV)" = "prd" ]; then \
		echo "⚠️ Applying to PROD"; \
	fi
	@terraform -chdir=$(TF_DIR) apply \
		-input=false \
		tfplan

tf-destroy: tf-init tf-workspace
	@terraform -chdir=$(TF_DIR) destroy \
		-var-file=$(TFVARS_TF) \
		-input=false

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
	echo "[INFO] Terraform validate"; \
	if [ -z "$(ORG)" ]; then \
		echo "[ERROR] ORG not set (e.g. make tf-validate ORG=fdr-cmc)"; \
		exit 1; \
	fi; \
	TFVARS_FILE="configs/orgs/$(ORG).tfvars"; \
	if [ ! -f "$$TFVARS_FILE" ]; then \
		echo "[ERROR] tfvars not found: $$TFVARS_FILE"; \
		exit 1; \
	fi; \
	echo "[INFO] Using $$TFVARS_FILE"; \
	terraform -chdir=seed-terraform init -backend=false -input=false >/dev/null; \
	terraform -chdir=seed-terraform validate

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
# ENVIRONMENT / BOOTSTRAP HELPERS
# ============================================================

generate-cloudshell-script:
	@echo "[INFO] Generating bootstrap + imports scripts for $(ORG)"
	@test -f "$(TFVARS_ROOT)" || (echo "[ERROR] tfvars not found: $(TFVARS_ROOT)" && exit 1)
	@TFVARS_FILE="$(TFVARS_ROOT)" bash tools/generate-cloudshell.sh

create-github-environment:
	@set -e; \
	for v in SEED_ROLE_ARN TF_STATE_BUCKET TF_LOGS_BUCKET KMS_KEY_ID; do \
		if [ -z "$${!v}" ]; then echo "[ERROR] Missing $$v"; exit 1; fi; \
	done; \
	echo "[INFO] Using tfvars: $(TFVARS_ROOT)"; \
	test -f "$(TFVARS_ROOT)" || (echo "[ERROR] tfvars not found: $(TFVARS_ROOT)" && exit 1); \
	TFVARS_FILE="$(TFVARS_ROOT)" bash tools/create-gh-env.sh

generate-cloudshell-delete-script:
	@echo "[INFO] Generating delete script from $(TFVARS_ROOT)"
	@test -f "$(TFVARS_ROOT)" || (echo "[ERROR] tfvars not found: $(TFVARS_ROOT)" && exit 1)
	TFVARS_FILE="$(TFVARS_ROOT)" bash tools/generate-delete.sh

# ============================================================
# CI ENTRYPOINT
# ============================================================

check: install precommit tf-check tf-scan
	@echo "✅ All checks passed"

ci: check
