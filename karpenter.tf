# Karpenter — node autoprovisioner that replaces static EKS managed node
# groups for GPU workloads.
#
# Lifecycle model shift:
#   before: flip var.enable_gpu_node_group + terraform apply → GPU node joins
#           (2-3 min) → vllm pod schedules. Reverse for teardown.
#    now:   `kubectl -n llm scale deployment vllm --replicas=1` → Karpenter
#           sees the Pending GPU-requesting pod → provisions a node in
#           ~60-90s → pod schedules. `--replicas=0` → Karpenter consolidates
#           the empty node and terminates it in ~30s.
#
# Karpenter itself runs as a Deployment in kube-system. Pinned to the default
# (m5.xlarge) node group via nodeSelector so it doesn't accidentally schedule
# onto a GPU node it just provisioned (circular-dependency foot-gun).
#
# The default (m5.xlarge × 3) node group stays as EKS managed — we don't
# need Karpenter for static baseline workloads. Karpenter's value is
# capacity that's dynamic, expensive, or instance-type-picky (GPUs).

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
  name       = "karpenter"
  namespace  = "kube-system"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
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
      # Pin the controller to the default (non-GPU) node group. Prevents the
      # foot-gun where Karpenter schedules itself onto a GPU node it just
      # provisioned, and then that node can't be drained because the
      # controller draining it is on it.
      nodeSelector = {
        workload = "general"
      }
      controller = {
        resources = {
          requests = { cpu = "200m", memory = "256Mi" }
          limits   = { cpu = "1",    memory = "1Gi" }
        }
      }
      # Single replica for a 3-node lab. Production runs 2+ for HA.
      replicas = 1
    })
  ]

  depends_on = [
    module.eks,
    module.karpenter,
  ]
}
