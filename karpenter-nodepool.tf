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
      # Hard upper bound on total capacity this NodePool can provision.
      # Sized to allow 2 × 48 vCPU GPU boxes simultaneously, which is
      # enough for one running demo + one rolling replacement. Prevents
      # runaway provisioning if something mass-creates GPU-requesting
      # pods. The real on/off toggle is the vllm Deployment's replica
      # count in the app repo (raj-ai-lab-eks/llm/base/deployment.yaml,
      # replicas=0 as steady state) — no pods requesting GPUs, no node.
      limits = {
        cpu              = "96"    # 48 vCPU × 2 instances
        memory           = "400Gi"
        "nvidia.com/gpu" = "8"     # 4 GPUs × 2 instances
      }
    }
  })

  depends_on = [
    kubectl_manifest.karpenter_ec2nc_gpu,
  ]
}

# gpu-experiments NodePool — opt-in hardware comparison sandbox.
#
# Distinct from the default `gpu` NodePool so Karpenter's cheapest-pick
# logic can't silently route the main llm.ekstest.com demo onto an
# exotic instance type (e.g. a g4dn.12xlarge at $3.91/hr would beat
# g6.12xlarge on price but AWQ inference is slow on Turing's non-INT4
# tensor cores). Opt-in is gated by a distinct taint (`gpu-experiment`)
# — only pods that explicitly tolerate it land here.
#
# Shares EC2NodeClass `gpu` (same AMI, disk, role, subnets, SGs). All
# instance types in the allow-list are amd64 EKS-NVIDIA compatible.
# AZ-pinned to us-west-2c to match the vllm-model-cache PVC zone; the
# variant Deployments all share the same PVC + 70B AWQ weights for
# apples-to-apples hardware comparison.
#
# Limits sized for exactly ONE p5.48xlarge (the largest allowed
# instance) at a time. gpu=8 is the authoritative safety cap — any
# mix totalling 8 GPUs is fine, but blocks simultaneous p5 + p4d.
# Designed for sequential testing ("scale one up, test, scale down,
# pick the next"), not parallel runs.
resource "kubectl_manifest" "karpenter_nodepool_gpu_experiments" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "gpu-experiments"
    }
    spec = {
      template = {
        metadata = {
          labels = {
            workload                 = "gpu-experiment"
            "nvidia.com/gpu"         = "true"
            "nvidia.com/gpu.present" = "true"
          }
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "gpu"
          }
          # Dual taint: same `nvidia.com/gpu` taint as the default pool
          # (so existing GPU-tolerant pod specs still work), plus the
          # `gpu-experiment` taint that only variant Deployments
          # tolerate. This keeps the default `vllm` Deployment out of
          # this pool — it tolerates nvidia.com/gpu but not
          # gpu-experiment, so it cannot schedule on an experiment node.
          taints = [
            {
              key    = "nvidia.com/gpu"
              value  = "true"
              effect = "NoSchedule"
            },
            {
              key    = "gpu-experiment"
              value  = "true"
              effect = "NoSchedule"
            },
          ]
          requirements = [
            {
              key      = "node.kubernetes.io/instance-type"
              operator = "In"
              values = [
                # 4-GPU perf-floor baseline — AWQ marlin kernel may
                # fall back to the triton path on Turing (no INT4
                # tensor cores). Interesting data-point either way.
                "g4dn.12xlarge",   # 4× T4 16GB (Turing)
                # 1× L4 24GB (Ada) — cheapest GPU in the allowlist.
                # Used by vllm-bge-m3 (~5 GB working set fits in 24 GB
                # comfortably). NOT suitable for 70B AWQ — quantized 70B
                # plus KV cache exceeds L4's 24 GB. Reserved for the
                # embedding tier and any future small-model variants.
                "g6.xlarge",       # 1× L4 24GB (Ada) — $0.80/hr
                # 1-GPU cheapest single-GPU path for quantized 70B.
                # Requires --tensor-parallel-size=1.
                "g6e.xlarge",      # 1× L40S 48GB (Ada)
                # 4-GPU Ada with 2× VRAM of g6 — room for unquantized
                # 70B FP16 comparison if desired.
                "g6e.12xlarge",    # 4× L40S 48GB (Ada)
                # Classic datacenter GPU. NVSwitch-backed TP=8.
                "p4d.24xlarge",    # 8× A100 40GB (Ampere)
                # Portfolio-flex option. Hopper + NVSwitch + 3.2 Tbps
                # EFA. Overkill for inference but impressive headline.
                "p5.48xlarge",     # 8× H100 80GB (Hopper)
              ]
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["on-demand"]
            },
            {
              # AZ pin matches vllm-model-cache PVC's EBS zone.
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
          # 24h vs the default pool's 30d — experiment nodes recycle
          # within a day even if left running. Cheap safety against
          # an accidental sustained run on a $98/hr p5.48xlarge.
          expireAfter = "24h"
        }
      }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "30s"
      }
      limits = {
        cpu              = "192"     # p5.48xlarge = 192 vCPU
        memory           = "2048Gi"  # p5.48xlarge = 2 TiB RAM
        "nvidia.com/gpu" = "8"
      }
    }
  })

  depends_on = [
    kubectl_manifest.karpenter_ec2nc_gpu,
  ]
}
