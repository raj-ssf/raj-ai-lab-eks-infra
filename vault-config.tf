# Vault declarative config (policies, auth roles, seed secrets).
#
# Bring-up order on a fresh cluster:
#   1. terraform apply -target=helm_release.vault \
#                       -target=aws_eks_pod_identity_association.vault
#   2. kubectl -n vault exec -it vault-0 -- vault operator init \
#        -recovery-shares=5 -recovery-threshold=3
#      -> save root + recovery keys to 1Password
#   3. ./vault-approle-bootstrap.sh  (uses root token to create the AppRole
#      for terraform; prints role_id + secret_id)
#   4. export TF_VAR_vault_terraform_role_id=...
#      export TF_VAR_vault_terraform_secret_id=...
#   5. terraform apply  (applies this file + everything else)

# =============================================================================
# Pilot: rag-service consumes a demo secret via Vault Agent Injector sidecar
# =============================================================================

resource "vault_policy" "rag_service" {
  name = "rag-service"

  policy = <<-EOT
    # Read-only on secrets under secret/rag-service/*
    path "secret/data/rag-service/*" {
      capabilities = ["read"]
    }
    path "secret/metadata/rag-service/*" {
      capabilities = ["read", "list"]
    }
  EOT
}

resource "vault_kubernetes_auth_backend_role" "rag_service" {
  backend                          = "kubernetes"
  role_name                        = "rag-service"
  bound_service_account_names      = ["rag-service"]
  bound_service_account_namespaces = ["rag"]
  token_ttl                        = 3600
  token_max_ttl                    = 86400
  token_policies                   = [vault_policy.rag_service.name]
}

# Demo secret so we can prove sidecar injection works end-to-end. Gets
# rendered into /vault/secrets/demo inside the rag-service container when
# the pod is annotated with the vault.hashicorp.com/agent-inject-* keys.
resource "vault_kv_secret_v2" "rag_service_demo" {
  mount = "secret"
  name  = "rag-service/demo"

  data_json = jsonencode({
    hello         = "from vault"
    rotation_note = "this value comes from Vault via agent injector sidecar"
  })
}
