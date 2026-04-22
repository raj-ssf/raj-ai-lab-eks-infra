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

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region, "--profile", var.aws_profile]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region, "--profile", var.aws_profile]
    }
  }
}

provider "kubectl" {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    load_config_file       = false

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