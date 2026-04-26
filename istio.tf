# Istio service mesh — sidecar mode with istio-cni for EKS VPC CNI.
#
# Three charts, installed in order:
#   1. base  — CRDs + cluster-scoped RBAC
#   2. cni   — DaemonSet that chains into VPC CNI; sets up per-pod iptables
#              for Envoy traffic capture without needing init container with
#              NET_ADMIN on every pod
#   3. istiod — control plane (xDS server, cert rotation, config pusher)
#
# Ingress gateway chart is deferred; we keep NGINX + ALB controller doing
# north-south traffic. Istio handles east-west (pod-to-pod) only in phase 1.

resource "kubernetes_namespace" "istio_system" {
  metadata {
    name = "istio-system"
    labels = {
      # istiod's webhook config expects this label for its own validating
      # webhook to find the right namespace.
      "istio.io/rev" = "default"
    }
  }
}

resource "helm_release" "istio_base" {
  name       = "istio-base"
  namespace  = kubernetes_namespace.istio_system.metadata[0].name
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "base"
  version    = "1.24.3"

  values = [
    yamlencode({
      defaultRevision = "default"
    })
  ]

  depends_on = [module.eks]
}

# istio-cni as a DaemonSet in kube-system. Chains into VPC CNI so Envoy
# traffic interception doesn't need a privileged init container per pod.
# This is the EKS-recommended install path.
resource "helm_release" "istio_cni" {
  name       = "istio-cni"
  namespace  = "kube-system"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "cni"
  version    = "1.24.3"

  values = [
    yamlencode({
      cni = {
        # Chained mode: inserted after VPC CNI in /etc/cni/net.d.
        chained      = true
        excludeNamespaces = ["kube-system", "istio-system"]
      }
    })
  ]

  depends_on = [helm_release.istio_base]
}

resource "helm_release" "istiod" {
  name       = "istiod"
  namespace  = kubernetes_namespace.istio_system.metadata[0].name
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  version    = "1.24.3"

  values = [
    yamlencode({
      global = {
        meshID  = "raj-ai-lab-mesh"
        network = "raj-ai-lab-network"
        multiCluster = {
          clusterName = module.eks.cluster_name
        }
      }
      # Keep the control plane small for a 3-node lab. Bump replicas/memory
      # when the mesh grows beyond a handful of workloads.
      pilot = {
        replicaCount = 1
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
        env = {
          # Native sidecars: inject istio-proxy as an initContainer with
          # restartPolicy=Always. Envoy comes up DURING the init phase, so
          # later init containers (e.g., vault-agent-init on rag-service)
          # can reach the network through the already-running sidecar.
          # Without this, istio-init installs iptables redirects to port
          # 15001, but Envoy isn't up yet → subsequent init containers hang.
          # Requires K8s 1.28+ (EKS 1.34 supports it).
          ENABLE_NATIVE_SIDECARS = "true"
        }
        # CRITICAL: tell istiod's injector that istio-cni is installed.
        # Without this, the injector defaults to adding an istio-init
        # init container to every meshed pod that runs istio-iptables
        # to set up traffic capture. But istio-cni-node ALSO sees these
        # pods and SKIPS them ("excluded due to being already injected
        # with istio-init container") — so the CNI plugin's iptables
        # setup never runs. Result: pods get a sidecar but iptables
        # never redirects outbound traffic to Envoy → traffic bypasses
        # the mesh entirely → mTLS doesn't engage → AuthorizationPolicy
        # rules with principal-based ALLOW match nothing → 403 RBAC.
        #
        # Setting pilot.cni.enabled=true makes the injector skip the
        # istio-init container; istio-cni-node then takes over and sets
        # up iptables via the CNI plugin chain on pod creation. This is
        # the canonical Istio + CNI integration mode.
        #
        # Diagnosed 2026-04-25 after several hours of debugging mTLS
        # not engaging despite all surface-level config (sidecar
        # injection, DestinationRules, AuthorizationPolicies) looking
        # correct. The injector ConfigMap showed pilot.cni.enabled =
        # False; istio-cni-node logs showed every meshed pod being
        # excluded. The two halves of the integration weren't talking.
        cni = {
          enabled = true
        }
      }
      # Prometheus picks up istiod + envoy metrics via ServiceMonitors the
      # chart ships when telemetry.enabled (true by default since 1.22).
    })
  ]

  depends_on = [helm_release.istio_base]
}

