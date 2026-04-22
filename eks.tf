module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version
  cluster_endpoint_public_access = true
  vpc_id     = var.vpc_id
  subnet_ids = data.aws_subnets.private.ids
  enable_cluster_creator_admin_permissions = true

  access_entries = {
    sso_admin = {
      principal_arn = var.sso_admin_role_arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  cluster_addons = {
    coredns                = {
      most_recent                 = true
      resolve_conflicts_on_update = "OVERWRITE"
    }
    kube-proxy             = {
      most_recent                 = true
      resolve_conflicts_on_update = "OVERWRITE"
    }
    vpc-cni                = {
      most_recent                 = true
      resolve_conflicts_on_update = "OVERWRITE"
    }
    eks-pod-identity-agent = {
      most_recent                 = true
      resolve_conflicts_on_update = "OVERWRITE"
    }
    aws-ebs-csi-driver     = {
      most_recent = true
      # Addon keeps service_account_role_arn pointing at the same role name
      # as before — the underlying role was rebuilt with a Pod Identity trust
      # policy, so the IRSA path is now a no-op. Real creds come from
      # aws_eks_pod_identity_association.ebs_csi (see iam-ebs-csi.tf), which
      # the AWS SDK picks up first in the credential chain.
      service_account_role_arn = aws_iam_role.ebs_csi.arn
    }
  }

  eks_managed_node_groups = merge(
    {
      default = {
        instance_types = var.node_instance_types
        ami_type       = "AL2023_x86_64_STANDARD"
        capacity_type  = "ON_DEMAND"

        desired_size = var.node_desired_size
        min_size     = var.node_min_size
        max_size     = var.node_max_size

        disk_size = 50

        block_device_mappings = {
          xvda = {
            device_name = "/dev/xvda"
            ebs = {
              volume_size = 50
              volume_type = "gp3"
              encrypted   = true
              delete_on_termination = true
            }
          }
        }

        labels = {
          workload = "general"
        }
      }
    },
    var.enable_gpu_node_group ? {
      gpu = {
        instance_types = [var.gpu_instance_type]
        ami_type       = "AL2023_x86_64_NVIDIA"
        capacity_type  = "ON_DEMAND"

        desired_size = 1
        min_size     = 0
        max_size     = 2

        disk_size = 100

        labels = {
          workload      = "gpu"
          "nvidia.com/gpu" = "true"
        }

        taints = [{
          key    = "nvidia.com/gpu"
          value  = "true"
          effect = "NO_SCHEDULE"
        }]
      }
    } : {}
  )

  tags = merge(local.common_tags, {
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  })
}
