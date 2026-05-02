# =============================================================================
# Phase #65 expansion: NetworkPolicies for the remaining 7 namespaces.
#
# Wraps up the cluster-wide NetworkPolicy coverage started in Phase #70.
# Phase #70/#65 covered the highest-blast-radius components (admission
# webhooks, control plane, vault, the 4 meshed apps, argocd, monitoring,
# qdrant, llm, kyverno). This commit completes the coverage with the
# remaining 7 namespaces:
#
#   Meshed (use the app-network-policies.tf locals):
#     argo-rollouts                rollouts-controller, oauth2-proxy,
#                                  dashboard. Phase #55 mesh-injected.
#
#   Unmeshed (controller-shape, custom rules):
#     gateway-system               shared-gateway Envoy pods. NLB-fronted.
#     istio-system                 istiod (the control plane itself —
#                                  cannot be meshed; it IS the mesh)
#     velero                       backup orchestrator, S3 + K8s API
#     kubeflow                     training-operator, K8s API only
#     training                     PyTorchJob pods, S3 + HF + K8s API
#     vault-secrets-operator       VSO controller, Vault + K8s API
#
# After this commit, the cluster has 21 + 7 = 28 NetworkPolicies (chart-
# default + terraform-authored). Every user-managed namespace has at
# least default-deny + an explicit allowlist.
#
# Verification after apply:
#   kubectl get networkpolicy -A | wc -l
#     # expect: 28+ (header + each NP line)
#   # Smoke test admission webhooks still work (they're the highest-
#   # blast-radius case — istio-system + gateway-system both have
#   # webhook ingress paths):
#   kubectl create -f -<<'YAML'
#   apiVersion: gateway.networking.k8s.io/v1
#   kind: HTTPRoute
#   metadata: {name: phase65b-test, namespace: default}
#   spec:
#     parentRefs: [{name: shared-gateway, namespace: gateway-system}]
#     hostnames: [phase65b.test.invalid]
#     rules: [{matches: [{path: {type: PathPrefix, value: "/"}}], backendRefs: [{name: nonexistent, port: 80}]}]
#   YAML
#   # If admission accepts → istio-system + gateway-system NPs both
#   # admit the validating-webhook TLS handshake. Then delete:
#   kubectl delete httproute phase65b-test -n default --ignore-not-found
# =============================================================================

# --- argo-rollouts (meshed) --------------------------------------------------
resource "kubectl_manifest" "argo_rollouts_netpol" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "argo-rollouts"
      namespace = "argo-rollouts"
    }
    spec = {
      podSelector = {} # all pods in argo-rollouts ns
      policyTypes = ["Ingress", "Egress"]
      # Same shape as Phase #70f apps + argocd: admit from meshed
      # namespaces (Istio AuthZ filters L7 in
      # istio-zero-trust.tf:allow_argo_rollouts_to_prometheus etc).
      # Plus gateway-system for the dashboard's HTTPRoute (rollouts.${var.domain}).
      ingress = concat(local.app_common_ingress, [{
        from = [{
          namespaceSelector = {
            matchLabels = {
              "kubernetes.io/metadata.name" = "gateway-system"
            }
          }
        }]
      }])
      egress = local.app_common_egress
    }
  })

  depends_on = [helm_release.istiod]
}

# --- gateway-system (unmeshed, ingress-heavy) -------------------------------
# NLB sends traffic here. Pods are Envoy proxies that forward into the
# mesh — they speak Istio xDS to istiod but don't carry a mesh sidecar
# themselves (sidecar.istio.io/inject=false on the pods). Network
# profile:
#   Ingress: ANY (NLB target — public-internet sources after AWS NLB
#            forwards. The shared-gateway-istio Listener Envoy does
#            the L7 routing; HTTPRoute + Istio AuthZ enforce policy).
#   Egress:  meshed namespaces (where backends live), istiod (xDS),
#            DNS, K8s API.
resource "kubectl_manifest" "gateway_system_netpol" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "gateway-system"
      namespace = "gateway-system"
    }
    spec = {
      podSelector = {}
      policyTypes = ["Ingress", "Egress"]
      # Allow all ingress: NLB source IPs are unpredictable and
      # tightening would only block legitimate public traffic.
      # The Listener TLS config + HTTPRoute matchers + Istio AuthZ
      # are the actual enforcement points.
      ingress = [{}]
      egress  = local.app_common_egress
    }
  })

  depends_on = [helm_release.istiod]
}

