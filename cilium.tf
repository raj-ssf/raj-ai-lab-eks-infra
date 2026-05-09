# =============================================================================
# Cilium — replaces AWS VPC CNI as the cluster's networking layer.
#
# Architecture choice (Phase 1a of the migration — see migration/ for plan):
#   - ENI IPAM mode: pods get IPs from AWS ENIs attached to nodes (not
#     overlay). Operator manages ENI lifecycle via AWS API.
#   - Routing mode: native (kernel routes pod traffic directly, no
#     VXLAN/Geneve overhead).
#   - kubeProxyReplacement: false (Phase 1a). EKS-managed kube-proxy
#     DaemonSet keeps doing service-to-pod load balancing. Phase 6 may
#     flip this to "true" for eBPF-native performance.
#   - Hubble: enabled with relay + UI. Replaces the runbook's earlier
#     "no network observability" gap.
#   - Encryption: WireGuard pod-to-pod (replaces Istio mTLS at L3 once
#     Phase 5 lands. Currently no Istio in this cluster, so this IS the
#     mTLS story.)
#   - GatewayAPI: enabled. No Gateway resources defined yet — that's
#     Phase 3. But the controller is ready to claim Gateway resources
#     when they appear.
#
# Bootstrap dependency chain (the chicken-and-egg solution):
#   1. EKS cluster exists, control plane up.
#   2. Fargate profiles activate (karpenter ns, kube-system w/ Cilium label).
#   3. Karpenter helm release runs Karpenter on Fargate.
#   4. THIS file's helm_release runs Cilium operator on Fargate (matches
#      the kube-system Fargate selector via app.kubernetes.io/part-of=cilium).
#   5. First non-Fargate workload (e.g., a test pod, eventually all the
#      app DaemonSets and Deployments) creates Pending pods.
#   6. Karpenter sees the Pending pods and provisions an EC2 node.
#   7. Cilium DaemonSet pod schedules on the new EC2 node (hostNetwork=true,
#      so doesn't need pod IP). Operator on Fargate allocates ENIs to it.
#   8. Workload pods on the EC2 node get Cilium-managed IPs from the ENI.
# =============================================================================

# -----------------------------------------------------------------------------
# IAM — Cilium operator needs EC2 ENI management permissions
# -----------------------------------------------------------------------------
# The operator allocates ENIs to nodes for pod IP space. Without these
# permissions, pods stay Pending with errors about IP allocation.

data "aws_iam_policy_document" "cilium_operator_assume_role" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cilium_operator" {
  name               = "${var.cluster_name}-cilium-operator"
  assume_role_policy = data.aws_iam_policy_document.cilium_operator_assume_role.json
  tags               = local.common_tags
}

