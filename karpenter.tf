# Karpenter — node autoprovisioner. In the new (Cilium) cluster, Karpenter
# owns 100% of EC2 capacity, including the baseline that used to live in
# the eks_managed_node_groups.default block.
#
# Lifecycle model shift (recap):
#   old cluster (raj-ai-lab-eks):
#     - 1 managed NG (m5.xlarge × 3) for the baseline workloads
#     - Karpenter on TOP of that NG, provisioning extra GPU/burst capacity
#     - Karpenter controller pinned to NG via nodeSelector workload=general
#       (foot-gun prevention: don't let it run on a GPU node it just made)
#
#   new cluster (raj-ai-lab-eks-cilium):
#     - ZERO managed node groups
#     - Karpenter controller pod runs on FARGATE (see fargate_profiles in
#       eks.tf — the "karpenter" namespace selector catches it)
#     - 100% of EC2 capacity provisioned by Karpenter on demand
#     - The "first EC2 node" is provisioned when the first non-Fargate
#       workload (e.g., a test pod, then Cilium DaemonSet) is pending
#
# Foot-gun prevention is now handled by Fargate vs EC2 separation rather
# than by nodeSelector — Karpenter on Fargate physically can't end up on
# an EC2 node it just provisioned.

# -----------------------------------------------------------------------------
# IAM, SQS, access entries — handled by the terraform-aws-modules submodule
# -----------------------------------------------------------------------------
# Creates:
#   - Controller IAM role with EC2 RunInstances / TerminateInstances / CreateFleet,
#     SSM GetParameter (AMI lookup), SQS (interruption queue), PassRole, etc.
#   - Node IAM role with AmazonEKSWorkerNodePolicy + AmazonEKS_CNI_Policy +
#     AmazonEC2ContainerRegistryReadOnly + AmazonSSMManagedInstanceCore.
#   - aws_iam_instance_profile for the node role (required by launch template).
#   - SQS interruption queue + EventBridge rules for spot termination events.
#   - EKS access entry so nodes registered by Karpenter can authenticate.
#   - Pod Identity association (controller SA → controller IAM role).
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.24"

  cluster_name = module.eks.cluster_name

  # Use Pod Identity, not IRSA. Matches the pattern of every other workload
  # in this cluster (see bedrock.tf, kyverno.tf, etc.) and survives cluster
  # recreate because trust is on the fixed service principal, not a per-
  # cluster OIDC issuer.
  enable_pod_identity             = true
  create_pod_identity_association = true

  # Attach SSM policy to Karpenter-provisioned nodes so we can debug them
  # via Session Manager without SSH keys.
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Karpenter Helm release
# -----------------------------------------------------------------------------
resource "helm_release" "karpenter" {
  name             = "karpenter"
  # Namespace changed from kube-system → karpenter so it matches the
  # "karpenter" Fargate profile selector defined in eks.tf. Helm creates
  # the namespace if it doesn't exist (create_namespace = true).
  namespace        = "karpenter"
  create_namespace = true
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  # Pin deliberately. Karpenter version must support the cluster's K8s
  # version — 1.1.x only supports K8s up to 1.31; we're on 1.34, so we
  # need 1.5.x+ (earlier version matrix: 1.2→K8s1.32, 1.3→K8s1.33,
  # 1.5→K8s1.34). Validated with 1.1.1 crash-panic
  # "karpenter version is not compatible with K8s version 1.34" before
  # the bump.
  version = "1.5.0"

  # Karpenter's Helm chart lives on a public ECR OCI repo. No username/pw
  # needed — public ECR images are pullable anonymously with the right UA.
  # Helm's OCI support handles this transparently.

  values = [
    yamlencode({
      settings = {
        clusterName       = module.eks.cluster_name
        interruptionQueue = module.karpenter.queue_name
      }
      serviceAccount = {
        # Pod Identity association created by the submodule above binds this
        # SA name to the controller IAM role. Don't rename without also
        # updating the association.
        name = "karpenter"
      }
      # nodeSelector REMOVED — old cluster pinned Karpenter to the default
      # managed NG via {workload: general}. New cluster has no managed NG;
      # the "karpenter" namespace's Fargate Profile (in eks.tf) routes the
      # controller pod onto Fargate automatically. No nodeSelector needed.
      controller = {
        resources = {
          # Slightly bumped requests since Fargate charges per requested
          # vCPU/memory — overprovisioning here directly costs money.
          # Karpenter controller in steady state uses ~50-100m CPU /
          # 200-400Mi memory. Requesting 250m/512Mi gives headroom for
          # cold-start and provisioning bursts.
          requests = { cpu = "250m", memory = "512Mi" }
          limits   = { cpu = "1",    memory = "1Gi" }
        }
      }
      # Single replica for a lab. Production runs 2+ for HA. Each replica
      # adds ~$0.012/hr Fargate cost, so going to 2 doubles Karpenter spend
      # to ~$17/mo — fine for prod, unneeded for a personal sandbox.
      replicas = 1
    })
  ]

  depends_on = [
    module.eks,
    module.karpenter,
  ]
}
