locals {
  common_tags = {
    project     = "raj-ai-lab-eks"
    owner       = "sre"
    role        = "none"
    description = "Raj AI Lab EKS cluster node"
    bu          = "tech-development"
    env         = "dev"
    backup      = "do-not-protect"
    os          = "linux"
    reviewed    = "no"
    audit       = "non-prod"
    environment = "sandbox"
    audit       = "non-prod"
    cost-center = "sre-sandbox"
    managed-by  = "terraform"
    repo        = "raj-ssf/raj-ai-lab-eks-infra"
  }
}