# --- istio-system (unmeshed; the mesh control plane) -----------------------
# istiod cannot be meshed (it IS the mesh — chicken-and-egg with sidecar
# injection). Network profile:
#   Ingress 15010 xDS plaintext (legacy; mTLS-only deployments don't use)
#           15012 xDS over mTLS — every meshed pod's sidecar connects here
#           15014 monitoring — Prometheus scrape (Phase #55b allow already)
#           15017 validating/mutating admission webhooks — kube-apiserver
#                 (outside cluster) calls these for VirtualService /
#                 DestinationRule / etc CRUD
#           8080  debug endpoint (operator port-forward only)
#   Egress  53 → CoreDNS
#           443 → K8s API (CRD watches; kube-public for caBundle injection)
resource "kubectl_manifest" "istio_system_netpol" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "istio-system"
      namespace = "istio-system"
    }
    spec = {
      podSelector = {}
      policyTypes = ["Ingress", "Egress"]
      # Ports listed explicitly so a future surprise (someone exposes
      # 8443 on istiod for some debug feature) doesn't silently get
      # admitted.
      ingress = [{
        ports = [
          { protocol = "TCP", port = 15010 },
          { protocol = "TCP", port = 15012 },
          { protocol = "TCP", port = 15014 },
          { protocol = "TCP", port = 15017 },
          { protocol = "TCP", port = 8080 },
          { protocol = "TCP", port = 15021 }, # health probes from kubelet
        ]
      }]
      egress = [
        # DNS
        {
          to = [{
            namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = "kube-system" } }
            podSelector       = { matchLabels = { "k8s-app" = "kube-dns" } }
          }]
          ports = [
            { protocol = "UDP", port = 53 },
            { protocol = "TCP", port = 53 },
          ]
        },
        # K8s API
        {
          to = [{
            ipBlock = {
              cidr   = "0.0.0.0/0"
              except = ["169.254.169.254/32"] # IMDS — defense in depth
            }
          }]
          ports = [{ protocol = "TCP", port = 443 }]
        },
      ]
    }
  })

  depends_on = [helm_release.istiod]
}

# --- velero (unmeshed; backup workflow) -------------------------------------
# Velero orchestrates volume snapshots + uploads to S3. Network profile:
#   Ingress none (controller-shape)
#   Egress  S3 + STS via Pod Identity Agent + DNS + K8s API
resource "kubectl_manifest" "velero_netpol" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "velero"
      namespace = "velero"
    }
    spec = {
      podSelector = {}
      policyTypes = ["Ingress", "Egress"]
      ingress     = []
      egress = [
        {
          to = [{
            namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = "kube-system" } }
            podSelector       = { matchLabels = { "k8s-app" = "kube-dns" } }
          }]
          ports = [
            { protocol = "UDP", port = 53 },
            { protocol = "TCP", port = 53 },
          ]
        },
        {
          to    = [{ ipBlock = { cidr = "169.254.170.23/32" } }]
          ports = [{ protocol = "TCP", port = 80 }]
        },
        {
          to = [{
            ipBlock = {
              cidr   = "0.0.0.0/0"
              except = ["169.254.169.254/32"]
            }
          }]
          ports = [{ protocol = "TCP", port = 443 }]
        },
      ]
    }
  })

  depends_on = [helm_release.istiod]
}

# --- kubeflow (unmeshed; controller-shape) ----------------------------------
# training-operator watches PyTorchJob CRDs in the training namespace and
# spawns pods. Pure K8s API egress.
resource "kubectl_manifest" "kubeflow_netpol" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "kubeflow"
      namespace = "kubeflow"
    }
    spec = {
      podSelector = {}
      policyTypes = ["Ingress", "Egress"]
      ingress     = []
      egress = [
        {
          to = [{
            namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = "kube-system" } }
            podSelector       = { matchLabels = { "k8s-app" = "kube-dns" } }
          }]
          ports = [
            { protocol = "UDP", port = 53 },
            { protocol = "TCP", port = 53 },
          ]
        },
        {
          to = [{
            ipBlock = {
              cidr   = "0.0.0.0/0"
              except = ["169.254.169.254/32"]
            }
          }]
          ports = [{ protocol = "TCP", port = 443 }]
        },
      ]
    }
  })

  depends_on = [helm_release.istiod]
}

