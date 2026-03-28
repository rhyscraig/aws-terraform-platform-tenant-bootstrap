# Org Details
org             = "terrorgem"
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

# Teams that must approve deployments in the terrorgem-approve GitHub environment.
github_approver_teams = []

# Subjects for the GitHub Actions OIDC trust policy.
# Add an entry for each repo + environment that needs to authenticate via OIDC.
# Convention: "repo:<org>/<repo>:environment:<gh-env-name>"
github_oidc_subjects = [
  # Seed pipeline (this repo) — hoad-org environment
  "repo:rhyscraig/aws-terraform-platform-tenant-bootstrap:ref:refs/heads/main",
  "repo:rhyscraig/aws-terraform-platform-tenant-bootstrap:environment:hoad-org",

  # Terrorgem solution — production deployment
  "repo:rhyscraig/aws-terraform-solutions-terrorgem:ref:refs/heads/main",
  "repo:rhyscraig/aws-terraform-solutions-terrorgem:environment:terrorgem-prd",
]

############################################
# STACKSET
############################################

# OU IDs to deploy the cross-account cicd-role into member accounts via StackSet.
# ou-4if6-1edkqgjc = Production OU (account 767828739298)
target_organizational_unit_ids = ["ou-4if6-1edkqgjc"]

############################################
# TAGGING
############################################

default_tags = {
  managed-by  = "terraform"
  bootstrap   = "true"
  owner       = "terrorgem"
  environment = "mgmt"
  partition   = "aws"
}
