# Workload-scoped STRICT mTLS + AuthorizationPolicy on internal data tiers.
#
# Companion to the qdrant STRICT+AuthZ in istio.tf, and the cluster-wide
# deny-all in istio-zero-trust.tf. The data-tier policies here are the
# tightest layer — narrower than the ns-wide allows in the zero-trust
# layer above them. Specifically:
#
#   keycloak-postgres → only the keycloak SA can reach it (not other
#                       workloads in the keycloak ns)
#   argocd-redis      → only the three argocd controller SAs can reach
#                       it (not the argocd-server itself, dex, etc.)
#
# Layered policy semantics: Istio evaluates DENY policies first, then
# ALLOW. The cluster-wide deny-all in istio-system blocks everything
# by default. Each layer of ALLOW policies opens specific paths:
#
#   ns-wide allow      (in istio-zero-trust.tf) opens broad paths like
#                      "ingress-nginx → anything in this ns" and
#                      "anything in this ns → anything in this ns"
#
#   workload-tight     (this file + qdrant in istio.tf) layers on top —
#                      since multiple ALLOW rules are additive and any
#                      matching one lets traffic through, the tighter
#                      rules here are not strictly required for traffic
#                      to flow. They're kept for the demonstrably-tighter
#                      narrative ("qdrant only accepts rag-service, not
#                      every pod in the rag namespace") and so a future
#                      ns-wide policy revision doesn't accidentally
#                      widen the data-tier surface.

# =============================================================================
# keycloak-postgres — internal DB tier, STRICT + AuthZ to keycloak SA
# =============================================================================

resource "kubectl_manifest" "keycloak_postgres_peer_auth_strict" {
  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1beta1"
    kind       = "PeerAuthentication"
    metadata = {
      name      = "keycloak-postgres-strict"
      namespace = "keycloak"
    }
    spec = {
      # Workload selector — pin by name+instance. name alone (postgresql)
      # would be ambiguous if another postgres ever landed in the ns.
      selector = {
        matchLabels = {
          "app.kubernetes.io/name"     = "postgresql"
          "app.kubernetes.io/instance" = "keycloak-postgres"
        }
      }
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

resource "kubectl_manifest" "keycloak_postgres_authz_allow_keycloak" {
  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"
    metadata = {
      name      = "allow-keycloak-only"
      namespace = "keycloak"
    }
    spec = {
      selector = {
        matchLabels = {
          "app.kubernetes.io/name"     = "postgresql"
          "app.kubernetes.io/instance" = "keycloak-postgres"
        }
      }
      action = "ALLOW"
      rules = [
        {
          from = [{
            source = {
              # Only the Keycloak workload's SA can reach postgres. Not the
              # keycloak-vso ServiceAccount (that's for Vault Secrets Operator
              # which doesn't talk to postgres). Not the default SA.
              principals = ["cluster.local/ns/keycloak/sa/keycloak"]
            }
          }]
        },
      ]
    }
  })

  depends_on = [
    helm_release.istiod,
    kubectl_manifest.keycloak_postgres_peer_auth_strict,
  ]
}

# =============================================================================
# argocd-redis — internal cache tier. Three controllers cache state here.
# =============================================================================

resource "kubectl_manifest" "argocd_redis_peer_auth_strict" {
  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1beta1"
    kind       = "PeerAuthentication"
    metadata = {
      name      = "argocd-redis-strict"
      namespace = "argocd"
    }
    spec = {
      selector = {
        matchLabels = {
          "app.kubernetes.io/name"     = "argocd-redis"
          "app.kubernetes.io/instance" = "argocd"
        }
      }
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

resource "kubectl_manifest" "argocd_redis_authz_allow_argocd_controllers" {
  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"
    metadata = {
      name      = "allow-argocd-controllers-only"
      namespace = "argocd"
    }
    spec = {
      selector = {
        matchLabels = {
          "app.kubernetes.io/name"     = "argocd-redis"
          "app.kubernetes.io/instance" = "argocd"
        }
      }
      action = "ALLOW"
      rules = [
        {
          from = [{
            source = {
              # The three ArgoCD controllers that read/write the redis cache:
              #   argocd-server               — session + API cache
              #   argocd-application-controller — app state + reconcile cache
              #   argocd-repo-server          — git repo + manifest cache
              # Notably absent: dex-server, notifications-controller,
              # applicationset-controller, argocd-vso, default SA — none of
              # them touch redis.
              principals = [
                "cluster.local/ns/argocd/sa/argocd-server",
                "cluster.local/ns/argocd/sa/argocd-application-controller",
                "cluster.local/ns/argocd/sa/argocd-repo-server",
              ]
            }
          }]
        },
      ]
    }
  })

  depends_on = [
    helm_release.istiod,
    kubectl_manifest.argocd_redis_peer_auth_strict,
  ]
}
