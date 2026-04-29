# =============================================================================
# chat-ui — Chainlit-based web UI fronting langgraph-service.
#
# Single-purpose UI for the AI lab portfolio demo. Renders each LangGraph
# state-machine node (classify / ensure_warm / execute) as a Chainlit
# `cl.Step` so the routing decision is visible live, with a JSON sidebar
# showing the full /invoke response shape and a deep-link to the matching
# Langfuse trace.
#
# Auth: Chainlit's built-in @cl.oauth_callback talks Authorization Code
# + PKCE to Keycloak (CONFIDENTIAL client below). User clicks "Login
# with Keycloak", gets bounced through realm login, returns with a JWT
# that's forwarded to langgraph-service /invoke as the Bearer token.
# =============================================================================

resource "kubernetes_namespace" "chat" {
  metadata {
    name = "chat"
    labels = {
      # Mesh injection: enabled. The Chainlit pod calls langgraph-service
      # in another namespace, which is mTLS-strict; sidecar gives the
      # call a SPIFFE identity that the langgraph-service AuthZ policy
      # can match on.
      "istio-injection" = "enabled"
    }
  }
}

# -----------------------------------------------------------------------------
# ECR repository for the chat-ui image (pushed by GHA, signed with cosign,
# verified by Kyverno on admission).
# -----------------------------------------------------------------------------

