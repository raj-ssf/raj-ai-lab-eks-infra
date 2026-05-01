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
