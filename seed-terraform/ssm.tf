############################################
# SSM PARAMETER STORE - PLATFORM OUTPUTS
# These parameters are the "data glue" that
# allows solution repos to self-bootstrap
# their GitHub secrets without hardcoding.
############################################

resource "aws_ssm_parameter" "bootstrap_state_bucket" {
  name        = "/platform/bootstrap/state-bucket"
  description = "Terraform state S3 bucket name (managed by tenant-bootstrap)"
  type        = "String"
  value       = module.state_bucket[0].s3_bucket_id

  tags = local.tags
}

resource "aws_ssm_parameter" "bootstrap_logs_bucket" {
  name        = "/platform/bootstrap/logs-bucket"
  description = "Pipeline logs S3 bucket name (managed by tenant-bootstrap)"
  type        = "String"
  value       = module.logs_bucket[0].s3_bucket_id

  tags = local.tags
}

resource "aws_ssm_parameter" "bootstrap_kms_key_id" {
  name        = "/platform/bootstrap/kms-key-id"
  description = "KMS key ID for state encryption (managed by tenant-bootstrap)"
  type        = "String"
  value       = module.kms_key.key_id

  tags = local.tags
}

resource "aws_ssm_parameter" "bootstrap_kms_key_arn" {
  name        = "/platform/bootstrap/kms-key-arn"
  description = "KMS key ARN for state encryption (managed by tenant-bootstrap)"
  type        = "String"
  value       = module.kms_key.key_arn

  tags = local.tags
}

resource "aws_ssm_parameter" "bootstrap_seed_role_arn" {
  name        = "/platform/bootstrap/seed-role-arn"
  description = "OIDC role ARN for GitHub Actions (managed by tenant-bootstrap)"
  type        = "String"
  value       = module.workloads_oidc_role.arn

  tags = local.tags
}

resource "aws_ssm_parameter" "bootstrap_oidc_provider_arn" {
  name        = "/platform/bootstrap/oidc-provider-arn"
  description = "GitHub OIDC provider ARN (managed by tenant-bootstrap)"
  type        = "String"
  value       = module.oidc_provider.arn

  tags = local.tags
}

resource "aws_ssm_parameter" "bootstrap_name_prefix" {
  name        = "/platform/bootstrap/name-prefix"
  description = "Standard naming prefix: {org}-{partition_short}-{region_short}-{system}"
  type        = "String"
  value       = local.name_prefix

  tags = local.tags
}
