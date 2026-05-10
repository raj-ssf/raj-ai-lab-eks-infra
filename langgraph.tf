# langgraph-service infrastructure: namespace, ECR, Keycloak OIDC client,
# Langfuse credentials Secret, cross-namespace Istio AuthorizationPolicy
# for langgraph→llm calls.
#
# The ArgoCD Application that deploys langgraph-service lives in
# argocd-apps.tf alongside the other applications. The ServiceAccount
# + RBAC for JIT scaling Deployments in the llm namespace are managed
# by the app repo (raj-ai-lab-eks/langgraph-service/base/serviceaccount.yaml).
#
# The Istio injection label is added to this namespace by the existing
# kubernetes_labels.istio_injection resource in istio.tf — `langgraph`
# is in the istio_meshed_namespaces local set there. Per-namespace
# allow-ingress-nginx and allow-intra-namespace policies are added by
# extending the locals in istio-zero-trust.tf.

# =============================================================================
# ECR repository for langgraph-service container images.
#
# Same lifecycle policy as rag-service (keep last 10, expire older). The
# GHA workflow at raj-ai-lab-eks/.github/workflows/build-push-langgraph-service.yml
# pushes `:latest` and `:sha-<short>` on every main-branch push to
# `langgraph-service/app/**`.
# =============================================================================

resource "aws_ecr_repository" "langgraph_service" {
  name                 = "langgraph-service"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "langgraph_service" {
  repository = aws_ecr_repository.langgraph_service.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images, expire older untagged/tagged"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = {
        type = "expire"
      }
    }]
  })
}

output "langgraph_service_ecr_url" {
  value       = aws_ecr_repository.langgraph_service.repository_url
  description = "Use as the LANGGRAPH_ECR_REPOSITORY_URL GHA repo variable"
}

# =============================================================================
# Namespace.
#
# Created here (rather than letting ArgoCD CreateNamespace do it) so the
# kubernetes_labels.istio_injection resource has something stable to
# label, and so the langfuse-service-langfuse Secret below can be
# created in this ns before ArgoCD even runs its first sync.
# =============================================================================

# Namespace `langgraph` is declared in namespaces.tf (canonical, no
# istio-injection label — Cilium WireGuard handles east-west mTLS in this
# cluster, not Istio sidecars).

# =============================================================================
# Langfuse credentials Secret.
#
# Mirrors raj-ai-lab-eks-infra/langfuse-rag-creds.tf: same Secret keys
# (LANGFUSE_PUBLIC_KEY / LANGFUSE_SECRET_KEY), populated from the same
# tfvars (var.langfuse_public_key / var.langfuse_secret_key). Both
# rag-service and langgraph-service write into the same Langfuse
# project, so they reuse the same minted key pair — no need to mint
# separate credentials.
#
# Gated on both keys being non-empty so a fresh-clone apply (before
# Langfuse has been hit and keys minted in the UI) is a clean no-op.
# =============================================================================

resource "kubernetes_secret" "langgraph_service_langfuse" {
  count = (var.langfuse_public_key != "" && var.langfuse_secret_key != "") ? 1 : 0

  metadata {
    name      = "langgraph-service-langfuse"
    namespace = kubernetes_namespace.langgraph.metadata[0].name
  }

  type = "Opaque"

  data = {
    LANGFUSE_PUBLIC_KEY = var.langfuse_public_key
    LANGFUSE_SECRET_KEY = var.langfuse_secret_key
  }
}

# =============================================================================
# Keycloak OIDC client.
#
# Provider-managed, same pattern as keycloak-langfuse-client.tf. Two
# differences from the langfuse client:
#
#   1. direct_access_grants_enabled = true (password grant). Enables
#      curl-based testing — `curl -d 'grant_type=password&...' /token`
#      gives you a bearer token without a browser. Production would
#      disable this in favor of authorization-code flow, but for a
#      dev cluster + interview demo, it's the lowest-friction path.
#
#   2. No client_secret stored anywhere. langgraph-service validates
#      JWTs via the realm's JWKs endpoint (public). It doesn't act as
#      a confidential OAuth client itself — it's a resource server,
#      not a relying party. So `access_type = PUBLIC` and no secret
#      generation. Tokens come from other clients (e.g., the realm's
#      account-console flow, or this client via direct grants).
#
# The kubernetes_secret.langgraph_service_oidc resource is omitted for
# the same reason — there's no client_secret to inject into the
# langgraph-service Deployment. The KEYCLOAK_ISSUER env var in the
# Deployment manifest is the only OIDC config the service needs.
# =============================================================================

resource "keycloak_openid_client" "langgraph_service" {
  realm_id    = var.cluster_name
  client_id   = "langgraph-service"
  name        = "LangGraph Service"
  enabled     = true
  access_type = "PUBLIC"

  standard_flow_enabled        = true
  direct_access_grants_enabled = true
  service_accounts_enabled     = false

  root_url = "https://langgraph.${var.domain}"
  base_url = "https://langgraph.${var.domain}"

  valid_redirect_uris = [
    # Reserved for the future browser-flow UI; not used by the resource
    # server itself.
    "https://langgraph.${var.domain}/auth/callback",
  ]

  web_origins = [
    "https://langgraph.${var.domain}",
  ]
}

# Istio AuthorizationPolicy block (langgraph-service → llm) removed —
# Cilium-era cluster has no sidecar mesh, so AuthZ has no enforcer in the
# data path. L3/L4 equivalent will live in cilium-network-policies.tf when
# the llm namespace's vllm Deployments come back.

# =============================================================================
# Kubernetes RBAC: langgraph-service SA can read + patch Deployment scale in llm.
#
# ensure_warm() in main.py calls apps_v1.patch_namespaced_deployment_scale
# to bring a target Deployment from replicas=0 to 1 when the classifier
# routes a request that needs the heavier model. Without this Role, the
# call hits Forbidden at the kube-apiserver and surfaces in chat-ui as:
#   ❌ upstream returned 502: failed to read scale of llm/<deploy>: Forbidden
#
# The trivial-routed path doesn't need this — when the 8B is already at
# replicas=1, ensure_warm short-circuits without an API call. So this
# RBAC gap was latent until the classifier first picked 'reasoning' or
# 'hard' (which it finally did for code-generation prompts).
#
# Scope: ns-wide on apps/deployments + apps/deployments/scale, plus pod
# get/list/watch so ensure_warm can poll for "ready replica" status
# after issuing the scale patch. Bound to the langgraph-service SA only.
# =============================================================================

resource "kubernetes_role_v1" "langgraph_scale_llm" {
  metadata {
    name      = "langgraph-deployment-scaler"
    namespace = "llm"
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments/scale"]
    verbs      = ["get", "patch", "update"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding_v1" "langgraph_scale_llm" {
  metadata {
    name      = "langgraph-deployment-scaler"
    namespace = "llm"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.langgraph_scale_llm.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = "langgraph-service"
    namespace = "langgraph"
  }
}
