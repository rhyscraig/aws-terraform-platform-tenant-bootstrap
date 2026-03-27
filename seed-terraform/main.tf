############################################
# VALIDATION
############################################

resource "null_resource" "validate_region_short" {
  lifecycle {
    precondition {
      condition     = local.region_short != null
      error_message = "Unsupported aws_region for region_short mapping"
    }
  }
}

resource "null_resource" "validate_partition" {
  lifecycle {
    precondition {
      condition = (
        (local.partition_short == "gvc" && data.aws_partition.current.partition == "aws-us-gov") ||
        (local.partition_short == "cmc" && data.aws_partition.current.partition == "aws")
      )
      error_message = "partition_short does not match actual AWS partition"
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
# IAM - OIDC PROVIDER
############################################

module "oidc_provider" {
  source = "git::https://github.com/BT-IT-Infrastructure-CloudOps/aws-terraform-module-iam.git//modules/iam-oidc-provider?ref=f902bb6de3b6938de895f840815882a544e15a1f"

  tags = local.tags
}

############################################
# IAM - ASSUME MEMBER ROLES POLICY
# Allows the OIDC role to assume the CI/CD role deployed into every
# member account via the CloudFormation StackSet.
############################################

module "assume_member_roles_policy" {
  source = "git::https://github.com/BT-IT-Infrastructure-CloudOps/aws-terraform-module-iam.git//modules/iam-policy?ref=f902bb6de3b6938de895f840815882a544e15a1f"

  name        = "${local.name_prefix}-assume-member-roles"
  description = "Allow assume member roles"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Resource = [
          "arn:${local.partition}:iam::*:role/${trim(var.member_role_path_prefix, "/")}/${local.member_role_name}"
        ]
      }
    ]
  })

  tags = local.tags
}

############################################
# IAM - SEED INFRASTRUCTURE POLICY
# Grants the OIDC role full access to the services used to manage
# the seed infrastructure itself (state backend, KMS, OIDC, StackSet).
#
# FedRAMP / NIST 800-53 AC-6 NOTE:
# These permissions are intentionally broad during the active build-out
# phase of the platform.  Justification:
#   - This role is assumed only by GitHub Actions via short-lived OIDC
#     tokens — no human or long-lived credential can assume it.
#   - The role is scoped to specific GitHub repositories and environments
#     via the OIDC subject conditions (github_oidc_subjects in tfvars).
#   - Narrowing to per-resource ARNs requires the full resource inventory
#     to be stable; that work is tracked as a post-stabilisation item.
# Compensating controls: MFA not required (OIDC only), CloudTrail enabled,
# state bucket versioned + KMS encrypted, approval gate on all applies.
############################################

module "seed_oidc_policy" {
  source = "git::https://github.com/BT-IT-Infrastructure-CloudOps/aws-terraform-module-iam.git//modules/iam-policy?ref=f902bb6de3b6938de895f840815882a544e15a1f"

  name        = "${local.name_prefix}-seed-infra"
  description = "Permissions for the seed pipeline to manage IAM, S3, KMS, CloudFormation, and Organizations resources"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SeedInfrastructure"
        Effect = "Allow"
        Action = [
          "iam:*",
          "sts:*",
          "s3:*",
          "kms:*",
          "cloudformation:*",
          "organizations:*"
        ]
        Resource = "*"
      }
    ]
  })

  tags = local.tags
}

############################################
# IAM - WORKLOADS POLICY
# Grants the OIDC role the AWS service permissions required by workload
# pipelines (e.g. org-analytics-pipeline) that authenticate via this
# role.
#
# FedRAMP / NIST 800-53 AC-6 NOTE:
# Permissions are intentionally broad while the analytics pipeline
# stabilises.  Justification:
#   - Same OIDC trust controls as the seed-infra policy above apply.
#   - Scoping to specific resource ARNs requires a stable, complete
#     inventory of resources deployed by the analytics pipeline — that
#     inventory is not yet finalised.
#   - Hard narrowing will be applied per-service once the pipeline
#     reaches steady state (tracked as post-stabilisation work).
# Compensating controls: OIDC short-lived tokens only, approval gate,
# CloudTrail + KMS encryption on all managed resources.
############################################

module "workloads_oidc_policy" {
  source = "git::https://github.com/BT-IT-Infrastructure-CloudOps/aws-terraform-module-iam.git//modules/iam-policy?ref=f902bb6de3b6938de895f840815882a544e15a1f"