# --- training (unmeshed; PyTorchJob pods land here) -------------------------
# Pods pull datasets from S3 (datasets/), pull HF Hub model weights
# (HF_HUB_OFFLINE=false during the model-download phase of the QLoRA
# fine-tune), upload trained adapters to S3 (adapters/), and talk to
# the K8s API (heartbeats to PyTorchJob status).
resource "kubectl_manifest" "training_netpol" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "training"
      namespace = "training"
    }
    spec = {
      podSelector = {}
      policyTypes = ["Ingress", "Egress"]
      ingress     = []
      egress = [
        {
          to = [{
            namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = "kube-system" } }
            podSelector       = { matchLabels = { "k8s-app" = "kube-dns" } }
          }]
          ports = [
            { protocol = "UDP", port = 53 },
            { protocol = "TCP", port = 53 },
          ]
        },
        # Pod Identity Agent — training-pod IAM for S3 datasets/+adapters/
        {
          to    = [{ ipBlock = { cidr = "169.254.170.23/32" } }]
          ports = [{ protocol = "TCP", port = 80 }]
        },
        # 443 outbound: S3 + STS + HuggingFace Hub (huggingface.co) +
        # K8s API. HF Hub does NOT use the Pod Identity Agent path —
        # it's plain HTTPS to a public endpoint. 0.0.0.0/0 except IMDS
        # covers all of these.
        {
          to = [{
            ipBlock = {
              cidr   = "0.0.0.0/0"
              except = ["169.254.169.254/32"]
            }
          }]
          ports = [{ protocol = "TCP", port = 443 }]
        },
      ]
    }
  })

  depends_on = [helm_release.istiod]
}

# --- vault-secrets-operator (unmeshed; controller-shape) -------------------
# VSO reconciles VaultStaticSecret / VaultDynamicSecret CRs by calling the
# Vault API and creating/updating the corresponding K8s Secret. Network
# profile:
#   Egress  Vault HTTP API on 8200 (vault.vault.svc:8200)
#           K8s API for CR watches + Secret writes
#           Pod Identity for AWS-auth backend (if used)
#           DNS
resource "kubectl_manifest" "vault_secrets_operator_netpol" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "vault-secrets-operator"
      namespace = "vault-secrets-operator"
    }
    spec = {
      podSelector = {}
      policyTypes = ["Ingress", "Egress"]
      ingress     = []
      egress = [
        {
          to = [{
            namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = "kube-system" } }
            podSelector       = { matchLabels = { "k8s-app" = "kube-dns" } }
          }]
          ports = [
            { protocol = "UDP", port = 53 },
            { protocol = "TCP", port = 53 },
          ]
        },
        # Vault HTTP API
        {
          to = [{
            namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = "vault" } }
            podSelector = {
              matchLabels = {
                "app.kubernetes.io/name" = "vault"
                "component"              = "server"
              }
            }
          }]
          ports = [{ protocol = "TCP", port = 8200 }]
        },
        # Pod Identity Agent
        {
          to    = [{ ipBlock = { cidr = "169.254.170.23/32" } }]
          ports = [{ protocol = "TCP", port = 80 }]
        },
        # K8s API
        {
          to = [{
            ipBlock = {
              cidr   = "0.0.0.0/0"
              except = ["169.254.169.254/32"]
            }
          }]
          ports = [{ protocol = "TCP", port = 443 }]
        },
      ]
    }
  })

  depends_on = [helm_release.istiod]
}

