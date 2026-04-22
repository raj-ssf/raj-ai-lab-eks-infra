output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_oidc_issuer_url" {
  value = module.eks.cluster_oidc_issuer_url
}

output "vpc_id" {
  value = data.aws_vpc.sandbox.id
}

output "private_subnet_ids" {
  value = data.aws_subnets.private.ids
}

output "public_subnet_ids" {
  value = data.aws_subnets.public.ids
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name} --profile ${var.aws_profile} --alias ${module.eks.cluster_name}"
}