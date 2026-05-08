module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name                             = var.cluster_name
  cluster_version                          = var.cluster_version
  cluster_endpoint_public_access           = true
  vpc_id                                   = var.vpc_id
  subnet_ids                               = data.aws_subnets.private.ids
  enable_cluster_creator_admin_permissions = true

  # IRSA OIDC provider unused since the Pod Identity migration — every
  # workload that needs AWS API access goes through
  # aws_eks_pod_identity_association (current count is in the
  # double digits across model-weights.tf, eval.tf, langgraph.tf,
  # ingestion-service.tf, chat-ui.tf, training.tf, plus the platform
  # bindings for karpenter/ALB/cert-manager/external-dns/EBS CSI/etc.;
  # see `aws eks list-pod-identity-associations` for the live list).
  # Disabling enable_irsa removes the orphaned
  # aws_iam_openid_connect_provider and keeps IAM clean. The one
  # leftover IRSA artifact — the eks.amazonaws.com/role-arn annotation
  # on kube-system/ebs-csi-controller-sa — is documented in the
  # aws-ebs-csi-driver block below (kept due to an SCP that blocks
  # UpdateAddon when removing service_account_role_arn).
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
    coredns = {
      most_recent                 = true
      resolve_conflicts_on_update = "OVERWRITE"
      # Cilium-migration note (Phase 1a):
      #   computeType = "Fargate" tells the addon to remove the EC2 node
      #   affinity (eks.amazonaws.com/compute-type=ec2) so CoreDNS pods
      #   match the Fargate profile selector below. Without this flag,
      #   the addon-managed Deployment fights the Fargate scheduler and
      #   pods stay Pending forever.
      #
      # Phase 3 will re-add the in-cluster rewrite — at that point
      # pointing at the Cilium Gateway Service (cilium-gateway-... in
      # gateway-system) instead of the Istio Gateway Service the old
      # cluster used. For now (Phase 1a) keep the corefile minimal.
      configuration_values = jsonencode({
        computeType = "Fargate"
        corefile = <<-EOT
          .:53 {
              errors
              health {
                  lameduck 5s
              }
              ready
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
    kube-proxy = {
      most_recent                 = true
      resolve_conflicts_on_update = "OVERWRITE"
    }
    # vpc-cni REMOVED 2026-05-08 — Cilium native CNI replaces it.
    # Cilium installs via helm in cilium.tf BEFORE Karpenter provisions
    # any EC2 nodes, so VPC CNI's IP-allocation role is fully replaced.
    eks-pod-identity-agent = {
      most_recent                 = true
      resolve_conflicts_on_update = "OVERWRITE"
    }
    # Phase #68: metrics-server addon. The cluster shipped without
    # metrics-server (the original config focused on data-plane add-
    # ons); discovered when Phase #60 (istiod HPA) and Phase #67
    # (rag/langgraph/ingestion/chat-ui HPAs) all showed
    # `cpu: <unknown>/70%`. Without metrics-server, HPAs can't make
    # CPU-based scaling decisions, `kubectl top` fails, and many
    # core dashboards in Grafana show empty data.
    #
    # EKS managed addon (vs running the helm chart directly):
    # auto-updates with EKS version bumps, AWS-handled HA, no
    # serviceAccount/IRSA wiring needed (the addon ships the SA
    # bound to the necessary cluster-internal RBAC). For a lab on
    # EKS, this is the lowest-friction path.
    #
    # Once this addon is Active, the HPAs from #60 + #67 start
    # reading actual pod CPU and the `<unknown>` placeholders
    # disappear within ~30s.
    metrics-server = {
      most_recent                 = true
      resolve_conflicts_on_update = "OVERWRITE"
    }
    aws-ebs-csi-driver = {
      most_recent = true
      # Pod Identity is the working credential path (see iam-ebs-csi.tf:
      # aws_iam_role.ebs_csi with pod_identity_trust + the matching
      # aws_eks_pod_identity_association). The IRSA path through
      # service_account_role_arn is a no-op — enable_irsa = false on
      # this module disables the OIDC provider entirely, so the
      # eks.amazonaws.com/role-arn annotation that the EKS add-on sets
      # on ebs-csi-controller-sa cannot resolve.
      #
      # We attempted to clean this up on 2026-04-29 by removing
      # service_account_role_arn, but UpdateAddon failed with
      # "AccessDeniedException: Cross-account pass role is not allowed"
      # — Myriad's org-level SCP denies iam:PassRole when the calling
      # principal originates from a different account, and our
      # SAML-federated SSO identity (raj@MYGN → assume into 050693401425)
      # gets evaluated as cross-account by the SCP even though the role
      # itself is in 050693401425. The original CreateAddon worked from
      # a different principal/path before the SCP tightened.
      #
      # The dual-binding is therefore intentional rather than oversight:
      # we keep service_account_role_arn set so Terraform's UpdateAddon
      # never tries to unset it (which would re-trigger the SCP denial).
      # The zombie SA annotation is cosmetic noise; Pod Identity wins
      # the credential chain and EBS CSI works normally.
      #
      # Recreating the add-on (delete + create without
      # service_account_role_arn) would work — CreateAddon doesn't
      # validate PassRole on the old role — but it introduces a ~30s
      # window where new EBS volume provisioning fails. Not worth the
      # risk for cosmetic cleanup. Revisit if Myriad ever loosens the
      # SCP or this lab moves to a different account.
      service_account_role_arn = aws_iam_role.ebs_csi.arn
    }
  }

  # eks_managed_node_groups REMOVED 2026-05-08 — Cilium migration.
  #
  # Lifecycle shift (this is the architecturally interesting part):
  #
  #   old cluster (raj-ai-lab-eks):
  #     - 1 managed node group (default, m5.xlarge × 3) for the baseline
  #     - Karpenter on TOP of that NG, provisioning extra capacity
  #     - GPU workloads via Karpenter's gpu-experiments NodePool
  #
  #   new cluster (raj-ai-lab-eks-cilium):
  #     - ZERO managed node groups
  #     - Karpenter pods run on Fargate (see fargate_profiles below)
  #     - 100% of EC2 capacity (incl. baseline) provisioned by Karpenter
  #     - "First EC2 node" emerges when Cilium DaemonSet's Pending pod
  #       triggers Karpenter to scale up
  #     - GPU workloads same as before — gpu-experiments NodePool
  #
  # Cost trade: ~$25/mo Fargate spend for Karpenter + CoreDNS pods,
  # in exchange for: no static bootstrap node group to manage upgrades
  # for, uniform Karpenter labels across all nodes, single provisioning
  # path with one set of observability hooks.

  # Fargate profiles — bootstrap workloads that must run BEFORE any
  # EC2 node exists. Pod selectors are namespace + label-based; only
  # pods matching a selector schedule on Fargate.
  fargate_profiles = {
    karpenter = {
      name = "karpenter"
      selectors = [
        { namespace = "karpenter" }
      ]
    }
    # CoreDNS Deployment pods carry label k8s-app=kube-dns. The
    # configuration_values block on the coredns addon (above) sets
    # computeType=Fargate so the addon removes the EC2 node affinity
    # that would otherwise prevent Fargate scheduling.
    kube-system = {
      name = "kube-system-coredns"
      selectors = [
        {
          namespace = "kube-system"
          labels    = { "k8s-app" = "kube-dns" }
        }
      ]
    }
  }

  tags = merge(local.common_tags, {
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  })
}
