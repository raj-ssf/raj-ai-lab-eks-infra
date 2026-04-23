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
