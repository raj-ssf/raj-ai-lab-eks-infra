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

      server = {
        service = { type = "ClusterIP" }

        ingress = {
          enabled          = true
          ingressClassName = "nginx"
          hostname         = "argocd.${var.domain}"
          annotations = {
            "cert-manager.io/cluster-issuer"                   = "letsencrypt-prod"
            "nginx.ingress.kubernetes.io/backend-protocol"     = "HTTP"
            # argocd-server serves WebSockets on /api/v1/stream/...; bump
            # proxy timeouts so long-lived streams don't get cut off.
            "nginx.ingress.kubernetes.io/proxy-read-timeout"   = "1800"
            "nginx.ingress.kubernetes.io/proxy-send-timeout"   = "1800"
          }
          tls = true
          extraTls = [{
            hosts      = ["argocd.${var.domain}"]
            secretName = "argocd-tls"
          }]
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
