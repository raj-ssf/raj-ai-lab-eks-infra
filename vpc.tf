data "aws_vpc" "sandbox" {
  id = var.vpc_id
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }

  filter {
    name   = "tag:Name"
    values = ["*Private*"]
  }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }

  filter {
    name   = "tag:Name"
    values = ["*Public*"]
  }
}

# data.aws_subnets.gpu_az_private — removed 2026-04-24. Karpenter's
# EC2NodeClass now selects subnets via its own tag-match (see
# karpenter-nodepool.tf), and the AZ pin lives in the NodePool's
# topology.kubernetes.io/zone requirement.

data "aws_subnet" "private" {
  for_each = toset(data.aws_subnets.private.ids)
  id       = each.value
}

data "aws_subnet" "public" {
  for_each = toset(data.aws_subnets.public.ids)
  id       = each.value
}
