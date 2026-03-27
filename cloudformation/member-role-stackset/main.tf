locals {
  name_prefix = var.stackset_name
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
          RoleName = "${local.name_prefix}-cicd-role"
          Path     = var.member_role_path_prefix

          AssumeRolePolicyDocument = {
            Version = "2012-10-17"
            Statement = [{
              Effect = "Allow"
              Principal = {
                Service = "cloudformation.amazonaws.com"
              }
              Action = "sts:AssumeRole"
              Condition = {
                StringEquals = {
                  "aws:PrincipalOrgID" = var.organization_id
                }
              }
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
