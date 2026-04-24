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

# Private subnets filtered to a single AZ, used by the GPU node group so the
# GPU node always lands in the same AZ as the vllm-model-cache PVC's EBS
# volume. Configurable via var.gpu_az (see variables.tf for the rationale).
data "aws_subnets" "gpu_az_private" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }

  filter {
    name   = "tag:Name"
    values = ["*Private*"]
  }

  filter {
    name   = "availability-zone"
    values = [var.gpu_az]
  }
}

data "aws_subnet" "private" {
  for_each = toset(data.aws_subnets.private.ids)
  id       = each.value
}

data "aws_subnet" "public" {
  for_each = toset(data.aws_subnets.public.ids)
  id       = each.value
}
