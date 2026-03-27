# AI System Guide — Tenant Seed Repository

> **Purpose of this file:** Give an AI assistant full situational awareness
> of this repository — its architecture, design decisions, constraints, and
> common failure modes — so it can reason correctly about changes without
> needing to re-derive context from first principles.

---

## 1. What This Repo Is (and Is Not)

**Is:** A one-time bootstrap boundary that takes an AWS management account
from *zero* (no IAM roles, no SSO, no credentials) to a fully
Terraform-managed control plane with a working GitHub Actions pipeline.

**Is not:**
- A platform repo (no workload infra here)
- A security boundary solution (permissions boundary is a future, separate repo)
- A least-privilege IAM design (CI/CD role is intentionally broad — see §8)
- A reusable module library

If a proposed change smells like "reusable infra", "workload deployment", or
"app infrastructure" — it does not belong here.

---

## 2. Mental Model — Layers and Ownership

```
CloudShell (Phase 1)          Terraform (Phase 2+)         GitHub Actions (ongoing)
──────────────────────        ─────────────────────        ────────────────────────
Creates seed resources   →    Imports + owns them     →    All future plan/apply
  OIDC provider               Adds hardening                Standard pipeline
  IAM role                    Manages config
  KMS key + alias             Creates StackSet
  S3 state + logs buckets
  Assume-member-roles policy
  (if prior apply failed)
```

**Two-phase ownership is a core design principle.** Phase 1 creates
resources with minimal config. Phase 2 imports them and becomes the sole
authority. AI must never try to "complete" CloudShell resources — Terraform
does that.

---

## 3. Repository Structure (Current)

```
.
├── AI.md                          ← You are here
├── README.md                      ← Full bootstrap guide for humans
├── Makefile                       ← Primary UX layer — single interface for all ops
├── cloudformation/
│   └── member-role-stackset/      ← Deploys CI/CD IAM role to all member OUs
│       ├── main.tf
│       ├── outputs.tf
│       ├── variables.tf
│       └── versions.tf
├── cloudshell/
│   └── <org>/                     ← GITIGNORED — generated per-org bootstrap scripts
│       └── <org>-bootstrap.sh
├── configs/
│   └── orgs/                      ← SINGLE SOURCE OF TRUTH for all config
│       ├── fdr-cmc.tfvars
│       ├── fdr-gvc.tfvars
│       ├── bt-avm.tfvars
│       └── bt-dev.tfvars
├── docs/
│   ├── architecture.md
│   └── bootstrap-runbook.md
├── seed-terraform/                ← Terraform root — the control plane
│   ├── main.tf
│   ├── locals.tf
│   ├── variables.tf
│   ├── versions.tf
│   ├── providers.tf
│   ├── backend.tf
│   ├── data.tf
│   └── outputs.tf
└── tools/
    ├── generate-cloudshell.sh     ← Generates cloudshell/<org>/<org>-bootstrap.sh
    ├── generate-delete.sh         ← Generates teardown script for an org
    └── create-gh-env.sh           ← Pushes secrets to GitHub environment
```

> **Notable absences (intentionally deleted):**
> - `seed-terraform/imports.tf` — removed; imports now run via shell commands in bootstrap script
> - `enable_imports` variable — removed from variables.tf
> - `kms_key_id` variable — removed from variables.tf

---

## 4. The Bootstrap Flow (End-to-End)

