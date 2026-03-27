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
# The bootstrap script derives these from the git remote — keep in sync here for Terraform.
# Repo: rhyscraig/aws-terraform-platform-tenant-bootstrap (the seed pipeline repo)
github_oidc_subjects = [
  "repo:rhyscraig/aws-terraform-platform-tenant-bootstrap:ref:refs/heads/main",
  "repo:rhyscraig/aws-terraform-platform-tenant-bootstrap:environment:terrorgem",
]

############################################
# STACKSET
############################################

# Leave empty initially — add OU IDs to deploy the cross-account cicd-role
# into the terrorgem dev/prod accounts via CloudFormation StackSet.
# Run: aws organizations list-organizational-units-for-parent --parent-id <root-id>
# to discover OU IDs, then add them here and re-apply.
target_organizational_unit_ids = []

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
