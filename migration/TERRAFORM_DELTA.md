# Terraform Delta — Phase 1 IaC Changes for Cilium + Fargate-bootstrapped Karpenter

**Branch:** `migration/cilium-fargate`
**Target:** new cluster `raj-ai-lab-eks-cilium` running parallel with `raj-ai-lab-eks`

---

## 1. New variables

```hcl
# variables.tf — additions

variable "cluster_name_v2" {
  description = "Name of the Cilium-based replacement cluster"
  type        = string
  default     = "raj-ai-lab-eks-cilium"
}

variable "cilium_version" {
  description = "Cilium helm chart version"
  type        = string
  default     = "1.16.5"
}

variable "external_dns_owner_id_v2" {
  description = "TXT ownership ID for the new cluster's external-dns to prevent record fights with old cluster"
  type        = string
  default     = "raj-ai-lab-eks-cilium"
}
```

---

## 2. EKS module — remove managed node groups, add Fargate profiles

```hcl
# eks.tf — modifications

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name    = var.cluster_name_v2
  cluster_version = var.cluster_version

  cluster_endpoint_public_access = true
  vpc_id                          = var.vpc_id
  subnet_ids                      = data.aws_subnets.private.ids
  enable_cluster_creator_admin_permissions = true
  enable_irsa                     = false

  # REMOVED: eks_managed_node_groups = { ... }
  # No managed node groups — Karpenter (running on Fargate) provisions all EC2 capacity.

  # Fargate profiles for bootstrap workloads
  fargate_profiles = {
    karpenter = {
      name      = "karpenter"
      selectors = [
        { namespace = "karpenter" }
      ]
    }
    coredns = {
      name      = "coredns"
      selectors = [
        {
          namespace = "kube-system"
          labels = {
            "k8s-app" = "kube-dns"
          }
        }
      ]
    }
  }

  # PRESERVED: Node SG additional rules — needed for cilium-agent ↔ cilium-agent traffic
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node-to-node: all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    ingress_cluster_all = {
      description                   = "Cluster apiserver to node: all ports"
      protocol                      = "-1"
      from_port                     = 0
      to_port                       = 0
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

  # PRESERVED: access_entries (sso_admin, etc.) — exact same as old cluster

  # CHANGED: addon configuration — disable VPC CNI in favor of Cilium
  cluster_addons = {
    # vpc-cni removed — Cilium replaces it
    coredns = {
      most_recent = true
      configuration_values = jsonencode({
        # CoreDNS pods explicitly target the Fargate profile via labels
        nodeSelector = {
          "eks.amazonaws.com/compute-type" = "fargate"
        }
      })
    }
    kube-proxy = {
      most_recent = true
      # kube-proxy stays — kubectl-proxy is per-node DaemonSet,
      # runs on EC2 nodes once Karpenter provisions them
    }
    eks-pod-identity-agent = {
      most_recent = true
    }
    # Note: aws-ebs-csi-driver may want to come over too; preserve from existing IaC
  }
}
```

---

## 3. Cilium installation (replaces VPC CNI)

```hcl
# cilium.tf — NEW FILE

# Cilium is installed via helm AFTER cluster comes up but BEFORE
# Karpenter provisions any non-Fargate workload.
# Order: aws_eks_cluster -> fargate_profile -> helm_release.cilium ->
#        karpenter Helm install -> NodePool/EC2NodeClass -> apps

resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io"
  chart      = "cilium"
  version    = var.cilium_version
  namespace  = "kube-system"

  values = [yamlencode({
    # ENI-mode IPAM: Cilium uses AWS ENIs for pod IPs (replaces VPC CNI's role)
    eni = {
      enabled                = true
      iam-role               = aws_iam_role.cilium_eni.arn
      update-ec2-adapter-limit-via-api = true
    }
    ipam = {
      mode = "eni"
    }
    routingMode             = "native"
    egressMasqueradeInterfaces = "eth0"
    enableIPv4Masquerade    = true

    # Encryption between nodes (replaces Istio mTLS at L3)
    encryption = {
      enabled = true
      type    = "wireguard"
    }

    # Hubble: L3-L7 observability
    hubble = {
      enabled  = true
      relay    = { enabled = true }
      ui       = { enabled = true }
      metrics = {
        enabled = ["dns", "drop", "tcp", "flow", "icmp", "http"]
      }
    }

    # Gateway API support (replaces Istio Gateway / VirtualService)
    gatewayAPI = {
      enabled = true
    }

    # Cilium Service Mesh features
    serviceMesh = {
      enabled = true
    }

    # Required for EKS without VPC CNI
    cluster = {
      name = var.cluster_name_v2
      id   = 1
    }

    operator = {
      replicas = 1
      tolerations = [
        # Karpenter operator pod tolerates the Fargate node taint
        # (only relevant if Cilium operator runs on Fargate; usually it
        # runs on EC2 once Karpenter provides nodes)
      ]
    }
  })]

  depends_on = [
    module.eks,
    aws_eks_fargate_profile.karpenter,  # Karpenter must come up first to provide EC2
  ]
}

resource "kubectl_manifest" "cilium_clusterwide_policy" {
  # Default-deny policy at cluster level — replaces Istio default mTLS-required posture
  yaml_body = <<-YAML
    apiVersion: cilium.io/v2
    kind: CiliumClusterwideNetworkPolicy
    metadata:
      name: default-deny-egress
    spec:
      endpointSelector: {}  # all pods
      egress: []  # no egress allowed by default; namespace-level CiliumNetworkPolicy adds rules
  YAML
  # Apply ONLY after Phase 4 — too aggressive during initial workload deployment
  count = 0  # Set to 1 in Phase 5
}
```