```
configs/orgs/<org>.tfvars
        │
        ▼
make generate-cloudshell-script ORG=<org>
        │  reads tfvars, bakes in REPO_HTTPS, all config values
        ▼
cloudshell/<org>/<org>-bootstrap.sh   (gitignored, regenerated each time)
        │
        │  uploaded to AWS CloudShell
        │  run with: export GITHUB_TOKEN=... && bash <org>-bootstrap.sh
        ▼
PHASE 1 — AWS resource creation (idempotent, runs anywhere)
  Creates: OIDC provider, IAM role + inline policy, KMS key + alias,
           S3 state bucket, S3 logs bucket
  Prints:  export block for local terminal
        │
        ▼
PHASE 2 — Terraform imports (runs inside CloudShell)
  Auto-installs terraform 1.14.5 → ~/bin  (no sudo, no pre-req)
  Clones repo to /tmp/seed-repo           (uses GITHUB_TOKEN for private repo)
  Configures git credential substitution  (for private module downloads)
  terraform init -reconfigure             (uses /tmp to avoid 1GB home dir limit)
  terraform import × 7                    (skip-if-already-in-state logic)
        │
        ▼
State written to S3: <org>/<partition>/control-plane/terraform.tfstate
        │
        ▼
User copies export block → local terminal
        │
        ▼
make create-github-environment ORG=<org>
  Creates GitHub Environment <org> — pushes 6 secrets:
    SEED_ROLE_ARN, TF_STATE_BUCKET, TF_LOGS_BUCKET,
    KMS_KEY_ID, ORG_GITHUB_TOKEN, PLAN_PASSPHRASE
  Creates GitHub Environment <org>-approve — sets required reviewers
    from github_approver_teams in tfvars (approval gate, no secrets)
        │
        ▼
GitHub Actions: terraform-deploy.yml (plan + approve + apply)
```

---

## 5. Naming System — A Hard Contract

Everything derives from `locals.tf`. The pattern is:

```
name_prefix = <org>-<partition_short>-<region_short>-<system>
```

| tfvars field | Example value | Contribution |
|---|---|---|
| `org` | `"fedramp"` | `fedramp` |
| `partition` | `"aws"` | → `partition_short = "cmc"` |
| `aws_region` | `"us-east-1"` | → `region_short = "use1"` |
| `system` | `"infra-cloudops"` | `infra-cloudops` |
| **Result** | | `fedramp-cmc-use1-infra-cloudops` |

Resource names derived from this:

| Resource | Name |
|---|---|
| S3 state bucket | `<name_prefix>-tfstate-<env>` |
| S3 logs bucket | `<name_prefix>-logs-<env>` |
| KMS alias | `alias/<name_prefix>-tfstate` |
| IAM role | `<name_prefix>-oidc-role` |
| IAM policy | `<name_prefix>-assume-member-roles` |
| StackSet | `<name_prefix>-member-role` |
| Member CI/CD role | `<name_prefix>-cicd-role` |

**Treat naming like an API contract.** Changing it breaks: imports, backend
key, cross-account roles, and CI/CD. The bootstrap script bakes names in at
generation time — any rename requires regenerating the script.

---

## 6. Terraform Resources — What Gets Created

### `seed-terraform/main.tf`

| Resource | Module / Address | Notes |
|---|---|---|
| OIDC provider | `module.oidc_provider` | GitHub token.actions.githubusercontent.com |
| Assume-member-roles policy | `module.assume_member_roles_policy` | Allows `sts:AssumeRole` on member accounts |
| Workloads OIDC role | `module.workloads_oidc_role` | Attaches assume-member-roles policy |
| KMS key + alias | `module.kms_key` | Used for state encryption; alias = name_prefix-tfstate |
| S3 state bucket | `module.state_bucket[0]` | Versioning, lifecycle, KMS encryption, public access block |
| S3 logs bucket | `module.logs_bucket[0]` | Lifecycle (expire 30d), KMS encryption, public access block |
| CloudFormation StackSet | `module.member_role_stackset` | Deploys CI/CD role to all target OUs |
| Validation null_resources | `null_resource.validate_*` | Precondition guards — Terraform-internal only |

### `cloudformation/member-role-stackset/main.tf`

Creates `aws_cloudformation_stack_set` + `aws_cloudformation_stack_set_instance`.
The StackSet deploys `<name_prefix>-cicd-role` into every OU listed in
`target_organizational_unit_ids`. This role is the execution identity for
all future Terraform workload deployments across accounts.

---

## 7. The 7 Bootstrap Imports

The bootstrap script runs `terraform import` for resources that exist
before the first Terraform apply. Import addresses use the exact module path:

| # | Description | Terraform address | ID source |
|---|---|---|---|
| 1 | OIDC provider | `module.oidc_provider.aws_iam_openid_connect_provider.this[0]` | ARN: `arn:<partition>:iam::<account>:oidc-provider/token.actions.githubusercontent.com` |
| 2 | OIDC IAM role | `module.workloads_oidc_role.aws_iam_role.this[0]` | Role name: `<name_prefix>-oidc-role` |
| 3 | State bucket | `module.state_bucket[0].aws_s3_bucket.this[0]` | Bucket name |
| 4 | Logs bucket | `module.logs_bucket[0].aws_s3_bucket.this[0]` | Bucket name |
| 5 | KMS key | `module.kms_key.aws_kms_key.this[0]` | Key UUID (resolved at runtime) |
| 6 | KMS alias | `module.kms_key.aws_kms_alias.this["<name_prefix>-tfstate"]` | `alias/<name_prefix>-tfstate` — **key is WITHOUT `alias/` prefix** |
| 7 | Assume-member-roles policy | `module.assume_member_roles_policy.aws_iam_policy.policy[0]` | Policy ARN — **conditional**: only imported if already exists in AWS (handles partial prior apply) |

**Skip-if-in-state logic:** Each import checks `terraform state show <address>`
first and skips if already present. Safe to re-run.

**`-reconfigure` on `terraform init`:** Added to handle re-runs where
`/tmp/seed-repo` has a stale backend config from a previous run.

---

## 8. The Bootstrap Inline Policy

The OIDC role receives an inline policy named `terraform-bootstrap` that
enables the GitHub Actions pipeline to manage all seed resources:

```json
{
  "Action": ["iam:*", "sts:*", "s3:*", "kms:*", "cloudformation:*", "organizations:*"]
}
```

`cloudformation:*` and `organizations:*` are required for the SERVICE_MANAGED
StackSet. This policy is re-applied on every bootstrap script run (idempotent).

The role is **intentionally broad**. This is by design — it is the long-lived
CI/CD control role that must support unknown future Terraform use cases.
AI must **not** narrow it without explicit instruction.

---

## 9. CI/CD Pipeline — `terraform-deploy.yml`

Single mode: plan + apply. Single workflow input: `org`.

**Partition and region are derived from tfvars** — not workflow inputs. A
"Read org config from tfvars" step parses them after checkout and exports
them to `GITHUB_ENV`.

**Plan job:**
1. Checkout + read partition/region from tfvars → GITHUB_ENV
2. Validate required secrets
3. OIDC auth → assume `SEED_ROLE_ARN` (using region from tfvars)
4. Configure git for private module downloads
5. `terraform init` (dynamic backend via `-backend-config`)
6. `terraform plan -var-file=... -out=tfplan`
7. Hash plan → encrypt with AES-256-CBC → upload artifact

**Approve job** (gates plan → apply):
- Uses `environment: <org>-approve` (required reviewers, no secrets)
- Runs after plan artifact upload; plan output is visible before approval is requested
- Approvers see the plan before committing to apply

**Apply job** (runs after approve):
1. Checkout + read partition/region from tfvars → GITHUB_ENV
2. Validate required secrets
3. OIDC auth → assume `SEED_ROLE_ARN`
4. Download + decrypt plan artifact
5. Verify SHA256 hash + commit binding
6. `terraform init` (same dynamic backend)
7. `terraform apply tfplan`

**State key pattern:** `<org>/<partition>/control-plane/terraform.tfstate`

Where `<org>` is the **tfvars filename** (e.g. `fdr-cmc`), not the `org`
field value inside the file (e.g. `fedramp`). The bootstrap script uses the
same key — this is a critical alignment point.

**Concurrency:** Scoped to `terraform-<org>`.
Prevents parallel applies to same state; allows parallel runs across orgs.

**Org dropdown:** Auto-synced from `configs/orgs/*.tfvars` by
`sync-org-dropdown.yml` which runs on any push to `configs/orgs/**`.

---

## 10. `configs/orgs/<org>.tfvars` — Single Source of Truth

Every layer derives from this file. Changing a value here propagates to:
- `generate-cloudshell.sh` output (re-generation required)
- `create-gh-env.sh` output
- Terraform resource names via `locals.tf`
- GitHub OIDC trust subjects

Key fields:

