# GitHub Actions OIDC integration for pushing images to ECR
# Reuses the account's existing token.actions.githubusercontent.com provider.

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# IAM role assumed by GitHub Actions workflows in the app repo.
# Trust policy restricts:
#   - Only this specific GitHub repo can assume
#   - Only workflow runs on the main branch
#   - Audience must be sts.amazonaws.com (GitHub's default)
resource "aws_iam_role" "gha_rag_service" {
  name        = "${var.cluster_name}-gha-rag-service"
  description = "Assumed by <your-github-owner>/<your-app-repo> GitHub Actions to push rag-service images to ECR"

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

# ECR push policy scoped to the rag-service repository only.
resource "aws_iam_policy" "gha_rag_service_ecr" {
  name        = "${var.cluster_name}-gha-rag-service-ecr"
  description = "ECR push permissions for rag-service repo"

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
        Sid    = "PushToRagServiceRepo"
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
        Resource = aws_ecr_repository.rag_service.arn
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "gha_rag_service_ecr" {
  role       = aws_iam_role.gha_rag_service.name
  policy_arn = aws_iam_policy.gha_rag_service_ecr.arn
}

output "gha_rag_service_role_arn" {
  value       = aws_iam_role.gha_rag_service.arn
  description = "Paste into the GitHub Actions workflow's role-to-assume field"
}

# =============================================================================
# Per-service IAM role for langgraph-service GHA pushes.
#
# Mirrors the gha_rag_service shape — separate role + policy + policy
# attachment, scoped to the langgraph-service ECR repo only. The
# trust policy restricts assumption to workflows in the same
# <gha_repo_owner>/<gha_repo_name> on the main branch (same
# constraint as rag-service); for tighter scoping we'd add a
# job_workflow_ref condition restricting to this specific workflow
# file, but that's a follow-up hardening.
#
# Why per-service rather than one shared role: each workload gets
# its own IAM identity, so a compromise of one service's GHA
# secrets/permissions doesn't grant push access to other services'
# repos. Standard "least-privilege per workload" pattern.
# =============================================================================