---

## 4. Karpenter helm values — schedule controller on Fargate

```hcl
# karpenter.tf — modifications

resource "helm_release" "karpenter" {
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "1.5.0"
  namespace  = "karpenter"
  create_namespace = true

  values = [yamlencode({
    # Karpenter controller schedules on Fargate (no EC2 node selector needed —
    # Fargate profile selectors handle it)
    controller = {
      resources = {
        requests = { cpu = "250m", memory = "512Mi" }
        limits   = { cpu = "1",    memory = "1Gi"   }
      }
    }

    # PRESERVED: Pod Identity Association (use existing IRSA-replacement pattern)
    serviceAccount = {
      create = true
      name   = "karpenter"
      annotations = {
        "eks.amazonaws.com/role-arn" = aws_iam_role.karpenter.arn
      }
    }

    settings = {
      clusterName       = var.cluster_name_v2
      interruptionQueue = aws_sqs_queue.karpenter_interruption.name
    }

    # Webhook also runs on Fargate
    webhook = {
      enabled = true
    }
  })]

  depends_on = [
    module.eks,
    aws_eks_fargate_profile.karpenter,
  ]
}

# NodePool: defines what Karpenter should provision
resource "kubectl_manifest" "karpenter_nodepool_general" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: general
    spec:
      template:
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: default
          requirements:
            - key: kubernetes.io/arch
              operator: In
              values: [amd64]
            - key: karpenter.sh/capacity-type
              operator: In
              values: [spot, on-demand]
            - key: node.kubernetes.io/instance-type
              operator: In
              values: [m6i.large, m6i.xlarge, m6i.2xlarge, m5.large, m5.xlarge]
      limits:
        cpu: "256"
        memory: "1024Gi"
      disruption:
        consolidationPolicy: WhenEmpty
        consolidateAfter: 1m
  YAML

  depends_on = [helm_release.karpenter]
}

# Preserve gpu-experiments NodePool from existing IaC (1:1 copy)
```

---

## 5. external-dns — different ownership ID

```hcl
# external-dns.tf — modifications

resource "helm_release" "external_dns" {
  name      = "external-dns"
  chart     = "external-dns"
  namespace = "external-dns"

  values = [yamlencode({
    txtOwnerId    = var.external_dns_owner_id_v2  # "raj-ai-lab-eks-cilium"
    domainFilters = ["ekstest.com"]
    provider      = "aws"
    # ... rest preserved from existing IaC
  })]
}
```

---

## 6. Removed Terraform resources

These get deleted from the new cluster's state (no Istio):

- `istio-base.tf`
- `istio-cni.tf`
- `istiod.tf`
- All Istio CR resources (Gateway, VirtualService, AuthorizationPolicy if any)

These either get deleted or modified:
- `alb-controller.tf` — kept BUT may not be needed (Cilium Gateway can do ingress directly via AWS ALB integration). Decide in Phase 3.

---

## 7. Cluster-discovery + Karpenter EC2NodeClass

```hcl
# karpenter-ec2-nodeclass.tf — NEW

resource "kubectl_manifest" "karpenter_ec2nodeclass_default" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: default
    spec:
      amiSelectorTerms:
        - alias: al2023@latest
      role: ${aws_iam_role.karpenter_node.name}
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.cluster_name_v2}
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.cluster_name_v2}
      userData: |
        #!/bin/bash
        # Cilium will install via DaemonSet — no aws-cni bootstrap needed
  YAML

  depends_on = [helm_release.karpenter]
}
```

---

## 8. Pre-apply checklist

Before `terraform apply` on this branch:

- [ ] Verify Terraform backend points to a NEW state file (not the old cluster's state)
  - Update `backend.hcl` with new bucket key, e.g., `key = "raj-ai-lab-eks-cilium/terraform.tfstate"`
- [ ] Verify VPC has subnets tagged `karpenter.sh/discovery = raj-ai-lab-eks-cilium` (or update tag to a generic one)
- [ ] Confirm Velero S3 backup bucket has policy allowing both old and new cluster IAM roles
- [ ] Confirm Route53 zone `ekstest.com` is NOT recreated (preserve existing zone resource — IMPORT if needed)

## 9. Risks called out in the IaC

```hcl
# 🚨 PRE-APPLY WARNING:
# This Terraform creates a NEW EKS cluster alongside the existing one.
# AWS bill will reflect 2x EKS control plane cost (~$73/cluster) for
# the duration of the migration window. Plan to destroy the old cluster
# at Phase 8 (target: within 7 days of this apply).
#
# To destroy the old cluster, switch to its state file and run
# terraform destroy (in the original repo state, not this branch).
```