```hcl
org         = "fedramp"          # Used in name_prefix
partition   = "aws"              # aws | aws-us-gov
aws_region  = "us-east-1"
environment = "prd"
system      = "infra-cloudops"   # Used in name_prefix
organization_id = "o-xxxx"       # AWS Org ID

github_oidc_subjects = [         # Terraform uses for OIDC trust policy. Bootstrap generator derives these independently from git remote + org slug (tfvars filename). Keep in sync.
  "repo:Org/Repo:ref:refs/heads/main",
  "repo:Org/Repo:environment:<org>"
]

github_approver_teams = ["is-cloudops"]  # Team slugs set as required reviewers on <org>-approve env. Read by create-gh-env.sh — not used in Terraform resources.

target_organizational_unit_ids = ["ou-..."]  # OUs for StackSet deployment

expected_account_id = "260278864911"   # Guard rails — plan fails if wrong account or region
expected_region     = "us-east-1"      # Guard rails — plan fails if wrong account or region
```

---

## 11. Cross-Layer Variable Contracts

These names are **protocol fields** — they exist identically across multiple
layers. Renaming one requires updating all.

| Variable | CloudShell output | Local env | GitHub secret | Workflow env |
|---|---|---|---|---|
| `SEED_ROLE_ARN` | ✅ printed | ✅ exported | ✅ | ✅ |
| `TF_STATE_BUCKET` | ✅ printed | ✅ exported | ✅ | — |
| `TF_LOGS_BUCKET` | ✅ printed | ✅ exported | ✅ | — |
| `KMS_KEY_ID` | ✅ printed | ✅ exported | ✅ | via `-backend-config` |
| `KMS_ALIAS` | ✅ printed | ✅ exported | — | — |
| `ORG_GITHUB_TOKEN` | — | `GITHUB_TOKEN` | ✅ | git credential config |
| `PLAN_PASSPHRASE` | — | — | ✅ | plan encrypt/decrypt |

---

## 12. Heredoc Quoting in `generate-cloudshell.sh`

The generator uses `<<EOF` (unquoted heredoc), so variables are evaluated
at generation time unless escaped. Rules:

| In generator | In generated script | Evaluates |
|---|---|---|
| `${VAR}` | literal value | at generation time (baked in) |
| `\${VAR}` | `${VAR}` | at CloudShell runtime |
| `\\` | `\` | literal backslash in output |
| `\\\"` | `\"` | escaped quote in output |

**Never end an `echo` argument with `\\`** inside the heredoc — it creates
an unclosed double-quoted string in the generated script and causes an EOF
error.

---

## 13. Key Design Constraints (AI Operating Rules)

### Always
- Treat `configs/orgs/<org>.tfvars` as the source of truth — new behaviour
  starts there
- Keep CloudShell scripts idempotent and minimal — they must be safe to
  re-run blindly
- Keep the Makefile as the primary UX layer — add new operations via `make`
  targets
- Validate changes across the full chain: tfvars → generator → cloudshell →
  exports → GH secrets → workflow → terraform
- Think in state transitions, not just code — there are 4 state systems
  (AWS, Terraform tfstate, GitHub secrets, local env vars)

### Never
- Add infrastructure logic to the CloudShell script — if Terraform manages
  it, bootstrap must not touch it
- Hardcode values outside tfvars
- Narrow the CI/CD IAM role without explicit instruction
- Break naming conventions — treat `name_prefix` like an API contract
- Bypass the Makefile with raw commands
- Merge plan + apply, bypass plan encryption, or weaken commit binding
- Hardcode backend config into `backend.tf` — it is dynamic by design
- Rename cross-layer protocol fields without updating all layers
- Remove retries from `init`/`plan`/`apply` — AWS APIs are eventually
  consistent
- Add partition/region back as workflow inputs — they are derived from tfvars
  at runtime and must not be manual inputs

---

## 14. Common Failure Modes (With Causes)