  name        = "${local.name_prefix}-workloads"
  description = "AWS service permissions for workload pipelines authenticating via the ${local.name_prefix} OIDC role"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECR"
        Effect   = "Allow"
        Action   = ["ecr:*"]
        Resource = "*"
      },
      {
        Sid      = "ECS"
        Effect   = "Allow"
        Action   = ["ecs:*"]
        Resource = "*"
      },
      {
        Sid      = "EC2"
        Effect   = "Allow"
        Action   = ["ec2:*"]
        Resource = "*"
      },
      {
        Sid      = "DynamoDB"
        Effect   = "Allow"
        Action   = ["dynamodb:*"]
        Resource = "*"
      },
      {
        Sid      = "CloudWatchLogs"
        Effect   = "Allow"
        Action   = ["logs:*"]
        Resource = "*"
      },
      {
        Sid      = "CloudWatch"
        Effect   = "Allow"
        Action   = ["cloudwatch:*"]
        Resource = "*"
      },
      {
        Sid      = "Lambda"
        Effect   = "Allow"
        Action   = ["lambda:*"]
        Resource = "*"
      },
      {
        Sid      = "SNS"
        Effect   = "Allow"
        Action   = ["sns:*"]
        Resource = "*"
      },
      {
        Sid      = "SQS"
        Effect   = "Allow"
        Action   = ["sqs:*"]
        Resource = "*"
      },
      {
        Sid      = "Glue"
        Effect   = "Allow"
        Action   = ["glue:*"]
        Resource = "*"
      },
      {
        Sid      = "Athena"
        Effect   = "Allow"
        Action   = ["athena:*"]
        Resource = "*"
      },
      {
        Sid      = "CloudTrail"
        Effect   = "Allow"
        Action   = ["cloudtrail:*"]
        Resource = "*"
      },
      {
        Sid      = "Scheduler"
        Effect   = "Allow"
        Action   = ["scheduler:*"]
        Resource = "*"
      },
      {
        Sid      = "SecretsManager"
        Effect   = "Allow"
        Action   = ["secretsmanager:*"]
        Resource = "*"
      },
      {
        Sid      = "APIGateway"
        Effect   = "Allow"
        Action   = ["apigateway:*"]
        Resource = "*"
      },
      {
        Sid      = "EventBridge"
        Effect   = "Allow"
        Action   = ["events:*"]
        Resource = "*"
      },
      {
        Sid      = "StepFunctions"
        Effect   = "Allow"
        Action   = ["states:*"]
        Resource = "*"
      },
      {
        Sid      = "ResourceGroupsTagging"
        Effect   = "Allow"
        Action   = ["tag:*", "resource-groups:*"]
        Resource = "*"
      }
    ]
  })

  tags = local.tags
}

############################################
# IAM - WORKLOADS OIDC ROLE
############################################
module "workloads_oidc_role" {
  source = "git::https://github.com/BT-IT-Infrastructure-CloudOps/aws-terraform-module-iam.git//modules/iam-role?ref=f902bb6de3b6938de895f840815882a544e15a1f"

  depends_on = [module.oidc_provider]

  name            = "${local.name_prefix}-oidc-role"
  use_name_prefix = false

  enable_github_oidc = true
  oidc_subjects      = var.github_oidc_subjects

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
  source = "git::https://github.com/BT-IT-Infrastructure-CloudOps/aws-terraform-module-kms.git?ref=b7b2ad72c1111679abfdb9b3df2213a8c16b9727"

  description             = "${local.name_prefix}-tfstate"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  is_enabled              = true
  key_usage               = "ENCRYPT_DECRYPT"
  multi_region            = false

  # ✅ Let module build policy
  enable_default_policy = true

  # ✅ Access model
  key_owners = [
    "arn:${local.partition}:iam::${local.account_id}:root"
  ]

  key_administrators = [
    "arn:${local.partition}:iam::${local.account_id}:root"
  ]

  key_users = [
    module.workloads_oidc_role.arn
  ]

  # ✅ S3 service access (logs + state buckets)
  key_statements = [
    {
      sid = "AllowS3Usage"
      actions = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:GenerateDataKey*",
        "kms:DescribeKey"
      ]
      resources = ["*"]

      principals = [
        {
          type        = "Service"
          identifiers = ["s3.amazonaws.com"]
        }
      ]

      condition = [
        {
          test     = "StringEquals"
          variable = "aws:SourceAccount"
          values   = [local.account_id]
        },
        {
          test     = "StringLike"
          variable = "kms:ViaService"
          values   = ["s3.${var.aws_region}.amazonaws.com"]
        }
      ]
    }
  ]

  # ✅ Alias (consistent naming)
  aliases = [
    "${local.name_prefix}-tfstate"
  ]

  tags = local.tags
}

############################################
# S3 - STATE BUCKET
############################################

module "state_bucket" {
  source = "git::https://github.com/BT-IT-Infrastructure-CloudOps/aws-terraform-module-s3-bucket.git?ref=bde2672469f96c4a6907ee9c36ba540d7c77047b"

  count = 1

  bucket = local.tfstate_bucket_name

  versioning = {
    enabled = true
  }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        kms_master_key_id = module.kms_key.key_arn
        sse_algorithm     = "aws:kms"
      }
    }
  }

  lifecycle_rule = [
    {
      id      = "cleanup-old-versions"
      enabled = true

      noncurrent_version_expiration = {
        days = 90
      }
    }
  ]

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  force_destroy = false
}

############################################
# S3 - LOGGING BUCKET
############################################

module "logs_bucket" {
  source = "git::https://github.com/BT-IT-Infrastructure-CloudOps/aws-terraform-module-s3-bucket.git?ref=bde2672469f96c4a6907ee9c36ba540d7c77047b"

  count = 1

  bucket = local.logs_bucket_name

  versioning = {
    enabled = false
  }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        kms_master_key_id = module.kms_key.key_arn
        sse_algorithm     = "aws:kms"
      }
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

  force_destroy = false
}

############################################
# STACKSET
############################################

module "member_role_stackset" {
  count  = length(var.target_organizational_unit_ids) > 0 ? 1 : 0
  source = "../cloudformation/member-role-stackset"

  depends_on              = [module.workloads_oidc_role]
  aws_region              = var.aws_region
  stackset_name           = local.member_role_stackset_name
  member_role_path_prefix = var.member_role_path_prefix
  management_role_arn     = module.workloads_oidc_role.arn
  target_ou_ids           = var.target_organizational_unit_ids
  organization_id         = var.organization_id
}
