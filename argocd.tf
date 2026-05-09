# =============================================================================
# Phase 4a of Cilium migration: ArgoCD GitOps controller.
#
# Differences from the old (Istio-era) argocd.tf in _disabled:
#   - No istio-injection label on the namespace (Istio is gone).
#   - No OIDC config (Keycloak comes in Phase 4b; until then, ArgoCD uses
#     local admin login). The chart wires OIDC via configs.cm["oidc.config"]
#     when Keycloak is up — re-add then.
#   - No Vault-backed argocd-oidc-vault Secret (Vault deferred to 4c).
#   - No NetworkPolicy resource (Phase 5 will reintroduce as CNP).
#   - HTTPRoute uses Cilium's shared-gateway with sectionName="argocd-https"
#     (a new listener added in gateway-system.tf for this phase).
# =============================================================================

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "7.7.7"

  values = [
    yamlencode({
      configs = {
        params = {
          # Gateway terminates TLS; argocd-server speaks plain HTTP inside
          # the cluster. Avoids cert juggling on the in-pod side.
          "server.insecure" = true
        }

        cm = {
          # Canonical external URL — used for OIDC redirects (when wired in
          # Phase 4b) and for the "[Login via Keycloak]" button. Setting it
          # now so the value is stable across the OIDC enablement.
          url = "https://argocd.${var.domain}"
        }
      }

      # Phase 4a: redisSecretInit ENABLED. The Job creates the argocd-redis
      # Secret that redis-ha-haproxy mounts. The original lab disabled this
      # because Kyverno's verify-argocd-image-signatures policy blocked
      # the tag-only image (`argocd:v2.13.1`). Kyverno isn't deployed in
      # this cluster yet (Phase 7+), so the Job runs cleanly. When Phase 7
      # adds Kyverno, the options are: (1) re-disable + manually maintain
      # the Secret, (2) Kyverno PolicyException, (3) image digest pinning.
      redisSecretInit = {
        enabled = true
      }

      # Phase #74 carryover: argocd-redis-ha (3-pod Sentinel cluster +
      # 3-replica HAProxy) instead of single-pod argocd-redis. Same
      # rationale as the old lab — argocd's redis is a CACHE not a
      # system of record, so failover-without-data-loss is acceptable.
      # Anti-affinity ensures Sentinel quorum survives a single-node
      # failure (cluster spreads across us-west-2{a,b,c}).
      redis = {
        enabled = false
      }
      "redis-ha" = {
        enabled = true
        haproxy = {
          enabled          = true
          replicas         = 3
          hardAntiAffinity = true
        }
        hardAntiAffinity = true
      }

      server = {
        service = { type = "ClusterIP" }

        # Chart's Ingress disabled — traffic flows through shared-gateway.
        ingress = {
          enabled = false
        }
      }
    })
  ]

  depends_on = [
    module.eks,
    helm_release.cert_manager,
  ]
}

# =============================================================================
# HTTPRoute for argocd.${var.domain}. Attaches to shared-gateway via
# sectionName="argocd-https" (added to gateway-system.tf gateway_apps
# locals in this phase).
# =============================================================================

resource "kubectl_manifest" "argocd_httproute" {
  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "argocd-server"
      namespace = "argocd"
      labels    = { app = "argocd-server" }
    }
    spec = {
      parentRefs = [{
        name        = "shared-gateway"
        namespace   = "gateway-system"
        sectionName = "argocd-https"
      }]
      hostnames = ["argocd.${var.domain}"]
      rules = [{
        matches = [{
          path = { type = "PathPrefix", value = "/" }
        }]
        backendRefs = [{
          # argocd-server Service has port 80 (HTTP) and 443 (HTTPS) both
          # going to targetPort 8080. Port 80 here because Cilium's gateway
          # speaks plain HTTP to the backend (TLS terminates at the listener).
          name = "argocd-server"
          port = 80
        }]
      }]
    }
  })

  depends_on = [
    helm_release.argocd,
    kubectl_manifest.shared_gateway,
  ]
}