| Symptom | Root cause | Fix |
|---|---|---|
| `Backend configuration changed` in CloudShell | `/tmp/seed-repo` has stale backend config from prior run | `rm -rf /tmp/seed-repo` and re-run |
| `no space left on device` in CloudShell | Providers installed into 1GB home dir | Script now uses `/tmp` — regenerate if hitting old script |
| `Username for 'https://github.com'` | `GITHUB_TOKEN` not set before running script | `export GITHUB_TOKEN=...` and re-run |
| `EntityAlreadyExists` for IAM policy | Prior apply created resource but state was reset | Bootstrap script conditionally imports it |
| `AccessDenied: cloudformation:CreateStackSet` | Bootstrap inline policy missing `cloudformation:*` | Re-run bootstrap — policy is re-applied with correct permissions |
| `Saved plan is stale` | State changed between plan and apply | Re-trigger workflow |
| OIDC `AccessDenied` in pipeline | `github_oidc_subjects` mismatch (wrong repo, branch, or env name) | Check tfvars subjects match GitHub environment name exactly. Note: bootstrap generator now derives subjects automatically from org slug so copy-paste errors in tfvars subjects no longer affect bootstrap (but still affect Terraform apply) |
| OIDC timeout (11 retries then cancel) | `github_oidc_subjects` environment name doesn't match the GitHub environment | Fix subjects in tfvars — must match tfvars filename exactly (e.g. `environment:fdr-gvc` for `fdr-gvc.tfvars`) |
| Import wrong KMS alias address | Using `alias/<name>` as the for_each key | Key must be WITHOUT `alias/` prefix: `aws_kms_alias.this["<name>"]` |
| State key mismatch (workflow vs bootstrap) | Bootstrap used `org` field value; workflow uses tfvars filename | State key must use tfvars filename (e.g. `fdr-cmc`), not `org` value (e.g. `fedramp`) |

---

## 15. Partition Support

This repo targets both `aws` and `aws-us-gov`. Every change must work in both.

| Partition | `partition_short` | ARN prefix | Allowed regions |
|---|---|---|---|
| `aws` | `cmc` | `arn:aws:` | `us-east-1`, `us-west-*`, `eu-west-*` etc. |
| `aws-us-gov` | `gvc` | `arn:aws-us-gov:` | `us-gov-west-1`, `us-gov-east-1` |

Partition and region alignment is enforced by Terraform preconditions (`null_resource.validate_partition`, `null_resource.validate_region`) and the `expected_region` guardrail in tfvars.

---

## 16. Guardrails

Two safety variables in each org's tfvars prevent accidental cross-account or cross-region applies:

```hcl
expected_account_id = "260278864911"   # Plan fails if wrong AWS account
expected_region     = "us-east-1"      # Plan fails if wrong region
```

Both default to `""` (disabled) but should always be set for production orgs.
Error messages show expected vs actual values for fast diagnosis.

---

## 17. Pre-commit Hooks

All commits run:

| Hook | What it checks |
|---|---|
| `terraform fmt` | Formatting |
| `terraform validate` + `tflint` | Correctness + unused declarations, missing provider constraints |
| `checkov` | Security scanning |
| `detect-secrets` | Entropy / secret detection |
| `ruff` | Python linting/formatting |
| `end-of-file-fixer`, `trailing-whitespace` | Hygiene |

`detect-secrets` will flag hex strings (e.g. OIDC thumbprints). Use
`# pragma: allowlist secret` inline to suppress legitimate values.

`tflint` will warn on unused `locals` and missing provider version
constraints — keep locals.tf clean.

---

## 18. What "Good Change" Looks Like Here

A correct, complete change:

1. Starts in `configs/orgs/<org>.tfvars` (if config-driven)
2. Flows through `make generate-cloudshell` if the CloudShell script is affected
3. Lands in Terraform (`seed-terraform/`)
4. Has a Makefile target if it introduces a new operation
5. Passes all pre-commit hooks without `--no-verify`
6. Works from a fresh AWS account with no prior state
7. Is idempotent — safe to run more than once

---

## 19. Final Mental Model

```
This repo is a bridge:

  Nothing (empty AWS account)
        │
        ▼ CloudShell bootstrap (one time)
        │
        ▼ Terraform imports (one time, inside CloudShell)
        │
  Fully Terraform-managed control plane
        │
        ▼ GitHub Actions (ongoing, forever)
```

The moment Terraform successfully applies with no errors and no unexpected
changes, the bootstrap is complete. Everything from that point is a normal
Terraform lifecycle.

AI should behave less like a **code improver** and more like a
**system integrity engineer** — asking at every change:

> *"Does this break the chain from nothing to Terraform control?"*
