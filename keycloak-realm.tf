resource "random_password" "keycloak_grafana_client_secret" {
  length  = 32
  special = false
}

resource "random_password" "keycloak_argocd_client_secret" {
  length  = 32
  special = false
}

resource "random_password" "keycloak_demo_user_password" {
  length  = 20
  special = false
}

# Declarative realm definition. Imported on first Keycloak boot via
# --import-realm; re-imports are skipped by default, so edits made in the
# admin UI survive. To force a rewrite, bump a no-op field (e.g. displayName)
# and set KC_SPI_IMPORT_SINGLE_FILE_STRATEGY=OVERWRITE_EXISTING on the pod.
locals {
  keycloak_realm_json = jsonencode({
    realm                 = "raj-ai-lab-eks"
    displayName           = "Raj AI Lab (EKS)"
    enabled               = true
    registrationAllowed   = false
    resetPasswordAllowed  = true
    loginWithEmailAllowed = true

    roles = {
      realm = [
        { name = "admin",  description = "Full admin across wired apps" },
        { name = "viewer", description = "Read-only access across wired apps" },
      ]
    }

    groups = [
      { name = "argocd-admins",  path = "/argocd-admins" },
      { name = "argocd-viewers", path = "/argocd-viewers" },
    ]

    users = [
      {
        username      = "raj"
        email         = "raj@example.com"
        firstName     = "Raj"
        lastName      = "Sasidharan"
        emailVerified = true
        enabled       = true
        credentials = [{
          type      = "password"
          value     = random_password.keycloak_demo_user_password.result
          temporary = false
        }]
        realmRoles = ["admin"]
        groups     = ["/argocd-admins"]
      },
    ]

    clients = [
      # --- Grafana OIDC client -----------------------------------------------
      {
        clientId                  = "grafana"
        name                      = "Grafana"
        enabled                   = true
        protocol                  = "openid-connect"
        clientAuthenticatorType   = "client-secret"
        secret                    = random_password.keycloak_grafana_client_secret.result
        publicClient              = false
        standardFlowEnabled       = true
        directAccessGrantsEnabled = false
        serviceAccountsEnabled    = false
        rootUrl                   = "https://grafana.${var.domain}"
        baseUrl                   = "https://grafana.${var.domain}"
        redirectUris              = ["https://grafana.${var.domain}/login/generic_oauth"]
        webOrigins                = ["https://grafana.${var.domain}"]
        attributes = {
          "post.logout.redirect.uris" = "https://grafana.${var.domain}/*"
        }
        # Emit realm roles in the `roles` claim so Grafana's role_attribute_path
        # can map to admin/editor/viewer.
        protocolMappers = [{
          name            = "realm-roles"
          protocol        = "openid-connect"
          protocolMapper  = "oidc-usermodel-realm-role-mapper"
          consentRequired = false
          config = {
            "claim.name"           = "roles"
            "jsonType.label"       = "String"
            "multivalued"          = "true"
            "id.token.claim"       = "true"
            "access.token.claim"   = "true"
            "userinfo.token.claim" = "true"
          }
        }]
      },

      # --- ArgoCD OIDC client ------------------------------------------------
      {
        clientId                  = "argocd"
        name                      = "ArgoCD"
        enabled                   = true
        protocol                  = "openid-connect"
        clientAuthenticatorType   = "client-secret"
        secret                    = random_password.keycloak_argocd_client_secret.result
        publicClient              = false
        standardFlowEnabled       = true
        directAccessGrantsEnabled = false
        serviceAccountsEnabled    = false
        rootUrl                   = "https://argocd.${var.domain}"
        baseUrl                   = "https://argocd.${var.domain}"
        redirectUris              = ["https://argocd.${var.domain}/auth/callback"]
        webOrigins                = ["https://argocd.${var.domain}"]
        # ArgoCD keys RBAC off group membership, so emit `groups` in tokens.
        protocolMappers = [{
          name            = "groups"
          protocol        = "openid-connect"
          protocolMapper  = "oidc-group-membership-mapper"
          consentRequired = false
          config = {
            "claim.name"           = "groups"
            "full.path"            = "false"
            "id.token.claim"       = "true"
            "access.token.claim"   = "true"
            "userinfo.token.claim" = "true"
          }
        }]
      },
    ]
  })
}

resource "kubernetes_config_map_v1" "keycloak_realm_import" {
  metadata {
    name      = "keycloak-realm-import"
    namespace = kubernetes_namespace.keycloak.metadata[0].name
  }
  data = {
    "raj-ai-lab-eks-realm.json" = local.keycloak_realm_json
  }
}

# --- Outputs (sensitive). Retrieve with: terraform output -raw <name> ---------
output "keycloak_grafana_client_secret" {
  value     = random_password.keycloak_grafana_client_secret.result
  sensitive = true
}

output "keycloak_argocd_client_secret" {
  value     = random_password.keycloak_argocd_client_secret.result
  sensitive = true
}

output "keycloak_demo_user_password" {
  value     = random_password.keycloak_demo_user_password.result
  sensitive = true
}
