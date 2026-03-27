# Architecture Diagrams

Visual reference for the bootstrap flow, CI/CD pipeline, and resource ownership model.

---

## 1. End-to-End Bootstrap Flow

```mermaid
flowchart TD
    A["configs/orgs/&lt;org&gt;.tfvars\n(Source of Truth)"]

    A -->|read by generator| B["make generate-cloudshell-script ORG=&lt;org&gt;"]
    B -->|bakes in config + repo URL| C["cloudshell/&lt;org&gt;/&lt;org&gt;-bootstrap.sh\n(generated, gitignored)"]

    C -->|upload + run in browser| D["AWS CloudShell"]

    subgraph ph1["Phase 1 — AWS Resource Creation (idempotent)"]
        P1A["OIDC Provider\ntoken.actions.githubusercontent.com"]
        P1B["IAM Role + Inline Policy\niam:* sts:* s3:* kms:*\ncloudformation:* organizations:*"]
        P1C["KMS Key + Alias"]
        P1D["S3 State Bucket\n(versioning + KMS encryption)"]
        P1E["S3 Logs Bucket\n(lifecycle rules)"]
    end

    D --> ph1
    ph1 -->|prints| EXP["Export block\nSEED_ROLE_ARN, TF_STATE_BUCKET,\nTF_LOGS_BUCKET, KMS_KEY_ID,\nKMS_ALIAS, AWS_REGION"]

    subgraph ph2["Phase 2 — Terraform Imports (inside CloudShell)"]
        P2A["Auto-install Terraform 1.14.5 → ~/bin"]
        P2B["Clone repo → /tmp/seed-repo\n(uses GITHUB_TOKEN)"]
        P2C["Configure git credentials\n(for private modules)"]
        P2D["terraform init -reconfigure"]
        P2E["terraform import × 7\n(skip-if-already-in-state)"]
    end

    D --> ph2
    ph2 -->|writes| STATE["S3 State\n&lt;org&gt;/&lt;partition&gt;/control-plane/terraform.tfstate"]

    EXP -->|copy + paste| LOCAL["Local terminal\n(session-scoped env vars)"]
    LOCAL -->|trigger| GH["make create-github-environment ORG=&lt;org&gt;"]
    GH -->|push 6 secrets| ENV["GitHub Environment: &lt;org&gt;\nSEED_ROLE_ARN · TF_STATE_BUCKET\nTF_LOGS_BUCKET · KMS_KEY_ID\nORG_GITHUB_TOKEN · PLAN_PASSPHRASE"]
    GH -->|set required reviewers| ENVAPP["GitHub Environment: &lt;org&gt;-approve\n(approval gate — no secrets)\nReviewers from github_approver_teams"]

    ENV -->|trigger workflow| PIPE["terraform-deploy.yml\norg only — partition + region\nread from tfvars at runtime"]
    PIPE -->|✅ No changes| DONE["Fully bootstrapped\nTerraform-managed control plane"]

    style ph1 fill:#fff3e0,stroke:#f57c00
    style ph2 fill:#f3e5f5,stroke:#7b1fa2
    style DONE fill:#e8f5e9,stroke:#2e7d32
```

---

## 2. GitHub Actions Pipeline Flow

> **Note:** The workflow accepts a single input (`org`). Partition and region are derived automatically from `configs/orgs/<org>.tfvars` at runtime and exported into the job environment.

