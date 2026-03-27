locals {
  partition_short_map = {
    aws        = "cmc"
    aws-us-gov = "gvc"
  }

  region_short_map = {
    us-east-1     = "use1"
    us-west-1     = "usw1"
    us-west-2     = "usw2"
    eu-west-1     = "euw1"
    eu-west-2     = "euw2"
    us-gov-west-1 = "usgw1"
    us-gov-east-1 = "usge1"
  }

  partition  = var.partition
  account_id = data.aws_caller_identity.current.account_id

  partition_short = lookup(local.partition_short_map, var.partition, null)
  region_short    = lookup(local.region_short_map, var.aws_region, null)

  name_prefix = join("-", [
    var.org,
    local.partition_short,
    local.region_short,
    var.system
  ])

  tfstate_bucket_name = "${local.name_prefix}-tfstate-${var.environment}"
  logs_bucket_name    = "${local.name_prefix}-logs-${var.environment}"
  kms_alias           = "alias/${local.name_prefix}-tfstate"

  member_role_name          = "${local.name_prefix}-cicd-role"
  member_role_stackset_name = "${local.name_prefix}-member-role"

  tags = merge({
    Name   = local.name_prefix
    System = var.system
  }, var.default_tags)
}
