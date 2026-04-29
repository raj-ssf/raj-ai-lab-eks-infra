# cluster-config ConfigMap — domain + realm fan-out for app deployments.
#
# Phase 2 of the portability refactor. App deployments (chat-ui,
# rag-service, langgraph-service, ingestion-service) historically had
# hardcoded `https://keycloak.ekstest.com/realms/raj-ai-lab-eks` and
# similar literals in their env: blocks. Each fork to a new account /
# domain required hand-editing those YAML files.
#
# This file creates a per-namespace `cluster-config` ConfigMap
# carrying the two values that were duplicated into the manifests:
#   - domain          : "ekstest.com" (or whatever var.domain resolves to)
#   - keycloak_realm  : the realm name = cluster_name in this lab
#
# Each consuming Deployment then references these via:
#   env:
#     - name: DOMAIN
#       valueFrom:
#         configMapKeyRef: { name: cluster-config, key: domain }
#     - name: KEYCLOAK_REALM
#       valueFrom:
#         configMapKeyRef: { name: cluster-config, key: keycloak_realm }
#     - name: KEYCLOAK_ISSUER
#       value: "https://keycloak.$(DOMAIN)/realms/$(KEYCLOAK_REALM)"
#
# K8s expands $(VAR) at container start AFTER all env entries are
# resolved, so the helper envs (DOMAIN, KEYCLOAK_REALM) substitute
# into the composite ones (KEYCLOAK_ISSUER, LANGFUSE_HOST, etc.) at
# runtime. No image rebuild needed when domain changes — restart
# the pod and the new value flows through.
#
# Why per-namespace, not one shared CM:
#   ConfigMaps are namespace-scoped resources; there's no built-in
#   cross-namespace reference. Fan-out via for_each is the standard
#   pattern. Each app's namespace gets its own copy of the same data.
#
# Why a separate ConfigMap (not just env values in TF helm releases):
#   App deployments aren't installed via Helm in this lab — they're
#   GitOps-managed by ArgoCD pointing at raj-ai-lab-eks/<app>/. So
#   TF can't just pass values into a chart's env: block. The CM is
#   the bridge between TF (which knows var.domain) and ArgoCD-managed
#   manifests (which need the value at runtime).

locals {
  # Namespaces that have a Deployment referencing one of:
  #   - keycloak.<domain>  (OIDC issuer / OAuth base URL)
  #   - langfuse.<domain>  (trace UI deep-links)
  #   - chat.<domain>      (Chainlit's public URL)
  #
  # Add a namespace here when a new service starts depending on a
  # public hostname; remove when no longer needed.
  cluster_config_namespaces = toset([
    "chat",       # chat-ui: LANGFUSE_HOST, OAUTH_KEYCLOAK_BASE_URL, CHAINLIT_URL
    "rag",        # rag-service: KEYCLOAK_ISSUER
    "langgraph",  # langgraph-service: KEYCLOAK_ISSUER
    "ingestion",  # ingestion-service: KEYCLOAK_ISSUER
  ])
}

resource "kubernetes_config_map" "cluster_config" {
  for_each = local.cluster_config_namespaces

  metadata {
    name      = "cluster-config"
    namespace = each.key
    labels = {
      "app.kubernetes.io/name"      = "cluster-config"
      "app.kubernetes.io/component" = "platform-config"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  data = {
    # The apex domain users access the lab through. Drives every
    # `<sub>.<domain>` URL referenced in app env vars.
    domain = var.domain
    # The Keycloak realm name. Equal to var.cluster_name in this lab
    # (see keycloak-realm.tf) — keeping it as a separate CM key so
    # services never need to know about the realm-name = cluster-name
    # convention.
    keycloak_realm = var.cluster_name
  }
}
