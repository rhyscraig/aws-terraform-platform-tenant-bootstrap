############################################
# VALIDATION GUARDRAILS
############################################

resource "null_resource" "validate_region_short" {
  lifecycle {
    precondition {
      condition     = local.region_short != null
      error_message = "Unsupported aws_region for region_short mapping"
    }
  }
}

resource "null_resource" "validate_account" {
  lifecycle {
    precondition {
      condition     = var.expected_account_id == "" || data.aws_caller_identity.current.account_id == var.expected_account_id
      error_message = "Wrong AWS account: expected ${var.expected_account_id}, got ${data.aws_caller_identity.current.account_id}"
    }
  }
}

resource "null_resource" "validate_region" {
  lifecycle {
    precondition {
      condition     = var.expected_region == "" || data.aws_region.current.id == var.expected_region
      error_message = "Wrong AWS region: expected ${var.expected_region}, got ${data.aws_region.current.id}"
    }
  }
}

############################################
# IAM - GITHUB OIDC PROVIDER
############################################

module "oidc_provider" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-github-oidc-provider"
  version = "6.4.0"

  # Defaults to token.actions.githubusercontent.com + sts.amazonaws.com audience.
  # Module auto-fetches current thumbprint(s) + includes well-known GitHub ones.

  tags = local.tags
}

############################################
# IAM - ASSUME MEMBER ROLES POLICY
############################################

module "assume_member_roles_policy" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-policy"
  version = "6.4.0"

  name        = "${local.name_prefix}-assume-member-roles"
  description = "Allow the OIDC role to assume the CI/CD role in member accounts"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = ["arn:${local.partition}:iam::*:role${var.member_role_path_prefix}${local.member_role_name}"]
    }]
  })

  tags = local.tags
}

############################################
# IAM - SEED INFRASTRUCTURE POLICY
############################################

module "seed_oidc_policy" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-policy"
  version = "6.4.0"

  name        = "${local.name_prefix}-seed-infra"
  description = "Permissions for the seed pipeline to manage IAM, S3, KMS, CloudFormation, and Organizations"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "SeedInfrastructure"
      Effect   = "Allow"
      Action   = ["iam:*", "sts:*", "s3:*", "kms:*", "cloudformation:*", "organizations:*"]
      Resource = "*"
    }]
  })

  tags = local.tags
}

############################################
# IAM - WORKLOADS POLICY
############################################

module "workloads_oidc_policy" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-policy"
  version = "6.4.0"

  name        = "${local.name_prefix}-workloads"
  description = "AWS service permissions for workload pipelines authenticating via the ${local.name_prefix} OIDC role"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "ECR",        Effect = "Allow", Action = ["ecr:*"],            Resource = "*" },
      { Sid = "ECS",        Effect = "Allow", Action = ["ecs:*"],            Resource = "*" },
      { Sid = "EC2",        Effect = "Allow", Action = ["ec2:*"],            Resource = "*" },
      { Sid = "DynamoDB",   Effect = "Allow", Action = ["dynamodb:*"],       Resource = "*" },
      { Sid = "Logs",       Effect = "Allow", Action = ["logs:*"],           Resource = "*" },
      { Sid = "CloudWatch", Effect = "Allow", Action = ["cloudwatch:*"],     Resource = "*" },
      { Sid = "Lambda",     Effect = "Allow", Action = ["lambda:*"],         Resource = "*" },
      { Sid = "SNS",        Effect = "Allow", Action = ["sns:*"],            Resource = "*" },
      { Sid = "SQS",        Effect = "Allow", Action = ["sqs:*"],            Resource = "*" },
      { Sid = "Glue",       Effect = "Allow", Action = ["glue:*"],           Resource = "*" },
      { Sid = "Athena",     Effect = "Allow", Action = ["athena:*"],         Resource = "*" },
      { Sid = "CloudTrail", Effect = "Allow", Action = ["cloudtrail:*"],     Resource = "*" },
      { Sid = "Scheduler",  Effect = "Allow", Action = ["scheduler:*"],      Resource = "*" },
      { Sid = "Secrets",    Effect = "Allow", Action = ["secretsmanager:*"], Resource = "*" },
      { Sid = "APIGateway", Effect = "Allow", Action = ["apigateway:*"],     Resource = "*" },
      { Sid = "Events",     Effect = "Allow", Action = ["events:*"],         Resource = "*" },
      { Sid = "StepFunc",   Effect = "Allow", Action = ["states:*"],         Resource = "*" },
      { Sid = "Tagging",    Effect = "Allow", Action = ["tag:*", "resource-groups:*"], Resource = "*" },
    ]
  })

  tags = local.tags
}

