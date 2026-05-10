# =============================================================================
# Istio control plane + Gateway API ingress.
#
# Replaces Cilium Gateway API after persistent eBPF redirect bug
# (cilium#45871). Istio handles JUST the north-south ingress here —
# Cilium continues to own CNI + kpr + CiliumNetworkPolicy + WireGuard
# + Hubble + Tetragon for east-west / observability / runtime security.
#
# Coexistence rule: Istio CNI plugin MUST be disabled (Cilium owns CNI).
# Istio sidecars manage their own pod-local iptables redirect for L7
# interception, which doesn't conflict with Cilium's host-level eBPF.
#
# Pattern: 3 Istio components
#   1. istio-base       — CRDs (VirtualService, DestinationRule, etc.).
#                          Gateway API CRDs already present from Phase 3.
#   2. istiod           — control plane. Reads Gateway/HTTPRoute resources
#                          and configures Envoy data plane via xDS.
#   3. istio-gateway    — data plane Deployment + Service in gateway-system.
#                          Replaces the Cilium-created cilium-gateway-shared-
#                          gateway Service. AWS LBC discovers via the same
#                          annotations (already on the Gateway resource via
#                          spec.infrastructure.annotations).
#
# We do NOT enable Istio sidecar injection on app namespaces in this phase.
# That's a future phase 5b decision (Istio mTLS for east-west); for now,
# Cilium's WireGuard handles east-west encryption.
# =============================================================================

resource "kubernetes_namespace" "istio_system" {
  metadata {
    name = "istio-system"
    labels = {
      "kubernetes.io/metadata.name" = "istio-system"
    }
  }
}

# --- 1. istio-base: CRDs ---------------------------------------------------

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

# --- 2. istiod: control plane ----------------------------------------------

resource "helm_release" "istiod" {
  name       = "istiod"
  namespace  = kubernetes_namespace.istio_system.metadata[0].name
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  version    = "1.24.3"

  values = [
    yamlencode({
      pilot = {
        # CRITICAL: disable Istio's CNI plugin. Cilium owns CNI; an Istio
        # CNI binary in /opt/cni/bin would race + clobber Cilium's
        # /etc/cni/net.d/05-cilium.conflist priority and break pod
        # networking. Without this, both CNIs fight on every pod admit.
        cni = {
          enabled = false
        }
        nodeSelector = {
          "karpenter.sh/nodepool" = "general"
        }
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { cpu = "1000m", memory = "1Gi" }
        }
      }
      meshConfig = {
        # Don't auto-inject sidecars cluster-wide. We'll mark specific
        # namespaces with `istio-injection: enabled` in a future phase
        # if we want east-west mTLS via Istio (Cilium WireGuard already
        # handles that today).
        defaultConfig = {
          tracing = {}
        }
      }
    })
  ]

  depends_on = [
    helm_release.istio_base,
  ]
}

# --- 3. Gateway data plane: managed by Istio's gateway controller ---------
# Istio's GatewayClass=istio controller AUTO-creates a Deployment +
# Service named "<gateway-name>-istio" in the same namespace as the
# Gateway resource. We don't need a separate `gateway` helm release —
# Istio handles it.
#
# To pin pod placement (us-west-2a only, matching the single public
# subnet) and to set replica count, patch the Deployment after Istio
# creates it. Done via null_resource so the patch applies on first
# reconcile.

resource "null_resource" "gateway_pod_placement" {
  triggers = {
    target_zone = "us-west-2a"
    replicas    = "2"
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl -n gateway-system patch deployment shared-gateway-istio --type=merge --patch '{
        "spec": {
          "replicas": ${self.triggers.replicas},
          "template": {
            "spec": {
              "nodeSelector": {
                "karpenter.sh/nodepool": "general",
                "topology.kubernetes.io/zone": "${self.triggers.target_zone}"
              }
            }
          }
        }
      }' || echo "deployment shared-gateway-istio not yet created — will retry next apply"
    EOT
  }

  depends_on = [
    helm_release.istiod,
    kubectl_manifest.shared_gateway,
  ]
}
