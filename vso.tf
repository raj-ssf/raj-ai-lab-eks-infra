resource "kubernetes_namespace" "vault_secrets_operator" {
  metadata {
    name = "vault-secrets-operator"
  }
}

# VSO is HashiCorp's Vault-native counterpart to External Secrets Operator.
# Used for workloads that require a native kubernetes.io/* Secret (e.g.,
# ArgoCD's oidc.config, which resolves $<secret>:<key> refs against k8s
# Secrets and has no file/env fallback). Agent Injector stays for pods
# that CAN read files (rag-service, Grafana).
resource "helm_release" "vault_secrets_operator" {
  name       = "vault-secrets-operator"
  namespace  = kubernetes_namespace.vault_secrets_operator.metadata[0].name
  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault-secrets-operator"
  version    = "0.9.1"

  values = [
    yamlencode({
      # Default in-cluster VaultConnection used by all VaultStaticSecret /
      # VaultDynamicSecret CRs unless they override. Plain HTTP inside the
      # cluster (Vault's listener has tls_disable = true; TLS terminates at
      # ingress for external access).
      defaultVaultConnection = {
        enabled = true
        address = "http://vault.vault.svc.cluster.local:8200"
      }

      # Don't create a cluster-wide default VaultAuth — we want each consumer
      # to have its own minimally-scoped auth (SA → Vault role → policy).
      defaultAuthMethod = {
        enabled = false
      }

      controller = {
        resources = {
          requests = { cpu = "50m", memory = "128Mi" }
          limits   = { cpu = "200m", memory = "256Mi" }
        }
      }
    })
  ]

  depends_on = [
    module.eks,
    helm_release.alb_controller,
    helm_release.vault,
  ]
}