# =============================================================================
# Phase #65c: system + utility namespaces.
#
# Phase #65b's commit deferred these as out-of-scope for that round
# ("Phase #65c candidate if the cluster's threat model warrants it").
# Closing the deferral now with the SAFE subset:
#
#   default            real workload (hello) — per-app NP, not
#                      namespace-wide (so ad-hoc operator pods like
#                      smoke-test alpine, node-debugger continue
#                      to work)
#   kube-public        empty namespace — default-deny NP as
#                      hygiene (catches any future pod misconfig
#                      that lands here)
#   kube-node-lease    same
#   mount-s3           same (csi-driver runs in kube-system, not
#                      here; mount-s3 is just a placeholder ns)
#
# DELIBERATELY SKIPPED: kube-system.
#   Reasoning: kube-system contains AWS VPC CNI (aws-node DaemonSet),
#   coredns, kube-proxy, ebs-csi-controller/-node, metrics-server,
#   alb-controller, karpenter, istio-cni-node, nvidia-device-plugin.
#   A namespace-wide NP would need to allow:
#     - kubelet probe ingress (every pod)
#     - kube-apiserver webhook ingress (alb-controller, metrics-server)
#     - DNS lookups from every pod in the cluster (coredns)
#     - kube-proxy iptables setup (host network, NP doesn't even apply)
#     - aws-node host networking (NP doesn't apply to hostNetwork=true)
#     - karpenter calls to AWS APIs
#     - ebs-csi to EBS APIs
#   The risk-of-breakage from a wrong rule is "cluster pod-creation
#   stops" or "DNS resolution dies cluster-wide". Per-component NPs
#   would be safer but represent ~5-10 separate NetworkPolicy
#   resources, each with risk. Out of scope for tonight.
#
#   The mitigating factor: kube-system is owned by EKS-managed addons
#   (vpc-cni, kube-proxy, coredns, eks-pod-identity-agent, ebs-csi)
#   which AWS validates against EKS's threat model. Adding our own NP
#   on top would primarily protect against pod-to-pod lateral movement
#   FROM other namespaces, but our existing per-namespace NPs already
#   restrict OUTBOUND to specific kube-system targets (CoreDNS, Pod
#   Identity Agent). The "lock kube-system internally" gap is real
#   but bounded.
# =============================================================================

# --- default (per-app NP for hello) -----------------------------------------
# Selector targets the hello workload specifically — leaves the rest of
# `default` ns unprotected so ad-hoc operator pods (kyverno smoke-tests,
# node-debugger, phase65b-test HTTPRoute) work without NP edits.
#
# hello is NOT meshed (default ns has no istio-injection label), so the
# meshed-namespace ingress pattern doesn't apply. Traffic shape:
#   Ingress: gateway-system Envoy pods (HTTPRoute target)
#   Egress:  none in particular (hello is a static-content service)
resource "kubectl_manifest" "default_hello_netpol" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "hello"
      namespace = "default"
    }
    spec = {
      podSelector = {
        matchLabels = { app = "hello" }
      }
      policyTypes = ["Ingress", "Egress"]
      ingress = [{
        from = [{
          namespaceSelector = {
            matchLabels = {
              "kubernetes.io/metadata.name" = "gateway-system"
            }
          }
        }]
      }]
      # DNS only — hello's container is nginx serving static content,
      # no upstream calls needed.
      egress = [{
        to = [{
          namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = "kube-system" } }
          podSelector       = { matchLabels = { "k8s-app" = "kube-dns" } }
        }]
        ports = [
          { protocol = "UDP", port = 53 },
          { protocol = "TCP", port = 53 },
        ]
      }]
    }
  })
}

# --- kube-public (default-deny hygiene) -------------------------------------
# Empty namespace today. NetworkPolicy with podSelector={} matches all
# (zero) pods in this namespace — has no effect today, but if/when
# something lands here by misconfiguration, default-deny catches it.
resource "kubectl_manifest" "kube_public_netpol" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "default-deny"
      namespace = "kube-public"
    }
    spec = {
      podSelector = {}
      policyTypes = ["Ingress", "Egress"]
      # No ingress, no egress — explicit empty arrays. Anything that
      # lands here is dead in the water until an operator adds rules.
      ingress = []
      egress  = []
    }
  })
}

# --- kube-node-lease (default-deny hygiene) ---------------------------------
resource "kubectl_manifest" "kube_node_lease_netpol" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "default-deny"
      namespace = "kube-node-lease"
    }
    spec = {
      podSelector = {}
      policyTypes = ["Ingress", "Egress"]
      ingress     = []
      egress      = []
    }
  })
}

# --- mount-s3 (default-deny hygiene) ----------------------------------------
# The aws-mountpoint-s3-csi-driver actually runs in kube-system per
# AWS's EKS addon convention. mount-s3 ns exists from earlier
# experimentation but holds no pods today. If/when we ever deploy the
# csi-driver here directly (vs the addon), remove this NP and write
# specific rules.
resource "kubectl_manifest" "mount_s3_netpol" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "default-deny"
      namespace = "mount-s3"
    }
    spec = {
      podSelector = {}
      policyTypes = ["Ingress", "Egress"]
      ingress     = []
      egress      = []
    }
  })
}

