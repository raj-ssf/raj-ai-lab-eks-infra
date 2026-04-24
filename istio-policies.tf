# Workload-scoped STRICT mTLS + AuthorizationPolicy on internal data tiers.
#
# Companion to the qdrant STRICT+AuthZ in istio.tf. Same pattern, different
# workloads: lock down DB/cache tiers that no unmeshed client ever needs
# to reach, so STRICT is safe and the AuthZ allowlist is the only path in.
#
# Scope chosen with the NGINX-unmeshed constraint in mind:
#
#   COVERED (STRICT + AuthZ here):
#     keycloak-postgres  — only caller is keycloak pod
#     argocd-redis       — only callers are argocd-server, application-
#                          controller, repo-server
#
#   NOT COVERED (externally-reached via ingress-nginx → workload; STRICT
#   would reject the plaintext hop from unmeshed NGINX):
#     rag-service        — takes HTTPS from NGINX → rag.ekstest.com
#     keycloak pod       — takes HTTPS from NGINX → keycloak login page
#     argocd-server      — takes HTTPS from NGINX → ArgoCD UI
#
#   Adding ALLOW-style AuthZ to PERMISSIVE workloads would be worse than
#   nothing: unmeshed plaintext has no SPIFFE principal, so an ALLOW policy
#   with only principal rules would implicitly deny NGINX and break ingress.
#   Proper fix is meshing ingress-nginx itself (inject sidecar on its ns,
#   restart pods), which lets NGINX initiate mTLS to workloads. That's its
#   own milestone — deferred.
#
# Net interview narrative: four-tier segmentation today —
#   qdrant (STRICT, allow=rag-service)
#   keycloak-postgres (STRICT, allow=keycloak)
#   argocd-redis (STRICT, allow=argocd-controllers)
#   + namespace labels + Istio sidecars on 4 namespaces
# Mesh-wide STRICT is the next fold once NGINX is meshed.

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
