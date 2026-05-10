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

resource "kubectl_manifest" "keycloak_cert" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "keycloak-tls"
      namespace = "keycloak"
    }
    spec = {
      secretName = "keycloak-tls"
      issuerRef = {
        name  = "letsencrypt-prod"
        kind  = "ClusterIssuer"
        group = "cert-manager.io"
      }
      commonName = "keycloak.${var.domain}"
      dnsNames   = ["keycloak.${var.domain}"]
    }
  })

  depends_on = [
    kubectl_manifest.gateway_api_crds,
    kubernetes_namespace.keycloak,
  ]
}

resource "kubectl_manifest" "langfuse_cert" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "langfuse-tls"
      namespace = "langfuse"
    }
    spec = {
      secretName = "langfuse-tls"
      issuerRef = {
        name  = "letsencrypt-prod"
        kind  = "ClusterIssuer"
        group = "cert-manager.io"
      }
      commonName = "langfuse.${var.domain}"
      dnsNames   = ["langfuse.${var.domain}"]
    }
  })

  depends_on = [
    kubectl_manifest.gateway_api_crds,
    kubernetes_namespace.langfuse,
  ]
}

resource "kubectl_manifest" "rollouts_cert" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "rollouts-tls"
      namespace = "argo-rollouts"
    }
    spec = {
      secretName = "rollouts-tls"
      issuerRef = {
        name  = "letsencrypt-prod"
        kind  = "ClusterIssuer"
        group = "cert-manager.io"
      }
      commonName = "rollouts.${var.domain}"
      dnsNames   = ["rollouts.${var.domain}"]
    }
  })

  depends_on = [
    kubectl_manifest.gateway_api_crds,
    kubernetes_namespace.argo_rollouts,
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

resource "kubectl_manifest" "vault_cert" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "vault-tls"
      namespace = "vault"
    }
    spec = {
      secretName = "vault-tls"
      issuerRef = {
        name  = "letsencrypt-prod"
        kind  = "ClusterIssuer"
        group = "cert-manager.io"
      }
      commonName = "vault.${var.domain}"
      dnsNames   = ["vault.${var.domain}"]
    }
  })

  depends_on = [
    kubectl_manifest.gateway_api_crds,
    helm_release.vault,
  ]
}

# SAN cert covering both hello hostnames. Single Secret consumed by both the
# `hello-https` and `hello2-https` listeners on shared-gateway.
resource "kubectl_manifest" "hello_cert" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "hello-tls"
      namespace = "default"
    }
    spec = {
      secretName = "hello-tls"
      issuerRef = {
        name  = "letsencrypt-prod"
        kind  = "ClusterIssuer"
        group = "cert-manager.io"
      }
      commonName = "hello.${var.domain}"
      dnsNames = [
        "hello.${var.domain}",
        "hello2.${var.domain}",
      ]
    }
  })

  depends_on = [
    kubectl_manifest.gateway_api_crds,
  ]
}
