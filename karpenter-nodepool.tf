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
            workload                 = "gpu"
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
          expireAfter = "720h" # 30 days
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
        cpu              = "96" # 48 vCPU × 2 instances
        memory           = "400Gi"
        "nvidia.com/gpu" = "8" # 4 GPUs × 2 instances
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
                # T4 / Turing (sm_75) was previously in this allowlist as
                # a perf-floor baseline. Removed 2026-04-28 after fine-
                # tuning F2: T4 doesn't support flash-attention 2 (Ampere+
                # only), and without flash-attn an 8B QLoRA training step
                # at sequence_len=2048 took ~5 min/step → ~26 hours per
                # epoch on g4dn.12xlarge. The cheapest L4-based instance
                # (g6.xlarge, $0.80/hr) is BOTH faster per step AND
                # cheaper per hour, so g4dn no longer earns a spot here.
                # Inference workloads (vllm AWQ marlin) preferred the
                # Ampere+ GPUs anyway — keeping T4 only inflated the
                # consideration set without offering value.
                # 1× L4 24GB (Ada) — cheapest GPU in the allowlist.
                # Used by vllm-bge-m3 (~5 GB working set fits in 24 GB
                # comfortably). NOT suitable for 70B AWQ — quantized 70B
                # plus KV cache exceeds L4's 24 GB. Reserved for the
                # embedding tier and any future small-model variants.
                "g6.xlarge", # 1× L4 24GB (Ada) — $0.80/hr
                # 1-GPU cheapest single-GPU path for quantized 70B.
                # Requires --tensor-parallel-size=1.
                "g6e.xlarge", # 1× L40S 48GB (Ada)
                # 4-GPU Ada with 2× VRAM of g6 — room for unquantized
                # 70B FP16 comparison if desired.
                "g6e.12xlarge", # 4× L40S 48GB (Ada)
                # Classic datacenter GPU. NVSwitch-backed TP=8.
                "p4d.24xlarge", # 8× A100 40GB (Ampere)
                # Portfolio-flex option. Hopper + NVSwitch + 3.2 Tbps
                # EFA. Overkill for inference but impressive headline.
                "p5.48xlarge", # 8× H100 80GB (Hopper)
              ]
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["on-demand"]
            },
            {
              # Phase #54c (2026-04-29): widened from us-west-2c-only
              # to all 4 us-west-2 AZs because AWS hit Insufficient-
              # InstanceCapacity for both p4d.24xlarge AND p5.48xlarge
              # in us-west-2c during the 405B smoke test, while
              # capacity was available in us-west-2a/b/d per AWS's
              # error message ("You can currently get p4d.24xlarge
              # capacity by [...] choosing us-west-2a, us-west-2b,
              # us-west-2d.").
              #
              # Trade-off: workloads using gp3 PVCs in this NodePool
              # need to be aware that EBS is AZ-locked. Specifically,
              # vllm-cache-llama-405b-gp3 was provisioned in us-
              # west-2c (Phase #52a staging Job ran there); pods
              # mounting it must still land in us-west-2c. The
              # vllm-llama-405b Deployment was reverted to the S3-
              # Mountpoint PVC (vllm-cache-llama-405b, region-
              # scoped) precisely so it can land in any AZ.
              #
              # Other workloads in this NodePool (variant
              # Deployments) similarly need region-scoped storage
              # OR an explicit topology.kubernetes.io/zone pin on
              # their pod spec. The vllm-model-cache PVC reference
              # in the previous comment was misleading — that PVC
              # is on the default GPU NodePool, not gpu-experiments.
              key      = "topology.kubernetes.io/zone"
              operator = "In"
              values   = ["us-west-2a", "us-west-2b", "us-west-2c", "us-west-2d"]
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
        cpu              = "192"    # p5.48xlarge = 192 vCPU
        memory           = "2048Gi" # p5.48xlarge = 2 TiB RAM
        "nvidia.com/gpu" = "8"
      }
    }
  })

  depends_on = [
    kubectl_manifest.karpenter_ec2nc_gpu,
  ]
}

# =============================================================================
# Phase #66: General-purpose CPU NodePool.
#
# Until this lands, the cluster has 3 static m5.xlarge nodes (one per
# us-west-2{a,b,c}) and Karpenter only has GPU NodePools. CPU workloads
# that exceed the static-node capacity have no spawn path:
#   - Multiple bumps in this session (Phase #59 gateway, Phase #62 vault-
#     agent-injector) ended up colocating 2 pods on the same node because
#     no Karpenter NodePool could spawn a second node in their target AZ.
#   - Phase #59 explicitly flagged Phase #59c (this) as the prerequisite
#     for the gateway's preferred-anti-affinity actually spreading pods.
#
# Design choices:
#
# Multi-AZ. Unlike the GPU NodePools (AZ-pinned us-west-2c for vllm
# model-cache PVC affinity), CPU workloads typically don't care which
# AZ they land in. Accept all 4 AZs (a/b/c/d) so Karpenter has the
# widest scheduling space and AWS InsufficientInstanceCapacity in one
# AZ doesn't block the spawn.
#
# No taints. Any pod that doesn't explicitly target the GPU NodePools
# (i.e., doesn't tolerate nvidia.com/gpu) can land here. This is the
# default scheduling pool.
#
# Spot-preferred capacity mix. Spot pricing is typically 60-90% off
# on-demand for these instance families. Lab workloads tolerate brief
# (~2-min) interruption notices for spot reclamation. Workloads that
# need stability (e.g., StatefulSets with long-running state) can add
# `karpenter.sh/capacity-type: on-demand` to their nodeSelector or
# pod spec requirements; Karpenter will honor that and skip spot for
# those pods.
#
# Diverse instance types. Karpenter picks cheapest-that-fits from
# the allowlist, weighing spot-price + interruption-rate signals. The
# more types in the list, the better the optimization.
#   m5/m5a   — Intel/AMD Xeon, common spot capacity
#   m6a      — AMD EPYC, often cheapest in the m-family
#   m6i/m7i  — Intel Ice Lake / Sapphire Rapids, newer
#   c6a/c7a  — AMD compute-optimized for CPU-heavy workloads
# Sizes capped at 2xlarge (8 vCPU / 32 GiB) — large enough to host
# realistic workloads, small enough that one runaway scheduler bug
# can't binpack 32 pods onto one node.
#
# 50 GiB gp3 root. Much smaller than the GPU pool's 200 GiB because
# CPU workloads' images are typically <10 GB. Cuts EBS cost ~75% per
# spawned node.
#
# expireAfter = 7d. Recycle nodes weekly to pick up AMI patches +
# pod-density rebalancing. Shorter than GPU's 30d because CPU
# workloads tolerate restart, longer than gpu-experiments' 24h
# because we want some node stability for log aggregation /
# cumulative metrics.
#
# Hard limit: cpu=64, memory=256Gi. Caps the pool at ~8 m5.xlarge
# equivalents. Prevents runaway CPU spend if a HPA misconfiguration
# causes mass pod creation. Adjust upward when steady-state demand
# exceeds 50% of cap (Karpenter scaling alarms in
# kube-prometheus-stack would surface that).
# =============================================================================

