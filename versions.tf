terraform {
  required_version = ">= 1.8"


  backend "s3" {
      bucket         = "terraform-tf-state-raj-ai-lab-eks"
      key            = "raj-ai-lab-eks/terraform.tfstate"
      region         = "us-west-2"
      encrypt        = true
      use_lockfile   = true
}

  required_providers {
    aws        = { source = "hashicorp/aws",        version = "~> 5.70" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.33" }
    helm       = { source = "hashicorp/helm",       version = "~> 2.15" }
    tls        = { source = "hashicorp/tls",        version = "~> 4.0" }
    kubectl    = { source = "alekc/kubectl",        version = "~> 2.1" }
  }
}