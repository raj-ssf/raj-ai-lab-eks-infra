# =============================================================================
# ingestion-service — RAG ingestion microservice.
#
# Accepts file uploads (PDF/DOCX/TXT/MD up to 25 MB), parses them with
# Unstructured, chunks via langchain's RecursiveCharacterTextSplitter
# (1000 chars / 200 overlap), embeds chunks via vllm-bge-m3, and writes
# them to Qdrant's `documents` collection. Each chunk's payload carries
# session_id (per-session tenancy) so rag-service /retrieve can filter
# at query time.
#
# Auth: PUBLIC Keycloak client (same shape as langgraph-service) —
# accepts JWTs from any realm-issued token; password grant enabled for
# curl-based testing. chat-ui forwards the user's access_token as the
# Bearer header on every /upload call.
#
# Mesh: in-cluster only (no public Ingress). chat-ui calls
# http://ingestion-service.ingestion.svc.cluster.local in-mesh.
# ingestion-service's outbound calls reach vllm-bge-m3 (llm ns) and
# qdrant (qdrant ns) — both gated by their AuthorizationPolicies, which
# this file extends to allow the ingestion-service SA principal.
# =============================================================================

resource "kubernetes_namespace" "ingestion" {
  metadata {
    name = "ingestion"
    labels = {
      "istio-injection" = "enabled"
    }
  }
}

# -----------------------------------------------------------------------------
# ECR repo + lifecycle
# -----------------------------------------------------------------------------

resource "aws_ecr_repository" "ingestion_service" {
  name                 = "ingestion-service"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "ingestion_service" {
  repository = aws_ecr_repository.ingestion_service.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images, expire older untagged/tagged"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
      action       = { type = "expire" }
    }]
  })
}

output "ingestion_service_ecr_url" {
  value       = aws_ecr_repository.ingestion_service.repository_url
  description = "Set as INGESTION_ECR_REPOSITORY_URL repo variable in GitHub Actions"
}

# -----------------------------------------------------------------------------
# GHA OIDC role for image pushes — mirrors gha_chat_ui / gha_langgraph_service
# -----------------------------------------------------------------------------

resource "aws_iam_role" "gha_ingestion_service" {
  name        = "${var.cluster_name}-gha-ingestion-service"
  description = "Assumed by GHA build-push-ingestion-service workflow to push images to ECR"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.gha_repo_owner}/${var.gha_repo_name}:ref:refs/heads/main"
        }
      }
    }]
  })
}

resource "aws_iam_policy" "gha_ingestion_service_ecr" {
  name        = "${var.cluster_name}-gha-ingestion-service-ecr"
  description = "ECR push permissions for ingestion-service repo"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "AuthToken", Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
      {
        Sid    = "PushToIngestionRepo"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
        ]
        Resource = aws_ecr_repository.ingestion_service.arn
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "gha_ingestion_service_ecr" {
  role       = aws_iam_role.gha_ingestion_service.name
  policy_arn = aws_iam_policy.gha_ingestion_service_ecr.arn
}

output "gha_ingestion_service_role_arn" {
  value       = aws_iam_role.gha_ingestion_service.arn
  description = "Set as INGESTION_AWS_ROLE_ARN repo variable in GitHub Actions"
}

# -----------------------------------------------------------------------------
# Keycloak OIDC client.
#
# PUBLIC type (no client_secret) + direct_access_grants_enabled=true for
# curl-based testing — same shape as langgraph-service. ingestion-service
# is a resource server: it validates JWTs against the realm's JWKs and
# doesn't itself initiate auth flows. Tokens come from chat-ui (which
# minted them via its own CONFIDENTIAL client during the user's
# auth-code flow) and get forwarded as the Bearer header.
# -----------------------------------------------------------------------------

resource "keycloak_openid_client" "ingestion_service" {
  realm_id    = var.cluster_name
  client_id   = "ingestion-service"
  name        = "Ingestion Service"
  enabled     = true
  access_type = "PUBLIC"

  standard_flow_enabled        = true
  direct_access_grants_enabled = true
  service_accounts_enabled     = false

  # No public ingress for ingestion-service in v1, but registering the
  # callback URL keeps the option open for direct browser-flow testing.
  root_url = "http://ingestion-service.ingestion.svc.cluster.local"

  valid_redirect_uris = [
    "http://ingestion-service.ingestion.svc.cluster.local/auth/callback",
  ]
}

# -----------------------------------------------------------------------------
# AuthorizationPolicy: chat-ui → ingestion-service (cross-namespace ALLOW).
#
# chat-ui's /upload handler POSTs to ingestion-service. With cluster-wide
# deny-all in effect, the ingestion ns needs to allowlist the chat-ui SA
# principal. Same pattern as allow-langgraph-service in the langgraph ns.
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "allow_chat_to_ingestion" {
  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"
    metadata = {
      name      = "allow-chat-ui"
      namespace = "ingestion"
    }
    spec = {
      action = "ALLOW"
      rules = [
        { from = [{ source = { principals = ["cluster.local/ns/chat/sa/chat-ui"] } }] },
      ]
    }
  })
  depends_on = [
    helm_release.istiod,
    kubectl_manifest.deny_all_mesh_wide,
    kubernetes_namespace.ingestion,
  ]
}

# -----------------------------------------------------------------------------
# AuthorizationPolicy: ingestion-service → vllm-* in llm namespace.
#
# ingestion-service calls /v1/embeddings on vllm-bge-m3 to embed chunks
# at write time. Same destination ns (llm) and same cross-ns allow shape
# as the existing langgraph-service rule. Both rules coexist in the llm
# ns under different metadata.name values.
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "allow_ingestion_to_llm" {
  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"
    metadata = {
      name      = "allow-ingestion-service"
      namespace = "llm"
    }
    spec = {
      action = "ALLOW"
      rules = [
        { from = [{ source = { principals = ["cluster.local/ns/ingestion/sa/ingestion-service"] } }] },
      ]
    }
  })
  depends_on = [
    helm_release.istiod,
    kubectl_manifest.deny_all_mesh_wide,
    kubernetes_namespace.ingestion,
  ]
}

# -----------------------------------------------------------------------------
# AuthorizationPolicy: ingestion-service → qdrant.
#
# ingestion-service writes chunks to Qdrant's `documents` collection.
# qdrant's existing allow-rag-service-only is a single-source policy;
# adding a parallel allow-ingestion-service rule lets both producers
# write to qdrant without having to rewrite the existing policy.
# Istio combines multiple ALLOW rules with OR semantics — either one
# matching is sufficient.
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "allow_ingestion_to_qdrant" {
  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"
    metadata = {
      name      = "allow-ingestion-service"
      namespace = "qdrant"
    }
    spec = {
      action = "ALLOW"
      rules = [
        { from = [{ source = { principals = ["cluster.local/ns/ingestion/sa/ingestion-service"] } }] },
      ]
    }
  })
  depends_on = [
    helm_release.istiod,
    kubectl_manifest.deny_all_mesh_wide,
    kubernetes_namespace.ingestion,
  ]
}
