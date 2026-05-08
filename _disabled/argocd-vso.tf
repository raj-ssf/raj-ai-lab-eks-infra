# VSO wiring for ArgoCD. Three pieces:
#
#   1. A ServiceAccount the VSO controller impersonates when talking to Vault.
#      Bound to Vault's `argocd` kubernetes auth role (see vault-config.tf).
#   2. A VaultAuth CR in the argocd namespace telling VSO which SA / role /
#      auth mount to use.
#   3. A VaultStaticSecret CR that pulls secret/argocd/oidc → renders into the
#      k8s Secret `argocd-oidc-vault`, which argocd-cm references.

resource "kubernetes_service_account_v1" "argocd_vso" {
  metadata {
    name      = "argocd-vso"
    namespace = kubernetes_namespace.argocd.metadata[0].name
  }
}

resource "kubectl_manifest" "argocd_vault_auth" {
  yaml_body = yamlencode({
    apiVersion = "secrets.hashicorp.com/v1beta1"
    kind       = "VaultAuth"
    metadata = {
      name      = "argocd-vault-auth"
      namespace = kubernetes_namespace.argocd.metadata[0].name
    }
    spec = {
      method = "kubernetes"
      mount  = "kubernetes"
      kubernetes = {
        role           = "argocd"
        serviceAccount = kubernetes_service_account_v1.argocd_vso.metadata[0].name
      }
    }
  })

  depends_on = [
    helm_release.vault_secrets_operator,
    vault_kubernetes_auth_backend_role.argocd,
  ]
}

resource "kubectl_manifest" "argocd_oidc_vault_secret" {
  yaml_body = yamlencode({
    apiVersion = "secrets.hashicorp.com/v1beta1"
    kind       = "VaultStaticSecret"
    metadata = {
      name      = "argocd-oidc"
      namespace = kubernetes_namespace.argocd.metadata[0].name
    }
    spec = {
      vaultAuthRef = "argocd-vault-auth"
      mount        = "secret"
      type         = "kv-v2"
      path         = "argocd/oidc"
      destination = {
        name   = "argocd-oidc-vault"
        create = true
        # ArgoCD's $<secret>:<key> substitution only resolves against
        # Secrets labeled app.kubernetes.io/part-of=argocd. Without this
        # label, the reference quietly resolves to empty string → Keycloak
        # rejects with "unauthorized_client / Invalid client credentials".
        labels = {
          "app.kubernetes.io/part-of" = "argocd"
        }
      }
      # Re-sync interval. Vault → VSO → k8s Secret update every 60s; pod
      # still needs to reload argocd-server to pick up config changes (argocd
      # polls argocd-cm on its own cadence).
      refreshAfter = "60s"
    }
  })

  depends_on = [
    kubectl_manifest.argocd_vault_auth,
    vault_kv_secret_v2.argocd_oidc,
  ]
}
