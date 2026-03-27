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

# Teams that must approve deployments in the fdr-gvc-approve GitHub environment.
# Add team slugs to expand the approver group — create-gh-env.sh resolves them to IDs.
github_approver_teams = ["is-cloudops"]

# Subjects for the GitHub Actions OIDC trust policy.
# Format: repo:<github-org>/<repo>:environment:<tfvars-filename>
# The bootstrap script derives these automatically — keep in sync here for Terraform.
github_oidc_subjects = [
  # Seed pipeline (self)
  "repo:BT-IT-Infrastructure-CloudOps/aws-terraform-platform-tenant-seed:ref:refs/heads/main",
  "repo:BT-IT-Infrastructure-CloudOps/aws-terraform-platform-tenant-seed:environment:hoad-org.tfvars",
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
