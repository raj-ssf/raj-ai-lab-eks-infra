# gateway-system namespace + the shared Istio Gateway.
#
# This is the north-south ingress equivalent of istio-zero-trust.tf:
# infrastructure that other workloads depend on but doesn't belong to
# any single app. The Gateway resource lives here; HTTPRoutes that
# attach to it (cross-ns parentRef) live in their respective app
# manifests in the apps repo.
#
# Why a dedicated namespace, not istio-system or default:
#   - Convention from Gateway API community + Istio docs.
#   - Lifecycle separation: Gateway resource churn shouldn't touch
#     istiod's namespace (where mistaken edits would be high-blast).
#   - When you eventually want per-tenant gateways (different cert
#     authorities, different listener policies), they each get their
#     own namespace cleanly.
#
# Why NO istio-injection label on gateway-system:
#   - The Istio Gateway controller deploys its own Envoy *as the
#     gateway pods* in this namespace. They aren't sidecared
#     workloads — they ARE the data plane. Adding the injection
#     label would re-inject istio-proxy onto Envoy itself, creating
#     a sidecar-on-Envoy mess.
#
# Phase 1 scope: ONE listener for rag.ekstest.com referencing the
# existing cert Secret in the rag namespace via ReferenceGrant.
# Subsequent phases add listeners for the other 9 hosts.

resource "kubernetes_namespace" "gateway_system" {
  metadata {
    name = "gateway-system"
    labels = {
      # Used by NetworkPolicies + AuthZ rules that need to identify
      # the gateway namespace specifically.
      "kubernetes.io/metadata.name" = "gateway-system"
    }
    # Explicitly do NOT set istio-injection here. See header comment.
  }
}

# Phase 1 Gateway: one listener for rag.ekstest.com. Subsequent
# phases append listeners for chat, keycloak, langfuse, langgraph,
# llm, grafana, vault, argocd, hello.
#
# Listener model: each (host, port, protocol) is its own listener.
# Istio's Gateway controller materializes ONE LoadBalancer Service
# fronting them all (single NLB) — listener objects share the LB,
# they don't each spawn one.
#
# allowedRoutes.namespaces.from = Selector + matchLabels constrains
# WHICH namespaces are allowed to attach HTTPRoutes via parentRef.
# We label app namespaces with `gateway-access=enabled` to opt in.
# Without the selector, default is "Same namespace" which would
# require all HTTPRoutes to live in gateway-system — wrong split.
resource "kubectl_manifest" "shared_gateway" {
  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = "shared-gateway"
      namespace = kubernetes_namespace.gateway_system.metadata[0].name
      annotations = {
        # Same NLB type the existing ingress-nginx uses. Istio's
        # gateway controller passes annotations through to the
        # Service it creates. Without this, the default is a CLB.
        "service.beta.kubernetes.io/aws-load-balancer-type"            = "nlb"
        "service.beta.kubernetes.io/aws-load-balancer-scheme"          = "internet-facing"
        "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
      }
    }
    spec = {
      gatewayClassName = "istio"
      listeners = [
        {
          name     = "rag-https"
          hostname = "rag.ekstest.com"
          port     = 443
          protocol = "HTTPS"
          tls = {
            mode = "Terminate"
            certificateRefs = [
              {
                # Cross-ns ref — requires ReferenceGrant in rag ns
                # (see allow-gateway-cert-read.yaml in apps repo).
                kind      = "Secret"
                name      = "rag-service-tls"
                namespace = "rag"
              },
            ]
          }
          allowedRoutes = {
            namespaces = {
              from = "Selector"
              selector = {
                matchLabels = {
                  "gateway-access" = "enabled"
                }
              }
            }
          }
        },
      ]
    }
  })

  depends_on = [
    kubernetes_namespace.gateway_system,
    kubectl_manifest.gateway_api_crds,
  ]
}

# ReferenceGrant: authorize the Gateway in gateway-system to read
# the rag-service-tls Secret in rag.
#
# Gateway API's cross-namespace reference model: a Gateway listener
# in NS-A pointing at a Secret in NS-B is REJECTED unless NS-B
# has a ReferenceGrant explicitly authorizing it. This is the
# moral equivalent of "the resource owner has to opt in to the
# reader" — much stricter than the old Ingress model where ingress
# controllers could read Secrets across namespaces with broad RBAC.
#
# The ReferenceGrant lives in the TARGET namespace (rag), specifies
# WHO can read (Gateways from gateway-system) and WHAT they can read
# (this specific Secret kind). Wildcard "all Secrets" is allowed
# but we scope tighter — explicit names per granted resource.
resource "kubectl_manifest" "rag_cert_reference_grant" {
  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1beta1"
    kind       = "ReferenceGrant"
    metadata = {
      name      = "allow-gateway-system-cert-read"
      namespace = "rag"
    }
    spec = {
      from = [{
        group     = "gateway.networking.k8s.io"
        kind      = "Gateway"
        namespace = "gateway-system"
      }]
      to = [{
        group = ""        # core API group
        kind  = "Secret"
        name  = "rag-service-tls"
      }]
    }
  })

  depends_on = [
    kubectl_manifest.gateway_api_crds,
  ]
}

# Label the rag namespace so HTTPRoutes there can attach to
# shared-gateway via parentRef. This is the opt-in mechanism for
# cross-namespace route attachment under Gateway API. Without this
# label, the Gateway's allowedRoutes.namespaces.selector won't
# match rag, and any HTTPRoute attempting to attach will be
# rejected with status condition Accepted=False, reason=NotAllowedByListeners.
resource "kubernetes_labels" "rag_gateway_access" {
  api_version = "v1"
  kind        = "Namespace"
  metadata {
    name = "rag"
  }
  labels = {
    "gateway-access" = "enabled"
  }
  force         = true
  field_manager = "terraform-raj-ai-lab"

  depends_on = [
    kubectl_manifest.shared_gateway,
  ]
}
