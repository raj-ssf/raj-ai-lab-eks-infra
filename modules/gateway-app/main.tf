# ReferenceGrant: authorize the shared Gateway to read the app's
# TLS Secret cross-ns. Without this, the Gateway listener's
# certificateRefs to a Secret in this app's namespace are rejected
# with status condition Programmed=False, reason=InvalidCertificateRef.
#
# Scoped tightly: only the named Secret kind+name, only from
# Gateways in gateway_namespace. We don't grant blanket access to
# all Secrets — minimal surface for cross-ns reads.
resource "kubectl_manifest" "cert_reference_grant" {
  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1beta1"
    kind       = "ReferenceGrant"
    metadata = {
      name      = "allow-gateway-system-cert-read"
      namespace = var.namespace
    }
    spec = {
      from = [{
        group     = "gateway.networking.k8s.io"
        kind      = "Gateway"
        namespace = var.gateway_namespace
      }]
      to = [{
        group = ""
        kind  = "Secret"
        name  = var.cert_secret_name
      }]
    }
  })
}

# Istio AuthorizationPolicy: allow the gateway pod's SPIFFE identity
# to reach this app's backend pods.
#
# When traffic flows external → NLB → gateway-system/Envoy → backend,
# the backend's istio-proxy sidecar enforces inbound AuthZ. Cluster-
# wide deny-all means an explicit ALLOW per source principal is
# required. This is the moral equivalent of allow-ingress-nginx but
# for the new Istio Gateway path.
resource "kubectl_manifest" "authz_allow_gateway" {
  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"
    metadata = {
      name      = "allow-gateway-system"
      namespace = var.namespace
    }
    spec = {
      action = "ALLOW"
      rules = [{
        from = [{
          source = {
            principals = [
              "cluster.local/ns/${var.gateway_namespace}/sa/${var.gateway_sa_name}",
            ]
          }
        }]
      }]
    }
  })
}
