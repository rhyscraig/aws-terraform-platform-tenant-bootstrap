variable "stackset_name" {
  type = string
}

variable "member_role_path_prefix" {
  type = string
}

# tflint-ignore: terraform_unused_declarations
variable "management_role_arn" {
  description = "ARN of the OIDC role in the management account. Passed for reference — consumed by the calling module, not directly referenced in this StackSet template."
  type        = string
}

variable "target_ou_ids" {
  type = list(string)
}

variable "organization_id" {
  description = "The org id"
  type        = string
}


variable "aws_region" {
  description = "The deployment region"
  type        = string
}
