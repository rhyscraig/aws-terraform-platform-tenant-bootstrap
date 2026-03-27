########################################
# CORE IDENTIFIERS
########################################

variable "org" {
  type = string
  validation {
    condition     = length(var.org) > 1 && length(var.org) < 20
    error_message = "org must be between 2 and 20 characters"
  }
}

variable "system" {
  type = string
  validation {
    condition     = length(var.system) > 1 && length(var.system) < 20
    error_message = "system must be between 2 and 20 characters"
  }
}

variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "prd"], var.environment)
    error_message = "environment must be 'dev' or 'prd'"
  }
}

########################################
# AWS PARTITION + REGION
########################################

variable "partition" {
  type = string
  validation {
    condition     = contains(["aws", "aws-us-gov"], var.partition)
    error_message = "partition must be 'aws' or 'aws-us-gov'"
  }
}

variable "aws_region" {
  type = string
  validation {
    condition = contains([
      "us-east-1", "us-west-1", "us-west-2",
      "eu-west-1", "eu-west-2", "us-gov-east-1", "us-gov-west-1"
    ], var.aws_region)
    error_message = "Invalid AWS region"
  }
}

########################################
# OIDC + IAM
########################################

variable "github_oidc_subjects" {
  type = list(string)
  validation {
    condition     = length(var.github_oidc_subjects) > 0
    error_message = "At least one OIDC subject must be provided"
  }
}

variable "member_role_path_prefix" {
  type = string
  validation {
    condition     = can(regex("^/.*$", var.member_role_path_prefix))
    error_message = "member_role_path_prefix must start and end with '/'"
  }
}

########################################
# ORGANIZATION TARGETING
########################################

variable "target_organizational_unit_ids" {
  description = "OUs to deploy the member CI/CD role into via CloudFormation StackSet. When empty, the StackSet module is skipped entirely."
  type        = list(string)
  default     = []
}

########################################
# TAGGING
########################################

variable "default_tags" {
  type    = map(string)
  default = {}
}

########################################
# GITHUB (pipeline metadata — not used by Terraform, read by create-gh-env.sh)
########################################

# tflint-ignore: terraform_unused_declarations
variable "github_approver_teams" {
  description = "GitHub team slugs granted approval rights on the {org}-approve environment. Read by create-gh-env.sh — not used in Terraform resources."
  type        = list(string)
  default     = []
}

########################################
# GUARDRAILS
########################################

variable "expected_account_id" {
  description = "Guard rail: if set, plan fails if the authenticated account does not match"
  type        = string
  default     = ""
}

variable "expected_region" {
  description = "Guard rail: if set, plan fails if the authenticated region does not match"
  type        = string
  default     = ""
}


variable "organization_id" {
  description = "The org id"
  type        = string
}
