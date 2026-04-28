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
          # NGINX terminates TLS; let argocd-server speak plain HTTP inside
          # the cluster.
          "server.insecure" = true
        }

        cm = {
          # Canonical external URL. Required for OIDC: the issuer must be
          # able to redirect back to this host after login.
          url = "https://argocd.${var.domain}"

          # OIDC configuration. clientSecret is resolved from a k8s Secret
          # named argocd-oidc-vault (managed by VSO — see argocd-vso.tf).
          # ArgoCD's $<secret>:<key> syntax reads from any named Secret;
          # we use that instead of the default argocd-secret so Vault can
          # own the value without fighting the chart for that Secret.
          "oidc.config" = yamlencode({
            name         = "Keycloak"
            issuer       = "https://keycloak.${var.domain}/realms/${var.cluster_name}"
            clientID     = "argocd"
            clientSecret = "$argocd-oidc-vault:client_secret"
            requestedScopes = ["openid", "profile", "email"]
            requestedIDTokenClaims = {
              groups = { essential = true }
            }
          })
        }

        # Map Keycloak groups to ArgoCD built-in roles. g, <group>, role:X.
        rbac = {
          "policy.default" = "role:readonly"
          "policy.csv"     = <<-EOT
            g, argocd-admins,  role:admin
            g, argocd-viewers, role:readonly
          EOT
          scopes = "[groups]"
        }

        # OIDC client secret is delivered via VSO → argocd-oidc-vault Secret;
        # no longer merged into the chart-managed argocd-secret.
      }

      # Disable the redis-secret-init Helm pre-upgrade Job. The chart
      # creates this Job on every install/upgrade to populate the
      # argocd-redis Secret; that Secret was created on initial
      # install (2026-04-20) and persists unchanged. The Job's image
      # is tag-only (quay.io/argoproj/argocd:v2.13.1) which the lab's
      # verify-argocd-image-signatures Kyverno policy blocks at admission
      # because cosign verification requires a digest. Skipping the Job
      # avoids the Kyverno collision; the existing Secret keeps working.
      #
      # If we ever NEED to rotate the Redis password, options are:
      #   1. Re-enable temporarily, accept the Kyverno block, manually
      #      apply the Secret, then re-disable; OR
      #   2. Add a Kyverno PolicyException for this specific Job; OR
      #   3. Pin the Job image to digest format in helm values.
      redisSecretInit = {
        enabled = false
      }

      server = {
        service = { type = "ClusterIP" }

        # Phase 12 of Gateway API migration: chart's Ingress disabled.
        # Traffic now flows through shared-gateway in gateway-system ns.
        ingress = {
          enabled = false
        }
      }
    })
  ]

  depends_on = [
    module.eks,
    helm_release.alb_controller,
    helm_release.cert_manager,
  ]
}

# =============================================================================
# Phase 9 of Gateway API migration: HTTPRoute for argocd.ekstest.com.
#
# argocd-server serves both REST (HTTP) + gRPC (SPDY/HTTP-2) + WebSockets
# on /api/v1/stream/... (live application status streams). All speak HTTP/1.1
# or HTTP/2 over TLS — Envoy routes them all transparently from a single
# HTTPRoute, no per-protocol config needed.
#
# The legacy Ingress had:
#   - backend-protocol: HTTP        — Envoy doesn't need (default)
#   - proxy-read/send-timeout: 1800 — Envoy default 1h covers WS streams
#   - upstream-vhost rewrite        — Envoy doesn't need (mesh-native)
# All three NGINX-isms drop away.
#
# argocd-server has TWO Service ports: http(80) + https(443), both
# targetPort 8080. The HTTPRoute uses port 80 (matches the Ingress'
# choice; Envoy speaks plain HTTP to the backend, terminates TLS at
# the listener).
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
          name = "argocd-server"
          port = 80
        }]
      }]
    }
  })

  depends_on = [
    helm_release.argocd,
  ]
}
