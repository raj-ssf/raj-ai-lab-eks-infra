#!/usr/bin/env bash
# One-time Vault AppRole bootstrap for the terraform provider.
#
# Usage:
#   export VAULT_ADDR=https://vault.ekstest.com
#   export VAULT_TOKEN=<root-token-from-`vault operator init`>
#   ./vault-approle-bootstrap.sh
#
# Run after `vault operator init` on a fresh Vault. Idempotent — re-running
# only rotates the secret_id. Prints role_id (safe to commit or tfvars) and
# secret_id (sensitive — put in tfvars or export as TF_VAR_*).

set -euo pipefail

: "${VAULT_ADDR:?VAULT_ADDR must be set}"
: "${VAULT_TOKEN:?VAULT_TOKEN (root token) must be set}"

# Enable approle auth if not already enabled
vault auth list -format=json | jq -e '."approle/"' >/dev/null 2>&1 \
  || vault auth enable approle

# Policy granting terraform what it needs to manage Vault config. Intentionally
# broad — this token IS the Vault admin for automation purposes. Tighten by
# enumerating specific paths if you want a smaller blast radius.
vault policy write terraform-admin - <<'EOP'
# System: manage policies, auth methods, secret engines
path "sys/policies/acl/*"           { capabilities = ["create","read","update","delete","list"] }
path "sys/auth"                     { capabilities = ["read","list"] }
path "sys/auth/*"                   { capabilities = ["create","read","update","delete","sudo"] }
path "sys/mounts"                   { capabilities = ["read","list"] }
path "sys/mounts/*"                 { capabilities = ["create","read","update","delete","sudo"] }

# Kubernetes auth: manage roles
path "auth/kubernetes/role"         { capabilities = ["list"] }
path "auth/kubernetes/role/*"       { capabilities = ["create","read","update","delete","list"] }

# AppRole: let terraform rotate its own / create new approles if needed later
path "auth/approle/role"            { capabilities = ["list"] }
path "auth/approle/role/*"          { capabilities = ["create","read","update","delete","list"] }

# KV v2: full CRUD on all secrets
path "secret/data/*"                { capabilities = ["create","read","update","delete","list"] }
path "secret/metadata/*"            { capabilities = ["create","read","update","delete","list"] }
path "secret/delete/*"              { capabilities = ["update"] }
path "secret/destroy/*"             { capabilities = ["update"] }

# Read ACL capabilities for self-diagnosis
path "sys/capabilities-self"        { capabilities = ["update"] }
EOP

# Role: wraps terraform-admin policy, 4h max TTL (terraform apply lifetime)
vault write -f auth/approle/role/terraform \
  token_policies=terraform-admin \
  token_ttl=1h \
  token_max_ttl=4h \
  secret_id_ttl=720h \
  secret_id_num_uses=0

ROLE_ID=$(vault read -field=role_id auth/approle/role/terraform/role-id)
SECRET_ID=$(vault write -f -field=secret_id auth/approle/role/terraform/secret-id)

cat <<EOF

=== Bootstrap complete ===

Export these before running terraform:

  export TF_VAR_vault_terraform_role_id='$ROLE_ID'
  export TF_VAR_vault_terraform_secret_id='$SECRET_ID'

role_id is not secret — safe to stash in tfvars.
secret_id is sensitive — save to 1Password, or regenerate it next session via:

  vault write -f -field=secret_id auth/approle/role/terraform/secret-id

secret_id TTL: 720h (30d). Re-run this script to rotate.

EOF
