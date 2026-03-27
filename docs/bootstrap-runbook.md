# Bootstrap Runbook — Management Account Seed Pipeline

> **Quick reference:** This is a condensed ops runbook. For full step-by-step instructions with prerequisites, troubleshooting, and platform-specific notes see [README.md](../README.md).

---

## Purpose

Bootstrap a new AWS management-account tenant from zero to fully Terraform-managed control plane.

**Outcomes:**
- AWS seed resources created (OIDC provider, IAM role, KMS key, S3 buckets)
- Resources imported into Terraform state
- GitHub environment and secrets configured
- Pipeline ready for standard plan/apply

---

## Prerequisites

- AWS console access to the management account (CloudShell will be used)
- `gh` CLI authenticated locally (`gh auth status` shows ✓)
- Repository cloned locally
- Local terminal with `make` available

---

## Step 1 — Create Org Config (first time only)

```bash
cp configs/orgs/fdr-cmc.tfvars configs/orgs/<org>.tfvars
# Edit the new file: org, partition, aws_region, organization_id,
# github_oidc_subjects, github_approver_teams, target_organizational_unit_ids
git add configs/orgs/<org>.tfvars && git commit -m "feat: add <org> org config" && git push
```

---

## Step 2 — Generate the CloudShell Script

```bash
make generate-cloudshell-script ORG=<org>
```

**Output:** `cloudshell/<org>/<org>-bootstrap.sh` (gitignored)

---

## Step 3 — Get GitHub Token

Run locally, copy the entire output line:

```bash
echo "export GITHUB_TOKEN=$(gh auth token)"
```

---

## Step 4 — Run in AWS CloudShell

1. Open [AWS CloudShell](https://console.aws.amazon.com/cloudshell/) in the management account
2. Upload `cloudshell/<org>/<org>-bootstrap.sh` via **Actions → Upload file**
3. Paste the `export GITHUB_TOKEN=...` line from Step 3
4. Run:

```bash
bash <org>-bootstrap.sh
```

**Phase 1** creates AWS resources idempotently.
**Phase 2** auto-installs Terraform, clones the repo to `/tmp/seed-repo`, and runs 7 `terraform import` commands.

A successful run ends with:
```
✅ Bootstrap + imports complete.
```

> **Re-run safe:** Phase 1 is fully idempotent. Phase 2 skips already-imported resources.
> If Phase 2 fails with "Backend configuration changed", run `rm -rf /tmp/seed-repo` and re-run.

---

## Step 5 — Export Values Locally

Copy the export block printed during Phase 1 and paste into your **local terminal**:

```bash
export SEED_ROLE_ARN="arn:aws:iam::<account>:role/<name_prefix>-oidc-role"
export TF_STATE_BUCKET="<name_prefix>-tfstate-prd"
export TF_LOGS_BUCKET="<name_prefix>-logs-prd"
export KMS_ALIAS="alias/<name_prefix>-tfstate"
export KMS_KEY_ID="<uuid>"
export AWS_REGION="us-east-1"
export AWS_DEFAULT_REGION="us-east-1"
```

> These are session-scoped. If your terminal closes before Step 6, re-run the bootstrap script to reprint them.

---

## Step 6 — Push Secrets to GitHub

With the exports active in your local terminal:

```bash
make create-github-environment ORG=<org>
```

This creates (or updates) **two** GitHub Environments:

**`<org>`** — secrets environment used by plan and apply (no approval gate):

| Secret | Source |
|---|---|
| `SEED_ROLE_ARN` | CloudShell export |
| `TF_STATE_BUCKET` | CloudShell export |
| `TF_LOGS_BUCKET` | CloudShell export |
| `KMS_KEY_ID` | CloudShell export |
| `ORG_GITHUB_TOKEN` | Local `GITHUB_TOKEN` (private module downloads) |
| `PLAN_PASSPHRASE` | Auto-generated |

**`<org>-approve`** — approval gate between plan and apply (no secrets):
- Required reviewers set from `github_approver_teams` in your tfvars

> **Why two environments?** A single environment with both secrets and an approval gate would block the plan job — approvers would be approving blind before seeing any plan output. The `-approve` environment gates only the plan → apply transition.

Verify: **GitHub → Settings → Environments** — you should see `<org>` (6 secrets) and `<org>-approve` (1 protection rule).

---

## Step 7 — Trigger the Pipeline

**GitHub Actions → `terraform-deploy.yml` → Run workflow:**

| Input | Value |
|---|---|
| Organisation | `<org>` |

> Partition and region are read automatically from `configs/orgs/<org>.tfvars` — no manual selection required.

Review the plan output (expect sub-resource creation, no core resource deletions). When prompted, approve via the `<org>-approve` environment to trigger the apply.

**Success indicator:** `No changes. Your infrastructure matches the configuration.` on subsequent runs.

---

## Validation Checklist

- [ ] `SEED_ROLE_ARN` matches the role ARN in IAM console
- [ ] `TF_STATE_BUCKET` matches the physical S3 bucket name
- [ ] `KMS_KEY_ID` resolves to an active KMS key
- [ ] `expected_account_id` in tfvars matches the target AWS account
- [ ] `expected_region` in tfvars matches the target region
- [ ] GitHub environment `<org>` exists with all 6 secrets
- [ ] GitHub environment `<org>-approve` exists with required reviewers set
- [ ] Pipeline plan shows no unexpected deletions
- [ ] Pipeline apply completes green (after approval in `<org>-approve`)
- [ ] Subsequent pipeline run shows **No changes**
