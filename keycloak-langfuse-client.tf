# Keycloak OIDC client for Langfuse, managed via the keycloak/keycloak TF
# provider (not the realm-import JSON).
#
# Why provider-managed, not realm-JSON-managed:
#   The realm-import at first boot is idempotent only on "create or skip" —
#   once the realm exists, subsequent imports are silently no-op (see the
#   comment at the top of keycloak-realm.tf). Adding clients via the import
#   JSON AFTER the realm is live requires a forced-overwrite import, which
#   would clobber any manual changes. The provider-managed path does a real
#   HTTP call to Keycloak's admin API on every plan/apply, so drift is
#   detected and reconciled.
#
# grafana and argocd clients remain realm-import-managed (they were present
# at first boot). Only langfuse is provider-managed. Both mechanisms coexist
# cleanly because each owns a disjoint set of clients.

provider "keycloak" {
  client_id = "admin-cli"
  username  = "admin"
  password  = var.keycloak_admin_password
  url       = "https://keycloak.${var.domain}"
  # Auth against the master realm as the Keycloak admin user. Our
  # raj-ai-lab-eks realm is the target realm for the client resource below,
  # set via resource.realm_id — not here.
  realm = "master"
  # Keycloak's admin API can be slow on first login after pod restart;
  # bump timeout beyond the default 15s so a cold-start apply doesn't time out.
  client_timeout = 60
}

resource "random_password" "keycloak_langfuse_client_secret" {
  length  = 32
  special = false
}

resource "keycloak_openid_client" "langfuse" {
  realm_id    = var.cluster_name
  client_id   = "langfuse"
  name        = "Langfuse"
  enabled     = true
  access_type = "CONFIDENTIAL"
  client_secret = random_password.keycloak_langfuse_client_secret.result

  # Standard OIDC authorization-code flow (browser redirect). Disable the
  # direct-access-grant (password grant) and service-account flows — Langfuse
  # only needs user-login redirects.
  standard_flow_enabled        = true
  direct_access_grants_enabled = false
  service_accounts_enabled     = false

  root_url = "https://langfuse.${var.domain}"
  base_url = "https://langfuse.${var.domain}"

  # Langfuse's NextAuth.js Keycloak provider posts back to this exact path.
  # If NextAuth is ever upgraded and the callback path changes, this must
  # follow. A mismatch here produces 'redirect_uri_mismatch' errors at login.
  valid_redirect_uris = [
    "https://langfuse.${var.domain}/api/auth/callback/keycloak",
  ]

  web_origins = [
    "https://langfuse.${var.domain}",
  ]
}

output "keycloak_langfuse_client_secret" {
  value       = random_password.keycloak_langfuse_client_secret.result
  sensitive   = true
  description = "Client secret for Langfuse's Keycloak OIDC client. Passed into Langfuse via Helm values."
}
