module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version
  cluster_endpoint_public_access = true
  vpc_id     = var.vpc_id
  subnet_ids = data.aws_subnets.private.ids
  enable_cluster_creator_admin_permissions = true

  # IRSA OIDC provider is unused since the Pod Identity migration (all 5
  # workloads now use aws_eks_pod_identity_association). Disabling removes
  # the orphaned aws_iam_openid_connect_provider and keeps IAM clean.
  enable_irsa = false

  # Module's default node SG only opens 1025-65535/tcp between nodes, which
  # blocks cross-node pod-to-pod traffic on low ports (80, 443, 8443, etc.).
  # Broke argocd-server / grafana → ingress-nginx:443 calls needed for OIDC
  # discovery. Open all protocols/ports between nodes.
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node-to-node: all ports/protocols (pod-to-pod on low ports)"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    # Cluster SG (EKS apiserver) → node SG on all ports. Default module only
    # opens 443/4443/6443/8443/9443/10250, which silently drops webhook
    # traffic to pods listening on other ports (Vault Agent Injector on 8080
    # is the case that bit us). failurePolicy=Ignore on the webhook means no
    # visible error — pods are created without mutation.
    ingress_cluster_all = {
      description                   = "Cluster apiserver to node: all ports (webhook targets)"
      protocol                      = "-1"
      from_port                     = 0
      to_port                       = 0
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

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
      # Rewrite keycloak.<domain> to the in-cluster ingress-nginx Service.
      # Without this, pods resolving keycloak.<domain> get the NLB public IP
      # and AWS drops the hairpin loopback with "connection reset by peer".
      # This full Corefile mirrors the EKS default + one `rewrite` line.
      configuration_values = jsonencode({
        corefile = <<-EOT
          .:53 {
              errors
              health {
                  lameduck 5s
              }
              ready
              rewrite name keycloak.${var.domain} ingress-nginx-controller.ingress-nginx.svc.cluster.local
              kubernetes cluster.local in-addr.arpa ip6.arpa {
                  pods insecure
                  fallthrough in-addr.arpa ip6.arpa
              }
              prometheus :9153
              forward . /etc/resolv.conf
              cache 30
              loop
              reload
              loadbalance
          }
        EOT
      })
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
        # max_size=1 is intentional: on a 4-A10G cost-sensitive lab, we never
        # want the managed nodegroup to burst above 1 instance during a
        # rolling update. Earlier (2026-04-24) an eks.tf edit triggered a
        # runaway replacement loop — launch-template version bumps caused
        # overlapping rolls that bursted to 11 tracked + ~18 cycled
        # instances before Ctrl-C + manual cleanup. Capping max_size=1
        # means any future LT change will terminate-then-launch (with
        # vllm downtime during replacement) rather than burst-then-drain.
        # That's the right tradeoff for a lab running on-demand compute.
        max_size = 1

        # Root disk sized via block_device_mappings only. DO NOT also set
        # `disk_size` at the same level — that's the footgun from the
        # 2026-04-24 incident. The EKS module emits one LT param for each
        # and the drift resolution between them triggers cascading LT
        # versions → cascading rolls. block_device_mappings is the more
        # expressive form (volume_type/encrypted/throughput control) so
        # it's the one to keep.
        #
        # Sizing rationale — 200 GiB root:
        #   AL2023_x86_64_NVIDIA OS + drivers + CUDA libs consume ~25 GiB.
        #   containerd's extraction of vllm/vllm-openai (~15 GiB compressed,
        #   ~40 GiB extracted in overlayfs) needs transient headroom.
        #   100 GiB blew kubelet's eviction threshold mid-pull. 200 GiB
        #   leaves comfortable margin for the image + logs + any future
        #   add-ons (DCGM exporter, etc.).
        block_device_mappings = {
          xvda = {
            device_name = "/dev/xvda"
            ebs = {
              volume_size           = 200
              volume_type           = "gp3"
              encrypted             = true
              delete_on_termination = true
            }
          }
        }

        labels = {
          workload              = "gpu"
          "nvidia.com/gpu"      = "true"
          # NVIDIA-GPU-Operator convention label; we're not running the
          # Operator (AL2023_x86_64_NVIDIA AMI + device plugin is enough
          # for this lab) but the label key is what nodeSelectors target
          # across the industry — matches the vllm Deployment in the app
          # repo without a bespoke label.
          "nvidia.com/gpu.present" = "true"
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