# Label namespaces for sidecar injection. kubernetes_labels merges labels
# without owning the Namespace object — ArgoCD's CreateNamespace=true
# syncOption and these labels can coexist.
#
# Skipped intentionally (see the commit message for reasoning):
#   vault           (raft port 8201 uses its own TLS — double-encrypt breaks)
#   monitoring      (Prometheus scrape loops, Tempo OTel path)
#   cert-manager    (all traffic is to external Route53 / ACME)
#   external-dns    (same)
#   ingress-nginx   (north-south entry, not a mesh participant)
#   vault-secrets-operator, kube-system, istio-system (system)
locals {
  istio_meshed_namespaces = toset([
    "rag",
    "qdrant",
    "keycloak",
    "argocd",
    "langgraph",
  ])
}

resource "kubernetes_labels" "istio_injection" {
  for_each = local.istio_meshed_namespaces

  api_version = "v1"
  kind        = "Namespace"
  metadata {
    name = each.value
  }
  labels = {
    "istio-injection" = "enabled"
  }
  force         = true
  field_manager = "terraform-raj-ai-lab"

  depends_on = [
    helm_release.istiod,
    helm_release.istio_cni,
    # Namespaces come up via their respective apps/helm_releases. Labelling
    # before the namespace exists is fine for kubernetes_labels (it'll retry).
    kubectl_manifest.rag_service_app,
    kubectl_manifest.qdrant_app,
    kubernetes_namespace.keycloak,
    kubernetes_namespace.argocd,
  ]
}

# STRICT mTLS on qdrant. qdrant's only caller is rag-service (meshed), so
# enforcing STRICT here rejects any plaintext / non-mTLS traffic without
# breaking a user-facing path. We can't flip mesh-wide STRICT because
# NGINX ingress isn't meshed — its inbound traffic to rag/keycloak/argocd
# pods would get rejected.
resource "kubectl_manifest" "qdrant_peer_auth_strict" {
  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1beta1"
    kind       = "PeerAuthentication"
    metadata = {
      name      = "default"
      namespace = "qdrant"
    }
    spec = {
      mtls = {
        mode = "STRICT"
      }
    }
  })

  depends_on = [
    helm_release.istiod,
    kubernetes_labels.istio_injection,
  ]
}

# =============================================================================
# Prometheus scrape config for Istio — required for the dashboards to populate.
# istio/istiod chart doesn't ship ServiceMonitor/PodMonitor; without these, the
# istio_requests_total and pilot_xds metrics never arrive in Prometheus even
# though Envoy + istiod are emitting them.
# =============================================================================

# Envoy sidecar scraping gets kicked up to kube-prometheus-stack's
# additionalScrapeConfigs instead of a PodMonitor (see prometheus-stack.tf).
# PodMonitor would always auto-generate a
#   keep container_port_number == 15090
# relabel, and Prometheus 2.x pod-SD doesn't enumerate initContainer ports.
# With native sidecars (istio-proxy is an init container), every target gets
# dropped. A hand-rolled scrape config rewrites __address__ to pod_ip:15090
# directly, sidestepping the port enumeration problem. Revisit once we're
# on Prometheus 3.x (kube-prometheus-stack 76+), which does enumerate
# initContainer ports.

# istiod (Pilot) control-plane metrics on port 15014. Powers the Control Plane
# dashboard.
resource "kubectl_manifest" "istiod_service_monitor" {
  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      name      = "istiod"
      namespace = kubernetes_namespace.istio_system.metadata[0].name
      labels    = { release = "kube-prometheus-stack" }
    }
    spec = {
      selector = {
        matchLabels = { istio = "pilot" }
      }
      endpoints = [{
        port     = "http-monitoring"
        interval = "15s"
      }]
    }
  })

  depends_on = [helm_release.kube_prometheus_stack, helm_release.istiod]
}

# Layer-7 authorization on top of mTLS: only the rag-service SA can access
# qdrant. Any other meshed SPIFFE identity (e.g., a random pod in another
# meshed ns that happens to have mTLS) is rejected with RBAC: access denied.
# STRICT mTLS alone says "encrypted+authenticated"; this adds "authorized".
resource "kubectl_manifest" "qdrant_authz_policy" {
  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"
    metadata = {
      name      = "allow-rag-service-only"
      namespace = "qdrant"
    }
    spec = {
      action = "ALLOW"
      # Only principals matching this list are allowed. Action=ALLOW with a
      # rules block means "allow if any rule matches, deny otherwise."
      rules = [{
        from = [{
          source = {
            principals = ["cluster.local/ns/rag/sa/rag-service"]
          }
        }]
      }]
    }
  })

  depends_on = [
    helm_release.istiod,
    kubectl_manifest.qdrant_peer_auth_strict,
  ]
}