############################################
# IAM - WORKLOADS OIDC ROLE
############################################

module "workloads_oidc_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-github-oidc-role"
  version = "6.4.0"

  depends_on = [module.oidc_provider]

  name = "${local.name_prefix}-oidc-role"

  # Module strips any leading "repo:" and re-adds it — safe to pass full subjects.
  subjects = var.github_oidc_subjects

  policies = {
    AssumeMemberRoles = module.assume_member_roles_policy.arn
    SeedInfraPolicy   = module.seed_oidc_policy.arn
    WorkloadsPolicy   = module.workloads_oidc_policy.arn
  }

  tags = local.tags
}

############################################
# KMS KEY
############################################

module "kms_key" {
  source  = "terraform-aws-modules/kms/aws"
  version = "4.2.0"

  description             = "${local.name_prefix}-tfstate"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  key_owners = [
    "arn:${local.partition}:iam::${local.account_id}:root"
  ]

  key_users = [
    module.workloads_oidc_role.arn
  ]

  # S3 service access for server-side encryption
  source_policy_documents = [
    data.aws_iam_policy_document.kms_s3_access.json
  ]

  aliases = ["${local.name_prefix}-tfstate"]

  tags = local.tags
}

data "aws_iam_policy_document" "kms_s3_access" {
  statement {
    sid     = "AllowS3Usage"
    effect  = "Allow"
    actions = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

############################################
# S3 - STATE BUCKET
############################################

module "state_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.11.0"

  count = 1

  bucket        = local.tfstate_bucket_name
  force_destroy = false

  versioning = {
    enabled = true
  }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        kms_master_key_id = module.kms_key.key_arn
        sse_algorithm     = "aws:kms"
      }
      bucket_key_enabled = true
    }
  }

  lifecycle_rule = [
    {
      id      = "cleanup-old-versions"
      enabled = true

      noncurrent_version_expiration = {
        noncurrent_days = 90
      }
    }
  ]

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  tags = local.tags
}

############################################
# S3 - LOGS BUCKET
############################################

module "logs_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.11.0"

  count = 1

  bucket        = local.logs_bucket_name
  force_destroy = false

  versioning = {
    enabled = false
  }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        kms_master_key_id = module.kms_key.key_arn
        sse_algorithm     = "aws:kms"
      }
      bucket_key_enabled = true
    }
  }

  lifecycle_rule = [
    {
      id      = "expire-logs"
      enabled = true

      expiration = {
        days = 30
      }
    }
  ]

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  tags = local.tags
}

############################################
# CLOUDFORMATION STACKSET (optional)
# Deploy the cross-account cicd-role into member account OUs.
# Set target_organizational_unit_ids in tfvars to enable.
############################################

module "member_role_stackset" {
  count  = length(var.target_organizational_unit_ids) > 0 ? 1 : 0
  source = "../cloudformation/member-role-stackset"

  depends_on = [module.workloads_oidc_role]

  aws_region              = var.aws_region
  stackset_name           = local.member_role_stackset_name
  member_role_path_prefix = var.member_role_path_prefix
  management_role_arn     = module.workloads_oidc_role.arn
  target_ou_ids           = var.target_organizational_unit_ids
  organization_id         = var.organization_id
}
