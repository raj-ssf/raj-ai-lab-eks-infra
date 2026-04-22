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

variable "enable_gpu_node_group" {
  description = "Enable GPU Node Group"
  type    = bool
  default = false
}

variable "gpu_instance_type" {
  description = "AWS GPU Instance Type"
  type    = string
  default = "g4dn.xlarge"
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