# VSO wiring for Keycloak DB password. Single k8s Secret consumed by both
# the Keycloak pod (externalDatabase.existingSecret) and the Postgres
# StatefulSet (auth.existingSecret) — see keycloak.tf for the chart refs.

resource "kubernetes_service_account_v1" "keycloak_vso" {
  metadata {
    name      = "keycloak-vso"
    namespace = kubernetes_namespace.keycloak.metadata[0].name
  }
}

resource "kubectl_manifest" "keycloak_vault_auth" {
  yaml_body = yamlencode({
    apiVersion = "secrets.hashicorp.com/v1beta1"
    kind       = "VaultAuth"
    metadata = {
      name      = "keycloak-vault-auth"
      namespace = kubernetes_namespace.keycloak.metadata[0].name
    }
    spec = {
      method = "kubernetes"
      mount  = "kubernetes"
      kubernetes = {
        role           = "keycloak-db"
        serviceAccount = kubernetes_service_account_v1.keycloak_vso.metadata[0].name
      }
    }
  })

  depends_on = [
    helm_release.vault_secrets_operator,
    vault_kubernetes_auth_backend_role.keycloak_db,
  ]
}

resource "kubectl_manifest" "keycloak_db_vault_secret" {
  yaml_body = yamlencode({
    apiVersion = "secrets.hashicorp.com/v1beta1"
    kind       = "VaultStaticSecret"
    metadata = {
      name      = "keycloak-db"
      namespace = kubernetes_namespace.keycloak.metadata[0].name
    }
    spec = {
      vaultAuthRef = "keycloak-vault-auth"
      mount        = "secret"
      type         = "kv-v2"
      path         = "keycloak/db"
      destination = {
        name   = "keycloak-db-auth"
        create = true
      }
      refreshAfter = "60s"
    }
  })

  depends_on = [
    kubectl_manifest.keycloak_vault_auth,
    vault_kv_secret_v2.keycloak_db,
  ]
}

resource "kubectl_manifest" "keycloak_admin_vault_secret" {
  yaml_body = yamlencode({
    apiVersion = "secrets.hashicorp.com/v1beta1"
    kind       = "VaultStaticSecret"
    metadata = {
      name      = "keycloak-admin"
      namespace = kubernetes_namespace.keycloak.metadata[0].name
    }
    spec = {
      vaultAuthRef = "keycloak-vault-auth"
      mount        = "secret"
      type         = "kv-v2"
      path         = "keycloak/admin"
      destination = {
        name   = "keycloak-admin-auth"
        create = true
      }
      refreshAfter = "60s"
    }
  })

  depends_on = [
    kubectl_manifest.keycloak_vault_auth,
    vault_kv_secret_v2.keycloak_admin,
  ]
}