# =============================================================================
# Phase #65d: kube-system per-component NetworkPolicies.
#
# Earlier (Phase #65c) I deferred kube-system citing risk of namespace-
# wide NP breaking CNI/DNS/kubelet. Closing the deferral now with the
# RIGHT pattern: per-component NPs targeting individual workloads
# rather than a namespace-wide podSelector={}.
#
# What's covered (4 components, all pod-network):
#
#   coredns                       Highest-stakes: every pod in the
#                                 cluster calls it for DNS resolution.
#   metrics-server                K8s API extension (Phase #80b
#                                 prometheus-adapter sibling pattern)
#   aws-load-balancer-controller  Admission webhook for Ingress/
#                                 TargetGroupBinding CRDs
#   karpenter                     NodePool reconciler + admission
#                                 webhook for NodePool/EC2NodeClass CRUD
#
# What's NOT covered (intentionally):
#
#   hostNetwork=true pods         NetworkPolicy doesn't apply. These
#                                 use the node's network namespace
#                                 directly. Components: aws-node (VPC
#                                 CNI), kube-proxy, eks-pod-identity-
#                                 agent, nvidia-device-plugin (likely),
#                                 dcgm-exporter (DaemonSet).
#
#   Other low-risk components     ebs-csi-controller, ebs-csi-node,
#                                 s3-csi-controller, s3-csi-node,
#                                 istio-cni-node. Each calls outbound
#                                 to AWS APIs (CSI) or has minimal
#                                 surface (cni-node sets up iptables
#                                 via host paths, not network). Adding
#                                 NPs for these would have low security
#                                 yield + non-trivial maintenance burden
#                                 (every CSI driver upgrade may change
#                                 internal port usage).
#
# After Phase #65d, kube-system has explicit ingress/egress rules on
# the 4 components that handle CRITICAL CLUSTER-WIDE TRAFFIC. The
# uncovered components are either NP-immune (hostNetwork) or low-risk.
# The "lock kube-system completely" goal is now unachievable as a
# matter of mechanism (hostNetwork is exempt by K8s design); this is
# as close as we can get without rewriting the AWS VPC CNI.
# =============================================================================

# --- coredns ----------------------------------------------------------------
# Highest-stakes NP in this rollout. EVERY pod in the cluster does
# DNS lookups against CoreDNS. Wrong rule here = cluster-wide DNS
# outage = nothing works.
#
# Ingress: port 53 (DNS) + 9153 (metrics) from ANYWHERE.
#   "Anywhere" because pods in any namespace need DNS. The CoreDNS
#   binary itself rate-limits + filters to A/AAAA/CNAME records for
#   the cluster zones; the L3 path is intentionally wide.
# Egress:  53 to 0.0.0.0/0 (CoreDNS forwards to upstream resolver
#          which on EKS is the VPC DNS server at <VPC CIDR>+2;
#          allowing 0.0.0.0/0:53 covers that without baking the
#          VPC CIDR into this resource).
#          K8s API on 443 for service/endpoint watches.
resource "kubectl_manifest" "coredns_netpol" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "coredns"
      namespace = "kube-system"
    }
    spec = {
      podSelector = {
        matchLabels = { "k8s-app" = "kube-dns" }
      }
      policyTypes = ["Ingress", "Egress"]
      ingress = [{
        ports = [
          { protocol = "UDP", port = 53 },
          { protocol = "TCP", port = 53 },
          { protocol = "TCP", port = 9153 }, # Prometheus metrics
        ]
      }]
      egress = [
        # Upstream DNS forwarder (VPC DNS resolver). Allowing 0.0.0.0
        # broadly because the VPC CIDR isn't baked into this resource.
        # Real production would use ipBlock with the actual VPC CIDR.
        {
          to = [{
            ipBlock = { cidr = "0.0.0.0/0" }
          }]
          ports = [
            { protocol = "UDP", port = 53 },
            { protocol = "TCP", port = 53 },
          ]
        },
        # K8s API for Service/Endpoint watches (CoreDNS's
        # `kubernetes` plugin queries the API to populate the
        # cluster zone)
        {
          to = [{
            ipBlock = {
              cidr   = "0.0.0.0/0"
              except = ["169.254.169.254/32"]
            }
          }]
          ports = [{ protocol = "TCP", port = 443 }]
        },
      ]
    }
  })
}

