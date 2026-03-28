locals {
  # Role name matches local.member_role_name in the root module:
  # "${name_prefix}-cicd-role" (stackset_name already contains name_prefix)
  # We drop the stackset suffix so the name is simply "<name_prefix>-cicd-role"
  cicd_role_name = replace(var.stackset_name, "-member-role", "-cicd-role")
}

resource "aws_cloudformation_stack_set" "this" {
  name             = var.stackset_name
  permission_model = "SERVICE_MANAGED"
  call_as          = "SELF"
  capabilities     = ["CAPABILITY_NAMED_IAM"]

  auto_deployment {
    enabled                          = true
    retain_stacks_on_account_removal = false
  }

  template_body = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Resources = {
      MemberRole = {
        Type = "AWS::IAM::Role"
        Properties = {
          # Consistent with local.member_role_name in the root module
          RoleName = local.cicd_role_name
          Path     = var.member_role_path_prefix

          AssumeRolePolicyDocument = {
            Version = "2012-10-17"
            Statement = [{
              # Trust the management account OIDC role to assume this role cross-account
              Effect = "Allow"
              Principal = {
                AWS = var.management_role_arn
              }
              Action = ["sts:AssumeRole", "sts:TagSession"]
            }]
          }

          Policies = [{
            PolicyName = "terraform-execution"
            PolicyDocument = {
              Version = "2012-10-17"
              Statement = [{
                Effect = "Allow"
                Action = [
                  "ec2:*",
                  "iam:*",
                  "s3:*",
                  "kms:*",
                  "logs:*",
                  "cloudwatch:*",
                  "events:*",
                  "lambda:*",
                  "ecs:*",
                  "ecr:*",
                  "autoscaling:*",
                  "elasticloadbalancing:*",
                  "ssm:*",
                  "secretsmanager:*",
                  "rds:*",
                  "dynamodb:*",
                  "cloudformation:*",
                  "route53:*",
                  "acm:*",
                  "cloudfront:*",
                  "apigateway:*",
                  "organizations:Describe*",
                  "organizations:List*",
                  "sts:AssumeRole",
                  "sts:GetCallerIdentity"
                ]
                Resource = "*"
              }]
            }
          }]
        }
      }
    }
  })
}

resource "aws_cloudformation_stack_set_instance" "this" {
  stack_set_name = aws_cloudformation_stack_set.this.name

  deployment_targets {
    organizational_unit_ids = var.target_ou_ids
  }

  stack_set_instance_region = var.aws_region
}
