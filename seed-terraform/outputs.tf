output "workloads_oidc_role_arn" {
  value       = module.workloads_oidc_role.arn
  description = "Management account workloads OIDC role ARN"
}

output "state_bucket_name" {
  value       = module.state_bucket[0].s3_bucket_id
  description = "Terraform state bucket name"
}

output "logs_bucket_name" {
  value       = module.logs_bucket[0].s3_bucket_id
  description = "Logging bucket name"
}

output "state_kms_key_arn" {
  value       = module.kms_key.key_arn
  description = "Terraform state bucket KMS key ARN"
}

output "kms_alias" {
  value       = local.kms_alias
  description = "KMS alias used for state encryption"
}

output "oidc_provider_arn" {
  value       = module.oidc_provider.arn
  description = "OIDC provider ARN"
}