resource "aws_ecr_repository" "chat_ui" {
  name                 = "chat-ui"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "chat_ui" {
  repository = aws_ecr_repository.chat_ui.name

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

output "chat_ui_ecr_url" {
  value       = aws_ecr_repository.chat_ui.repository_url
  description = "Use as the CHAT_UI_ECR_REPOSITORY_URL GHA repo variable"
}

# -----------------------------------------------------------------------------
# Per-service GHA OIDC role for pushing chat-ui images to ECR.
# Mirrors gha_langgraph_service / gha_rag_service shape: separate role +
# scoped policy so a compromised chat-ui CI secret can't push other repos.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "gha_chat_ui" {
  name        = "${var.cluster_name}-gha-chat-ui"
  description = "Assumed by GHA build-push-chat-ui workflow to push images to ECR"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = data.aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
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

resource "aws_iam_policy" "gha_chat_ui_ecr" {
  name        = "${var.cluster_name}-gha-chat-ui-ecr"
  description = "ECR push permissions for chat-ui repo"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AuthToken"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "PushToChatUiRepo"
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
        Resource = aws_ecr_repository.chat_ui.arn
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "gha_chat_ui_ecr" {
  role       = aws_iam_role.gha_chat_ui.name
  policy_arn = aws_iam_policy.gha_chat_ui_ecr.arn
}

output "gha_chat_ui_role_arn" {
  value       = aws_iam_role.gha_chat_ui.arn
  description = "Set as the CHAT_UI_AWS_ROLE_ARN repo variable in GitHub Actions"
}

# -----------------------------------------------------------------------------
# Keycloak OIDC client for chat-ui.
#
# CONFIDENTIAL client (has a generated client_secret) — required for
# Authorization Code Flow with PKCE per OAuth 2.1 / OIDC best practice.
# direct_access_grants_enabled=false: no password grant; only redirect-
# based browser flow. service_accounts_enabled=false: no client_credentials.
#
# Differs from the langgraph-service client (which is PUBLIC, password-
# grant-enabled, used for curl-style testing). chat-ui is end-user-facing
# and goes through the proper auth-code flow.
# -----------------------------------------------------------------------------

resource "keycloak_openid_client" "chat_ui" {
  realm_id    = var.cluster_name
  client_id   = "chat-ui"
  name        = "Chat UI"
  enabled     = true
  access_type = "CONFIDENTIAL"

  standard_flow_enabled        = true
  direct_access_grants_enabled = false
  service_accounts_enabled     = false

  # Override the realm's default access-token lifespan (5 min) just for
  # this client. Without an override, long-running chat conversations
  # got booted at the 5-min mark — Chainlit's KeycloakOAuthProvider
  # stashes the access_token at login but doesn't auto-refresh, so
  # downstream calls (chat-ui → langgraph-service → bearer token check)
  # start returning 401 once the token expires.
  #
  # 1-hour bump buys most users a single uninterrupted session without
  # requiring app-side refresh-token code. For sessions that genuinely
  # need to outlive 1h, the proper fix is implementing the refresh-token
  # flow in the Chainlit app (POST /protocol/openid-connect/token with
  # grant_type=refresh_token) — deferred until/unless 1h proves
  # insufficient in practice.
  #
  # Other clients in the realm (langgraph-service, langfuse, etc.) are
  # unaffected — they keep the realm default. Service clients want
  # shorter tokens for tighter blast-radius on credential leaks.
  access_token_lifespan = "3600"

  # PKCE intentionally NOT required. Chainlit's KeycloakOAuthProvider
  # (chainlit/oauth_providers.py) doesn't send code_challenge /
  # code_challenge_method on the authorize request. With PKCE required
  # here, Keycloak rejects every authorize request with
  # `error=invalid_request` and the user lands at /login?error=invalid_request.
  #
  # PKCE is redundant for CONFIDENTIAL clients anyway: the threat model
  # PKCE protects against (intercepted auth code → token without a
  # secret) doesn't apply when the client authenticates to the token
  # endpoint with client_secret. Re-enable when Chainlit ships PKCE
  # support upstream.

  root_url = "https://chat.${var.domain}"
  base_url = "https://chat.${var.domain}"

  valid_redirect_uris = [
    # Chainlit's OAuth callback path. The exact path is fixed by the
    # framework: /auth/oauth/{provider}/callback. provider id is
    # "keycloak" (set in the chat-ui app via OAUTH_KEYCLOAK_* env vars).
    "https://chat.${var.domain}/auth/oauth/keycloak/callback",
  ]

  web_origins = [
    "https://chat.${var.domain}",
  ]
}

# Sync the auto-generated client_secret into a K8s Secret in the chat ns
# so the Chainlit Deployment can mount it via envFrom.
resource "kubernetes_secret" "chat_ui_oidc" {
  metadata {
    name      = "chat-ui-oidc"
    namespace = kubernetes_namespace.chat.metadata[0].name
  }

  type = "Opaque"

  data = {
    OAUTH_KEYCLOAK_CLIENT_ID     = keycloak_openid_client.chat_ui.client_id
    OAUTH_KEYCLOAK_CLIENT_SECRET = keycloak_openid_client.chat_ui.client_secret
    # CHAINLIT_AUTH_SECRET signs Chainlit's session cookies. Generated
    # once at TF apply time and rotated only on explicit `terraform
    # taint` / replace. The actual value never appears in any committed
    # file — it's stored in the TF state (which is encrypted at rest in
    # the S3 backend) and propagated via this Secret.
    CHAINLIT_AUTH_SECRET = random_password.chainlit_auth_secret.result
  }
}

resource "random_password" "chainlit_auth_secret" {
  length  = 64
  special = false
}

# -----------------------------------------------------------------------------
# Cross-namespace AuthorizationPolicy: allow chat-ui → langgraph-service.
#
# chat-ui's Chainlit handler POSTs to https://langgraph.ekstest.com/invoke
# with the user's Keycloak JWT. With cluster-wide deny-all in effect,
# langgraph namespace's AuthZ policies need to explicitly allow the
# chat-ui SA principal — same pattern as the existing rag-service rule
# on qdrant and the langgraph rule on llm.
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "allow_chat_to_langgraph" {
  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"
    metadata = {
      name      = "allow-chat-ui"
      namespace = "langgraph"
    }
    spec = {
      action = "ALLOW"
      rules = [
        {
          from = [{
            source = {
              principals = [
                "cluster.local/ns/chat/sa/chat-ui",
              ]
            }
          }]
        },
      ]
    }
  })

  depends_on = [
    helm_release.istiod,
    kubectl_manifest.deny_all_mesh_wide,
    kubernetes_namespace.chat,
  ]
}