resource "kubectl_manifest" "karpenter_ec2nc_general" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "general"
    }
    spec = {
      # AL2023 STANDARD (no -nvidia suffix) — same EKS-optimized base
      # but without the pre-baked NVIDIA drivers. ~3 GB smaller AMI,
      # boots faster. Pods needing GPUs can't run here (no
      # nvidia-device-plugin) — they'd land on the GPU NodePools.
      amiFamily = "AL2023"
      amiSelectorTerms = [
        {
          name  = "amazon-eks-node-al2023-x86_64-standard-${var.cluster_version}-*"
          owner = "602401143452"
        },
      ]

      role = module.karpenter.node_iam_role_name

      subnetSelectorTerms = [
        {
          tags = {
            Name = var.private_subnet_name_pattern
          }
        },
      ]

      securityGroupSelectorTerms = [
        {
          tags = {
            "kubernetes.io/cluster/${module.eks.cluster_name}" = "owned"
          }
        },
      ]

      # 50 GiB root — CPU workload images are typically <10 GB
      # (FastAPI/Django apps, oauth2-proxy, etc.), and the AL2023
      # base + cri + containerd is ~8 GB. 50 GiB leaves comfortable
      # headroom for image churn during rolling updates.
      blockDeviceMappings = [
        {
          deviceName = "/dev/xvda"
          ebs = {
            volumeSize          = "50Gi"
            volumeType          = "gp3"
            encrypted           = true
            deleteOnTermination = true
          }
        },
      ]

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

resource "kubectl_manifest" "karpenter_nodepool_general" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "general"
    }
    spec = {
      template = {
        metadata = {
          labels = {
            workload = "general"
          }
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "general"
          }
          # NO taints — this is the default scheduling pool. Any pod
          # that doesn't explicitly target a GPU NodePool can land
          # here. To force a workload onto a STATIC node instead
          # (Vault, kube-system bits), add a nodeSelector matching
          # the existing static node group's labels.
          requirements = [
            {
              key      = "node.kubernetes.io/instance-type"
              operator = "In"
              values = [
                "m5.large", "m5.xlarge", "m5.2xlarge",
                "m5a.large", "m5a.xlarge", "m5a.2xlarge",
                "m6a.large", "m6a.xlarge", "m6a.2xlarge",
                "m6i.large", "m6i.xlarge", "m6i.2xlarge",
                "m7i.large", "m7i.xlarge", "m7i.2xlarge",
                # Compute-optimized (lower memory, higher CPU). Useful
                # for CPU-bound workloads (proxies, parsers).
                "c6a.large", "c6a.xlarge", "c6a.2xlarge",
                "c7a.large", "c7a.xlarge", "c7a.2xlarge",
              ]
            },
            {
              # Spot + on-demand mix. Karpenter prefers spot when both
              # are valid (cheaper); workloads that need stability can
              # add a karpenter.sh/capacity-type: on-demand requirement
              # to their pod spec to opt out of spot.
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["spot", "on-demand"]
            },
            {
              # Multi-AZ. Lab VPC has private subnets in all 4
              # us-west-2 AZs; CPU workloads are AZ-flexible.
              key      = "topology.kubernetes.io/zone"
              operator = "In"
              values   = ["us-west-2a", "us-west-2b", "us-west-2c", "us-west-2d"]
            },
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64"]
            },
          ]
          # Recycle weekly. Short enough to pick up AMI patches +
          # rebalance pod density, long enough that we're not
          # pointlessly burning compute time on restart cycles.
          expireAfter = "168h" # 7 days
        }
      }
      # CPU workloads churn more than GPU (rolling updates, scale-
      # down events). 5-minute consolidation window so brief
      # scale-down then scale-up doesn't terminate then re-spawn a
      # node every time.
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "5m"
      }
      # Cap at ~8 m5.xlarge equivalents. Adjust upward if
      # steady-state usage approaches 50% of cap.
      limits = {
        cpu    = "64"
        memory = "256Gi"
      }
    }
  })

  depends_on = [
    kubectl_manifest.karpenter_ec2nc_general,
  ]
}
