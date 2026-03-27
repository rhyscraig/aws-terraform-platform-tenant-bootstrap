provider "aws" {
  region = var.aws_region
}

locals {
  runtime_partition = data.aws_partition.current.partition
}

resource "null_resource" "partition_guard" {
  lifecycle {
    precondition {
      condition     = var.partition == local.runtime_partition
      error_message = "Partition mismatch: tfvars (${var.partition}) != runtime (${local.runtime_partition})"
    }
  }
}
