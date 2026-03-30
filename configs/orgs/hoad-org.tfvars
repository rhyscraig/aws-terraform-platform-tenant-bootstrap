# Org Details
org             = "hoad-org"
partition       = "aws"
aws_region      = "eu-west-2"
environment     = "prd"
system          = "platform"
organization_id = "o-h07s8pk406"

# Guardrails — plan fails if credentials target the wrong account or region
expected_account_id = "395101865577"
expected_region     = "eu-west-2"

############################################
# IAM
############################################

member_role_path_prefix = "/"

############################################
# GITHUB / OIDC
############################################

# Teams that must approve deployments in the hoad-org-approve GitHub environment.
github_approver_teams = []

# Subjects for the GitHub Actions OIDC trust policy.
# Convention: "repo:<org>/<repo>:environment:<gh-env-name>" or ":ref:refs/heads/main"
github_oidc_subjects = [
  # ── Bootstrap / Seed pipeline (this repo) ──────────────────────────────────
  "repo:rhyscraig/aws-terraform-platform-tenant-bootstrap:ref:refs/heads/main",
  "repo:rhyscraig/aws-terraform-platform-tenant-bootstrap:environment:hoad-org",

  # ── Platform repos (deploy to management account) ──────────────────────────
  "repo:rhyscraig/aws-terraform-platform-aws-org:environment:hoad-org",
  "repo:rhyscraig/aws-terraform-platform-aws-accounts:environment:hoad-org",
  "repo:rhyscraig/aws-terraform-platform-aws-baselines:environment:hoad-org",

  # ── Solution repos (deploy to member accounts via CICD role assumption) ────
  "repo:rhyscraig/aws-terraform-solutions-terrorgem:ref:refs/heads/main",
  "repo:rhyscraig/aws-terraform-solutions-terrorgem:environment:terrorgem-prd",
  "repo:rhyscraig/aws-terraform-solutions-websites:ref:refs/heads/main",
  "repo:rhyscraig/aws-terraform-solutions-websites:environment:hoad-org",
  "repo:rhyscraig/aws-terraform-solutions-banshee:ref:refs/heads/main",
  "repo:rhyscraig/aws-terraform-solutions-banshee:environment:hoad-org",
  "repo:rhyscraig/aws-terraform-solutions-asatst:ref:refs/heads/main",
  "repo:rhyscraig/aws-terraform-solutions-asatst:environment:hoad-org",

  # ── Website repos (deploy static content to production account) ────────────
  "repo:rhyscraig/website-static-html-craighoad.com:environment:hoad-org",
]

############################################
# STACKSET
############################################

target_organizational_unit_ids = [
  "ou-4if6-3ou6vcd6" #Infrastructure
  "ou-4if6-0shp9icd" #Management
  "ou-4if6-1edkqgjc" #Production
  "ou-4if6-qqwvvwvy" #QA
  "ou-4if6-m4l4xw13" #Security
  "ou-4if6-yvxs57c8" #Workloads
]

############################################
# TAGGING
############################################

default_tags = {
  managed-by  = "terraform"
  bootstrap   = "true"
  owner       = "platform"
  environment = "mgmt"
  partition   = "aws"
}
