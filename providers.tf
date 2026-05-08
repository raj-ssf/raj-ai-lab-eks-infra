provider "aws" {
  region  = var.region
  profile = var.aws_profile

  assume_role {
    role_arn     = var.terraform_role_arn
    session_name = "terraform-raj-ai-lab"
  }

  default_tags {
    tags = local.common_tags
  }
}

# Myriad TLS-interception note (2026-05-08):
#   On the corporate network/VPN, Palo Alto re-signs HTTPS connections
#   to AWS EKS endpoints with CN=untrusted.myriad.com. Terraform's helm
#   provider uses cluster_ca_certificate from module.eks output to verify
#   the cert, and rejects the inspected one. Setting insecure = true
#   bypasses verification — same fix applied to kubeconfig contexts in
#   ~/.kube/config (see feedback_myriad_tls_interception_personal_aws.md).
#   Drop cluster_ca_certificate alongside since insecure makes it unused.

provider "kubernetes" {
  host     = module.eks.cluster_endpoint
  insecure = true

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region, "--profile", var.aws_profile]
  }
}

provider "helm" {
  kubernetes {
    host     = module.eks.cluster_endpoint
    insecure = true

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region, "--profile", var.aws_profile]
    }
  }
}

provider "kubectl" {
  host             = module.eks.cluster_endpoint
  insecure         = true
  load_config_file = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region, "--profile", var.aws_profile]
  }
}

# Vault provider — authenticates via AppRole. role_id + secret_id come from
# TF_VAR_vault_terraform_role_id / _secret_id, set per session after the
# one-time bootstrap (see vault-approle-bootstrap.sh).
#
# On a fresh cluster the helm_release.vault must exist + be initialized + the
# AppRole must be bootstrapped before any vault_* resource can plan. See
# vault-config.tf header for the bring-up order.
provider "vault" {
  address          = "https://vault.${var.domain}"
  skip_child_token = true

  # Generic auth_login block; v4 vault provider doesn't ship a dedicated
  # auth_login_approle (unlike auth_login_jwt / _aws / _userpass), so we hit
  # the standard approle endpoint directly.
  auth_login {
    path = "auth/approle/login"
    parameters = {
      role_id   = var.vault_terraform_role_id
      secret_id = var.vault_terraform_secret_id
    }
  }
}

# GitHub provider used by argocd-webhook.tf to manage push-event webhooks
# on raj-ssf/raj-ai-lab-eks and raj-ssf/raj-ai-lab-eks-infra. Auth via the
# GITHUB_TOKEN env var — easiest to source from `gh auth token`:
#   export GITHUB_TOKEN=$(gh auth token)
#   terraform apply
# Token needs `admin:repo_hook` scope (creating/deleting repository webhooks).
# A standard `gh auth login --scopes admin:repo_hook` token has it.
provider "github" {
  owner = "raj-ssf"
}