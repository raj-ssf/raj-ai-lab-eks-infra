# =============================================================================
# cert-manager Certificates for Phase 3 gateway listeners.
#
# Each Certificate produces a Secret in its own namespace; the Gateway
# listener references the Secret via certificateRefs (cross-ns is
# authorized by the per-ns ReferenceGrant in gateway-system.tf).
#
# ClusterIssuer: letsencrypt-prod (rate-limited to 50 certs/week per
# domain — fine for two listeners). Falls back to letsencrypt-staging
# during dev work; switch ref by editing the issuerRef block.
#
# DNS-01 vs HTTP-01: clusterissuers.tf wires HTTP-01 by default, which
# requires the Gateway to be reachable on port 80 for the challenge.
# Cilium's Gateway listens on 443 by default. The cert-manager
# acme-challenge logic creates a temporary HTTPRoute on port 80 of the
# Gateway, but only if the gatewayHTTPRouteParentRefs is set on the
# ClusterIssuer (see clusterissuers.tf).
# =============================================================================

resource "kubectl_manifest" "grafana_cert" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "grafana-tls"
      namespace = "monitoring"
    }
    spec = {
      secretName = "grafana-tls"
      issuerRef = {
        name  = "letsencrypt-prod"
        kind  = "ClusterIssuer"
        group = "cert-manager.io"
      }
      commonName = "grafana.${var.domain}"
      dnsNames   = ["grafana.${var.domain}"]
    }
  })

  depends_on = [
    kubectl_manifest.gateway_api_crds,
  ]
}

resource "kubectl_manifest" "hubble_ui_cert" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "hubble-ui-tls"
      namespace = "kube-system"
    }
    spec = {
      secretName = "hubble-ui-tls"
      issuerRef = {
        name  = "letsencrypt-prod"
        kind  = "ClusterIssuer"
        group = "cert-manager.io"
      }
      commonName = "hubble.${var.domain}"
      dnsNames   = ["hubble.${var.domain}"]
    }
  })

  depends_on = [
    kubectl_manifest.gateway_api_crds,
  ]
}

resource "kubectl_manifest" "argocd_cert" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "argocd-tls"
      namespace = "argocd"
    }
    spec = {
      secretName = "argocd-tls"
      issuerRef = {
        name  = "letsencrypt-prod"
        kind  = "ClusterIssuer"
        group = "cert-manager.io"
      }
      commonName = "argocd.${var.domain}"
      dnsNames   = ["argocd.${var.domain}"]
    }
  })

  depends_on = [
    kubectl_manifest.gateway_api_crds,
    kubernetes_namespace.argocd,
  ]
}