```mermaid
flowchart LR
    TRIG["workflow_dispatch\norg"]

    subgraph PLAN["Plan Job (ubuntu-latest)"]
        direction TB
        V1["Validate tfvars exists\nValidate secrets present"]
        RC["Read org config from tfvars\npartition · aws_region → GITHUB_ENV"]
        AUTH1["OIDC auth\nassume SEED_ROLE_ARN"]
        GIT1["Configure git\nprivate module access"]
        INIT1["terraform init\ndynamic -backend-config ×5\nRetry 3×"]
        TF_PLAN["terraform plan\n-var-file\n-out=tfplan"]
        HASH["sha256sum tfplan\n→ plan.hash\nGITHUB_SHA → commit.sha"]
        ENC["openssl enc -aes-256-cbc\ntfplan → tfplan.enc\npassphrase = PLAN_PASSPHRASE"]
        ART["Upload artifact\ntfplan.enc · plan.hash · commit.sha"]

        V1 --> RC --> AUTH1 --> GIT1 --> INIT1 --> TF_PLAN --> HASH --> ENC --> ART
    end

    subgraph APPLY["Apply Job (ubuntu-latest)"]
        direction TB
        DL["Download artifact"]
        DEC["Decrypt tfplan.enc\nVerify SHA256 hash\nVerify commit SHA"]
        AUTH2["OIDC auth\nassume SEED_ROLE_ARN"]
        GIT2["Configure git\nprivate module access"]
        INIT2["terraform init\nsame dynamic backend\nRetry 3×"]
        TF_APPLY["terraform apply tfplan\nRetry 3×"]
        SAVED["State persisted to S3"]

        DL --> DEC --> AUTH2 --> GIT2 --> INIT2 --> TF_APPLY --> SAVED
    end

    TRIG --> PLAN
    ART -->|Manual approval\n&lt;org&gt;-approve environment| APPLY

    style PLAN fill:#e3f2fd,stroke:#1565c0
    style APPLY fill:#e8f5e9,stroke:#2e7d32
```

---

## 3. Resource Ownership Model

```mermaid
flowchart TB
    subgraph CS["CloudShell Phase 1\n(idempotent AWS API calls)"]
        direction LR
        R1["OIDC Provider"]
        R2["IAM Role"]
        R3["Bootstrap Inline Policy"]
        R4["KMS Key + Alias"]
        R5["S3 State Bucket"]
        R6["S3 Logs Bucket"]
    end

    subgraph IMP["CloudShell Phase 2\nterraform import (skip-if-in-state)"]
        direction LR
        I1["import: OIDC Provider"]
        I2["import: IAM Role"]
        I4["import: KMS Key"]
        I5["import: KMS Alias"]
        I6["import: State Bucket"]
        I7["import: Logs Bucket"]
        I8["import: Assume-Member-Roles\nPolicy (conditional —\nonly if prior apply failed)"]
    end

    subgraph TF["Terraform apply\n(created fresh — no import needed)"]
        direction LR
        T1["S3 sub-resources\n(versioning, lifecycle,\nencryption, public-access-block)"]
        T2["IAM role policy\nattachment"]
        T3["Assume-Member-Roles\nIAM Policy"]
        T4["KMS Key Policy"]
        T5["CloudFormation StackSet\n+ StackSet Instance\n→ deploys cicd-role to all OUs"]
        T6["null_resource\nvalidation guards"]
    end

    R1 --> I1
    R2 --> I2
    R4 --> I4
    R4 --> I5
    R5 --> I6
    R6 --> I7
    R3 -.->|"only if exists\nin AWS"| I8

    I1 & I2 & I4 & I5 & I6 & I7 & I8 -->|"Terraform owns\nfrom this point"| TF

    style CS fill:#fff3e0,stroke:#f57c00
    style IMP fill:#f3e5f5,stroke:#7b1fa2
    style TF fill:#e8f5e9,stroke:#2e7d32
```

---

## 4. Naming System

All resource names derive from a single formula in `seed-terraform/locals.tf`:

```
name_prefix = <org> - <partition_short> - <region_short> - <system>
```

| tfvars field | Example | Contribution |
|---|---|---|
| `org` | `fedramp` | prefix segment 1 |
| `partition` | `aws` | → `partition_short = cmc` |
| `aws_region` | `us-east-1` | → `region_short = use1` |
| `system` | `infra-cloudops` | prefix segment 4 |
| **Result** | | `fedramp-cmc-use1-infra-cloudops` |

| Resource | Full name |
|---|---|
| S3 state bucket | `<name_prefix>-tfstate-<env>` |
| S3 logs bucket | `<name_prefix>-logs-<env>` |
| KMS alias | `alias/<name_prefix>-tfstate` |
| OIDC role (mgmt account) | `<name_prefix>-oidc-role` |
| Assume-member-roles policy | `<name_prefix>-assume-member-roles` |
| CloudFormation StackSet | `<name_prefix>-member-role` |
| CI/CD role (member accounts) | `<name_prefix>-cicd-role` |

> **Naming is a hard contract** — changing any segment breaks imports, the S3 backend key, cross-account role assumptions, and CI/CD trust.
