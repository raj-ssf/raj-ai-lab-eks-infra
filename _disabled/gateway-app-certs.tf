# Standalone cert-manager Certificate resources for the 5 apps-repo
# applications whose previously-Ingress-owned Certificates were pruned
# by ArgoCD after the Phase 13 ownerReference patch.
#
# Recovery context (incident 2026-04-28):
#   - Phase 13 patched ownerReferences off all 12 cert-manager
#     Certificates to break the cascade-delete chain that would fire
#     when their parent Ingresses were eventually removed in Phase 12.
#   - The 5 apps-repo apps' Certificates carried argocd.argoproj.io/
#     instance labels (inherited from their parent Ingress via
#     cert-manager's ingress-shim). With ownerReferences removed,
#     ArgoCD's prune logic saw labeled-as-owned resources that
#     weren't in the kustomize source → pruned them.
#   - The TLS Secrets survived (cert-manager's Secret-side
#     ownerReference doesn't block deletion), so production TLS
#     traffic continued working through the existing valid certs.
#   - However, with no Certificate resource, cert-manager stopped
#     scheduling renewals. Without intervention, certs would expire
#     in ~3 months (Jul 20-24, 2026) and TLS would break.
#
# Recovery (this file):
#   - Recreate each pruned Certificate as a kubectl_manifest in this
#     TF file. NO argocd.argoproj.io/instance label, so ArgoCD ignores
#     them. Names + secretName + dnsNames match the originals so
#     cert-manager adopts the existing Secret rather than issuing new
#     certs (no LE rate-limit hit).
#   - The 7 Helm-managed apps' Certificates also lost ownerReferences
#     but survived the prune (Helm-managed Ingresses aren't tracked by
#     ArgoCD's per-app prune). They continue to be ingress-shim-managed
#     until Phase 12 removes the Ingresses; at that point we'd need a
#     similar recovery here for those certs (but with the chart's
#     ingress.enabled=false applied gracefully without ArgoCD's
#     interaction, the Helm-managed Certs should also persist since
#     Helm doesn't aggressively prune like ArgoCD).
#
# Why a single file: 5 small, related resources for a one-time recovery.
# Easier to find later than spreading across per-app TF files.

locals {
  recovered_certs = {
    rag-service = {
      name      = "rag-tls"
      namespace = "rag"
      dns_names = ["rag.ekstest.com"]
    }
    langgraph-service = {
      name      = "langgraph-service-tls"
      namespace = "langgraph"
      dns_names = ["langgraph.ekstest.com"]
    }
    chat-ui = {
      name      = "chat-ui-tls"
      namespace = "chat"
      dns_names = ["chat.ekstest.com"]
    }
    vllm = {
      name      = "vllm-tls"
      namespace = "llm"
      dns_names = ["llm.ekstest.com"]
    }
    hello = {
      name      = "hello-tls-prod"
      namespace = "default"
      dns_names = ["hello.ekstest.com", "hello2.ekstest.com"]
    }
  }
}

resource "kubectl_manifest" "recovered_certificate" {
  for_each = local.recovered_certs

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = each.value.name
      namespace = each.value.namespace
      # Deliberately NO argocd.argoproj.io/instance label — keeps
      # ArgoCD blind to these resources so its prune logic can't
      # reach them. cert-manager + the Gateway listener still
      # reference them by name.
    }
    spec = {
      # Same Secret name as before. cert-manager will adopt the
      # existing Secret on first reconcile (data already matches
      # the desired dnsNames + issuer).
      secretName = each.value.name
      dnsNames   = each.value.dns_names
      issuerRef = {
        group = "cert-manager.io"
        kind  = "ClusterIssuer"
        # letsencrypt-prod uses Route53 DNS-01 (cert-manager has
        # Pod Identity for Route53). DNS-01 means renewals don't
        # depend on any Ingress/HTTPRoute being reachable.
        name = "letsencrypt-prod"
      }
      usages = [
        "digital signature",
        "key encipherment",
      ]
      # cert-manager defaults: 90d duration, renew at 30d remaining.
      # Explicit for clarity.
      duration    = "2160h"  # 90d
      renewBefore = "720h"   # 30d
    }
  })

  depends_on = [
    helm_release.cert_manager,
  ]
}
