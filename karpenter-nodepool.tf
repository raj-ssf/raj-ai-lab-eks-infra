# GPU NodePool + EC2NodeClass for Karpenter.
#
# The NodePool tells Karpenter *when* to provision a node (what pod
# requirements it can satisfy). The EC2NodeClass tells Karpenter *how* to
# provision one (AMI, disk, subnets, SG, IAM role, user data).
#
# Constraints worth flagging:
#   - AZ-pinned to us-west-2c to match the vllm-model-cache PVC's EBS volume
#     zone. EBS is AZ-locked; a node in a different AZ can't mount the
#     pre-existing PVC. When we eventually delete the PVC and let it
#     re-provision fresh, Karpenter's volumeTopology-aware scheduling will
#     naturally match zones — but pinning is the simpler correctness path
#     for now.
#   - Instance types restricted to 4-GPU boxes (g5.12xlarge, g6.12xlarge)
#     because the vllm Deployment in the app repo is configured for
#     --tensor-parallel-size 4. Adding g6e.xlarge (1-GPU, 48 GiB VRAM,
#     cheapest-that-fits-70B) is a future milestone that requires the
#     vllm args to be parameterized on instance type.
#   - max_size via nodepool.limits.cpu — hard cap to prevent runaway
#     provisioning. Set so at most 2 g5.12xlarge or g6.12xlarge can exist
#     simultaneously.

resource "kubectl_manifest" "karpenter_ec2nc_gpu" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "gpu"
    }
    spec = {
      # EKS-optimized AL2023 NVIDIA AMI. Same family we used on the retired
      # static GPU node group. 602401143452 is Amazon's EKS AMI owner account.
      amiFamily = "AL2023"
      amiSelectorTerms = [
        {
          name  = "amazon-eks-node-al2023-x86_64-nvidia-${var.cluster_version}-*"
          owner = "602401143452"
        },
      ]

      # Node role created by the karpenter submodule. Instance profile is
      # auto-created from the role name and referenced by this EC2NodeClass.
      role = module.karpenter.node_iam_role_name

      # Subnet discovery — match OUR VPC's private subnets by a Name pattern
      # specified via var.private_subnet_name_pattern (real value in tfvars,
      # kept out of committed code). A loose pattern like '*Private*' risks
      # matching subnets in other VPCs in a shared account, which makes
      # Karpenter's CreateFleet fail with 'Security group and subnet belong
      # to different networks'. Karpenter further narrows to a specific AZ
      # via the NodePool's topology.kubernetes.io/zone requirement below.
      subnetSelectorTerms = [
        {
          tags = {
            Name = var.private_subnet_name_pattern
          }
        },
      ]

      # Security group discovery — the cluster's node SG + primary cluster
      # SG both carry this tag (set by the EKS module). Karpenter attaches
      # all matching SGs to the node.
      securityGroupSelectorTerms = [
        {
          tags = {
            "kubernetes.io/cluster/${module.eks.cluster_name}" = "owned"
          }
        },
      ]

      # 200 GiB root gp3 — same sizing rationale as the retired static GPU
      # node group (OS + drivers + vllm-openai image extraction). 100 GiB
      # proved too tight in the 2026-04-24 incident.
      blockDeviceMappings = [
        {
          deviceName = "/dev/xvda"
          ebs = {
            volumeSize          = "200Gi"
            volumeType          = "gp3"
            encrypted           = true
            deleteOnTermination = true
          }
        },
      ]

      # Enforce IMDSv2 on nodes Karpenter provisions.
      metadataOptions = {
        httpEndpoint            = "enabled"
        httpTokens              = "required"
        httpPutResponseHopLimit = 2
      }

      tags = local.common_tags
    }
  })

  depends_on = [
    helm_release.karpenter,
  ]
}

resource "kubectl_manifest" "karpenter_nodepool_gpu" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "gpu"
    }
    spec = {
      template = {
        metadata = {
          labels = {
            workload              = "gpu"
            "nvidia.com/gpu"      = "true"
            "nvidia.com/gpu.present" = "true"
          }
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "gpu"
          }
          # Taint matches the vllm Deployment's toleration. Any pod that
          # doesn't tolerate nvidia.com/gpu:NoSchedule won't land here —
          # prevents system pods from accidentally consuming GPU capacity.
          taints = [
            {
              key    = "nvidia.com/gpu"
              value  = "true"
              effect = "NoSchedule"
            },
          ]
          # Hard instance-type allowlist. Karpenter will pick cheapest
          # of these that satisfies pending pod requests — g6.12xlarge
          # is ~19% cheaper than g5.12xlarge so Karpenter will prefer it
          # when spot/on-demand price is comparable.
          requirements = [
            {
              key      = "node.kubernetes.io/instance-type"
              operator = "In"
              values   = ["g5.12xlarge", "g6.12xlarge"]
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["on-demand"]
            },
            # AZ pin to match the vllm-model-cache PVC's EBS zone.
            # When the PVC moves AZs (delete + re-provision), update this.
            {
              key      = "topology.kubernetes.io/zone"
              operator = "In"
              values   = ["us-west-2c"]
            },
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64"]
            },
          ]
          # 5-minute expiry guard against pathological long-lived nodes
          # (e.g., if a vllm pod is stuck Ready but actually wedged, you
          # can force a new node by deleting the stuck pod). Setting
          # expireAfter=Never would disable this; 30d is the safe default.
          expireAfter = "720h"  # 30 days
        }
      }
      # Scale-to-zero. When the vllm Deployment goes to replicas=0 (demo
      # done), Karpenter waits 30s for any drain to finish, then
      # terminates the empty node. Cost clock stops automatically.
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "30s"
      }
      # Hard cap: at most 2 × 48 vCPU GPU instances ever, total. Prevents
      # runaway provisioning if something spawns a flood of pending pods.
      limits = {
        cpu    = "96"      # 48 vCPU × 2 instances
        memory = "400Gi"
        "nvidia.com/gpu" = "8"  # 4 GPUs × 2 instances
      }
    }
  })

  depends_on = [
    kubectl_manifest.karpenter_ec2nc_gpu,
  ]
}