# Permissions adapted from Cilium's official EKS install doc:
# https://docs.cilium.io/en/stable/installation/cni/aws-eni/
data "aws_iam_policy_document" "cilium_operator" {
  statement {
    sid = "CiliumENIManagement"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeSubnets",
      "ec2:DescribeVpcs",
      "ec2:DescribeRouteTables",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeTags",
      "ec2:CreateNetworkInterface",
      "ec2:DeleteNetworkInterface",
      "ec2:AttachNetworkInterface",
      "ec2:DetachNetworkInterface",
      "ec2:ModifyNetworkInterfaceAttribute",
      "ec2:AssignPrivateIpAddresses",
      "ec2:UnassignPrivateIpAddresses",
      "ec2:CreateTags",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "cilium_operator" {
  name   = "cilium-operator"
  role   = aws_iam_role.cilium_operator.id
  policy = data.aws_iam_policy_document.cilium_operator.json
}

# Pod Identity Association — binds cilium-operator service account to the
# IAM role above. Same pattern as every other workload (matches enable_irsa
# = false on the EKS module).
resource "aws_eks_pod_identity_association" "cilium_operator" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "cilium-operator"
  role_arn        = aws_iam_role.cilium_operator.arn

  depends_on = [module.eks]
}

# -----------------------------------------------------------------------------
# Cilium Helm release
# -----------------------------------------------------------------------------
resource "helm_release" "cilium" {
  name       = "cilium"
  namespace  = "kube-system"
  repository = "https://helm.cilium.io"
  chart      = "cilium"
  # Pinned. 1.16.x is the GA series with stable Gateway API + Cluster Mesh
  # support. 1.17 is in beta as of this writing — wait for GA before bumping.
  version = "1.16.5"

  values = [
    yamlencode({
      # ---------------------------------------------------------------------
      # IPAM — use AWS ENIs (replaces VPC CNI's role)
      # ---------------------------------------------------------------------
      eni = {
        enabled = true
        # Cilium needs to know it's running on EKS so it talks to the EC2
        # ENI APIs the right way (vs the alternative ENI-IPAMd path).
        awsEnablePrefixDelegation = true
      }
      ipam = {
        mode = "eni"
      }

      # No overlay; route pod traffic via kernel routing on the ENI.
      routingMode = "native"
      # 2026-05-09: changed from "eth0" → "ens+" (regex). Amazon Linux 2023
      # uses predictable interface names like ens5/ens6/ens7, not eth0.
      # With "eth0" set, masquerade rules never matched, so pod egress to
      # AWS APIs (ec2.us-west-2.amazonaws.com etc.) had source-IP issues
      # or routing failures — EBS CSI controller couldn't reach EC2 API.
      # "ens+" matches all ens* interfaces (the actual primary/secondary
      # ENIs Cilium attaches in eni IPAM mode).
      egressMasqueradeInterfaces = "ens+"
      enableIPv4Masquerade       = true
      tunnelProtocol             = ""

      # ---------------------------------------------------------------------
      # Cluster identity (used by Hubble + ClusterMesh)
      # ---------------------------------------------------------------------
      cluster = {
        name = module.eks.cluster_name
        id   = 1
      }

      # ---------------------------------------------------------------------
      # kubeProxyReplacement — Phase 1a leaves kube-proxy in place
      # ---------------------------------------------------------------------
      # Set to "true" in Phase 6 to remove kube-proxy DaemonSet entirely
      # and let Cilium handle service load-balancing via eBPF. Until then,
      # kube-proxy (installed via EKS addon in eks.tf) does service NAT.
      kubeProxyReplacement = "false"

      # K8s API endpoint (required when kubeProxyReplacement is true; safe
      # to set always so flipping later doesn't need a values change).
      k8sServiceHost = replace(module.eks.cluster_endpoint, "https://", "")
      k8sServicePort = 443

      # ---------------------------------------------------------------------
      # Encryption — WireGuard pod-to-pod (replaces Istio mTLS at L3)
      # ---------------------------------------------------------------------
      encryption = {
        enabled = true
        type    = "wireguard"
        # Encrypt node-to-node too (covers control-plane traffic between
        # the cilium-agent on each node).
        nodeEncryption = true
      }

      # ---------------------------------------------------------------------
      # Hubble — L3-L7 network observability
      # ---------------------------------------------------------------------
      hubble = {
        enabled = true
        relay = {
          enabled = true
        }
        ui = {
          enabled = true
        }
        metrics = {
          enabled = ["dns", "drop", "tcp", "flow", "icmp", "http"]
        }
        tls = {
          # Cilium operator generates and rotates the certs automatically.
          auto = {
            enabled = true
            method  = "cronJob"
          }
        }
      }

      # ---------------------------------------------------------------------
      # Gateway API — controller is ready, no Gateway resources yet (Phase 3)
      # ---------------------------------------------------------------------
      gatewayAPI = {
        enabled = true
      }

      # ---------------------------------------------------------------------
      # Operator — runs on EC2 nodes (provisioned by Karpenter). Originally
      # planned for Fargate but Cilium's AWS operator calls ec2imds
      # GetInstanceIdentityDocument at startup which is not available on
      # Fargate. Falls back to EC2 in the standard hostNetwork=true config.
      # ---------------------------------------------------------------------
      # nodeSelector pins operator to the Karpenter-managed "general" pool.
      # Originally tried eks.amazonaws.com/compute-type=ec2, but that label
      # is only set on Fargate nodes (=fargate); Karpenter doesn't know
      # what "ec2" means and rejects the pod with "incompatible requirements,
      # label does not have known values". Using karpenter.sh/nodepool is
      # unambiguous — Karpenter understands this and provisions a node from
      # the general NodePool when no matching node exists.
      operator = {
        nodeSelector = {
          "karpenter.sh/nodepool" = "general"
        }

        # Single replica is fine for a lab. Production runs 2+ for HA.
        replicas = 1

        resources = {
          requests = { cpu = "50m",  memory = "128Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
      }

      # ---------------------------------------------------------------------
      # Agent (DaemonSet) — runs on EC2 nodes that Karpenter provisions.
      # In Cilium's helm schema, `agent` is a boolean (deploy DaemonSet?)
      # — defaults to true, no need to override. Agent container resources
      # would go under `resources:` at the chart's top level if needed
      # (default: requests cpu=100m / memory=512Mi). For Phase 1a defaults
      # are fine — agent is lightweight in eBPF mode (~100m / 200Mi steady
      # state on a typical lab node).
      # ---------------------------------------------------------------------

      # ---------------------------------------------------------------------
      # nodeAffinity — schedule on Karpenter-managed EC2 nodes only
      # ---------------------------------------------------------------------
      # Originally tried "eks.amazonaws.com/compute-type DoesNotExist" but
      # that label is set with a hashed value (e.g. "8778753898604093030")
      # on some EC2 nodes, breaking the DoesNotExist check. Switching to
      # "karpenter.sh/nodepool Exists" is unambiguous: every Karpenter-
      # provisioned EC2 node has it; Fargate nodes don't.
      #
      # This also tightly aligns with the architecture: Karpenter manages
      # all EC2 capacity in this cluster, so "Karpenter-managed" and
      # "EC2 worker we want Cilium on" are synonymous.
      affinity = {
        nodeAffinity = {
          requiredDuringSchedulingIgnoredDuringExecution = {
            nodeSelectorTerms = [
              {
                matchExpressions = [
                  {
                    key      = "karpenter.sh/nodepool"
                    operator = "Exists"
                  },
                ]
              },
            ]
          }
        }
      }

      # Same constraint for the envoy DaemonSet
      envoy = {
        affinity = {
          nodeAffinity = {
            requiredDuringSchedulingIgnoredDuringExecution = {
              nodeSelectorTerms = [
                {
                  matchExpressions = [
                    {
                      key      = "karpenter.sh/nodepool"
                      operator = "Exists"
                    },
                  ]
                },
              ]
            }
          }
        }
      }

      # ---------------------------------------------------------------------
      # Pod Security — EKS Pod Security Standards may flag privileged
      # containers; Cilium agent legitimately needs CAP_NET_ADMIN, etc.
      # The kube-system namespace has the privileged label by default in
      # EKS, so this is moot. Documenting for clarity.
      # ---------------------------------------------------------------------
    })
  ]

  depends_on = [
    module.eks,
    aws_eks_pod_identity_association.cilium_operator,
  ]

  # 2026-05-08 update: wait = false. Originally set to true so helm
  # would block until DaemonSet ready. But Cilium agent on EC2 nodes
  # waits for the operator to allocate ENIs; operator can't run until
  # Karpenter provisions another EC2 node; chicken-and-egg means the
  # 600s wait keeps timing out even though the chart installs cleanly.
  # With wait=false, helm submits manifests and returns; K8s controllers
  # settle out post-apply.
  wait    = false
  timeout = 600
  atomic  = false # don't auto-rollback; debug failures manually
}
