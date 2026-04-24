variable "region" {
  description = "AWS region"
  type    = string
  default = "us-west-2"
}

variable "aws_profile" {
  type    = string
  default = "raj"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type    = string
  default = "raj-ai-lab-eks"
}

variable "cluster_version" {
  description = "Kubernetes version"
  type    = string
  default = "1.34"
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
  default     = "var.vpc_id"
}

variable "node_instance_types" {
  description = "AWS Instance Type"
  type    = list(string)
  default = ["m5.xlarge"]
}

variable "node_desired_size" {
  description = "AWS Instance Desired Size"
  type    = number
  default = 3 
}

variable "node_min_size" {
  description = "AWS Instance Minimum Size"
  type    = number
  default = 3
}

variable "node_max_size" {
  description = "AWS Instance Maximum Size"
  type    = number
  default = 6
}

# enable_gpu_node_group / gpu_instance_type / gpu_az — removed 2026-04-24.
# Karpenter (see karpenter.tf + karpenter-nodepool.tf) now owns GPU node
# provisioning. Instance types are listed directly in the NodePool's
# requirements block, AZ is pinned there to match the PVC zone, and the
# enable toggle is obsolete — pods drive provisioning via
# `kubectl scale deployment vllm`.

variable "private_subnet_name_pattern" {
  description = <<-EOT
    Tag-Name pattern used by Karpenter's EC2NodeClass.subnetSelectorTerms to
    discover private subnets in the cluster's VPC. The pattern must uniquely
    match this VPC's private subnets and NOT subnets of other VPCs in the
    account (Karpenter would otherwise pick a subnet from a different VPC
    and fail with "Security group and subnet belong to different networks").
    Real value set in terraform.tfvars since it identifies the hosting VPC.
  EOT
  type    = string
  default = "*Private*"
}

variable "rds_instance_class" {
  description = "AWS RDS Instance Type"
  type    = string
  default = "db.r6g.large"
}

variable "rds_database_name" {
  description = "AWS RDS DB Name"
  type    = string
  default = "rajailab"
}

variable "rds_username" {
  description = "AWS RDS DB User"
  type    = string
  default = "rajailab"
}

variable "sso_admin_role_arn" {
    type = string
  }

variable "terraform_role_arn" {
    type = string
  }

variable "domain" {
    description = "Apex domain for the cluster (e.g., ekstest.com)"
    type        = string
  }

  variable "acme_email" {
    description = "Email for ACME account registration and Let's Encrypt expiry notifications"
    type        = string
    sensitive   = true
  }

  variable "argocd_app_repo_url" {
    type        = string
    description = "Git SSH URL for the ArgoCD-managed app repo"
    # Set in terraform.tfvars; example: git@github.com:<owner>/<repo>.git
  }

  variable "argocd_app_repo_ssh_key" {
    type        = string
    description = "SSH private key (PEM) for ArgoCD to clone the app repo"
    sensitive   = true
  }

  variable "gha_repo_owner" {
    type        = string
    description = "GitHub org/user owning the app repo"
  }

  variable "gha_repo_name" {
    type        = string
    description = "GitHub repo name containing the GHA workflow"
  }

  variable "grafana_admin_password" {
    type        = string
    description = "Initial admin password for Grafana — rotate via UI once logged in"
    sensitive   = true
  }

  variable "keycloak_admin_password" {
    type        = string
    description = "Bootstrap admin password for the Keycloak master realm"
    sensitive   = true
  }

  variable "keycloak_db_password" {
    type        = string
    description = "Password for the Postgres 'keycloak' user backing Keycloak"
    sensitive   = true
  }

  # --- Langfuse API keys for rag-service --------------------------------------
  # Minted once in the Langfuse UI (Settings → API Keys → Create New Key) and
  # pasted into terraform.tfvars. Public key is safe to commit (prefix 'pk-lf-')
  # but kept in tfvars alongside the secret for operational simplicity.
  variable "langfuse_public_key" {
    type        = string
    description = "Langfuse public key (pk-lf-...) minted in the Langfuse UI project settings"
    default     = ""
  }

  variable "langfuse_secret_key" {
    type        = string
    description = "Langfuse secret key (sk-lf-...) minted in the Langfuse UI project settings"
    sensitive   = true
    default     = ""
  }

  # --- Vault AppRole auth for Terraform itself ---
  # Bootstrap is manual (one-time, after `vault operator init`). See
  # vault-approle-bootstrap.sh for the script that creates the role and
  # fetches these values. Export as TF_VAR_* each session.
  variable "vault_terraform_role_id" {
    type        = string
    description = "Role ID of the Vault AppRole used by the terraform provider. Not a secret but scoped."
    default     = ""
  }

  variable "vault_terraform_secret_id" {
    type        = string
    description = "Secret ID for the terraform AppRole. Sensitive — regenerate per session if you want short TTL."
    sensitive   = true
    default     = ""
  }