# --- metrics-server ---------------------------------------------------------
# K8s aggregated API server (same shape as prometheus-adapter in
# Phase #80b). kube-apiserver calls /apis/metrics.k8s.io/v1beta1/...
# from outside the cluster's pod network.
#
# Ingress: 4443 (the metrics-server's TLS-secured aggregated-API
#          port) from anywhere — kube-apiserver source IP isn't
#          a documented constant.
# Egress:  10250/TCP to every node (kubelet's metrics endpoint).
#          Allowing 0.0.0.0/0:10250 since node CIDRs aren't fixed.
#          Plus K8s API on 443.
resource "kubectl_manifest" "metrics_server_netpol" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "metrics-server"
      namespace = "kube-system"
    }
    spec = {
      podSelector = {
        matchLabels = { "app.kubernetes.io/name" = "metrics-server" }
      }
      policyTypes = ["Ingress", "Egress"]
      ingress = [{
        ports = [{ protocol = "TCP", port = 4443 }]
      }]
      egress = [
        {
          to = [{
            namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = "kube-system" } }
            podSelector       = { matchLabels = { "k8s-app" = "kube-dns" } }
          }]
          ports = [
            { protocol = "UDP", port = 53 },
            { protocol = "TCP", port = 53 },
          ]
        },
        # 10250 to all node CIDRs — kubelet's resource-metrics endpoint
        {
          to = [{
            ipBlock = {
              cidr   = "0.0.0.0/0"
              except = ["169.254.169.254/32"]
            }
          }]
          ports = [{ protocol = "TCP", port = 10250 }]
        },
        # K8s API
        {
          to = [{
            ipBlock = {
              cidr   = "0.0.0.0/0"
              except = ["169.254.169.254/32"]
            }
          }]
          ports = [{ protocol = "TCP", port = 443 }]
        },
      ]
    }
  })
}

# --- aws-load-balancer-controller -------------------------------------------
# Admission webhook for Ingress + TargetGroupBinding CRDs (and Service
# annotations). failurePolicy=Fail in the chart's default values.
#
# Ingress: 9443 (webhook), 8080 (metrics)
# Egress:  ELBv2 + EC2 + ACM APIs via Pod Identity + K8s API
resource "kubectl_manifest" "alb_controller_netpol" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "aws-load-balancer-controller"
      namespace = "kube-system"
    }
    spec = {
      podSelector = {
        matchLabels = { "app.kubernetes.io/name" = "aws-load-balancer-controller" }
      }
      policyTypes = ["Ingress", "Egress"]
      ingress = [{
        ports = [
          { protocol = "TCP", port = 9443 },
          { protocol = "TCP", port = 8080 },
        ]
      }]
      egress = [
        {
          to = [{
            podSelector = { matchLabels = { "k8s-app" = "kube-dns" } }
          }]
          ports = [
            { protocol = "UDP", port = 53 },
            { protocol = "TCP", port = 53 },
          ]
        },
        {
          to    = [{ ipBlock = { cidr = "169.254.170.23/32" } }]
          ports = [{ protocol = "TCP", port = 80 }]
        },
        {
          to = [{
            ipBlock = {
              cidr   = "0.0.0.0/0"
              except = ["169.254.169.254/32"]
            }
          }]
          ports = [{ protocol = "TCP", port = 443 }]
        },
      ]
    }
  })
}

# --- karpenter --------------------------------------------------------------
# NodePool reconciler + admission webhook for NodePool/EC2NodeClass.
# Calls AWS EC2 + Pricing APIs to provision nodes.
#
# Ingress: 8443 (webhook), 8080 (metrics), 8081 (health)
# Egress:  EC2 + Pricing APIs via Pod Identity + K8s API
resource "kubectl_manifest" "karpenter_netpol" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "karpenter"
      namespace = "kube-system"
    }
    spec = {
      podSelector = {
        matchLabels = { "app.kubernetes.io/name" = "karpenter" }
      }
      policyTypes = ["Ingress", "Egress"]
      ingress = [{
        ports = [
          { protocol = "TCP", port = 8443 },
          { protocol = "TCP", port = 8080 },
          { protocol = "TCP", port = 8081 },
        ]
      }]
      egress = [
        {
          to = [{
            podSelector = { matchLabels = { "k8s-app" = "kube-dns" } }
          }]
          ports = [
            { protocol = "UDP", port = 53 },
            { protocol = "TCP", port = 53 },
          ]
        },
        {
          to    = [{ ipBlock = { cidr = "169.254.170.23/32" } }]
          ports = [{ protocol = "TCP", port = 80 }]
        },
        {
          to = [{
            ipBlock = {
              cidr   = "0.0.0.0/0"
              except = ["169.254.169.254/32"]
            }
          }]
          ports = [{ protocol = "TCP", port = 443 }]
        },
      ]
    }
  })
}
