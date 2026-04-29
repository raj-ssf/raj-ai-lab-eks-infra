# RAGAS regression-gate infra (apps repo's Phase #3).
#
# What this provisions:
#   - ECR repo `ragas-eval` for the RAGAS image. Sibling of `eval` (lm-
#     evaluation-harness). Separate so the two evaluation stacks version
#     independently.
#   - Extends the existing `gha_eval` IAM role (gha-oidc.tf) with:
#       * Push perms on the new ragas-eval repo (separate policy to keep
#         the diff isolated and avoid colliding with build-push-eval.yml).
#       * eks:DescribeCluster + eks:ListClusters so the workflow's
#         `aws eks update-kubeconfig` step succeeds.
#   - EKS access entry binding gha_eval to namespace-scope edit access
#     in the `llm` namespace, so the workflow's `kubectl scale` and
#     `kubectl apply -f Job` calls land. Cluster-wide admin would be
#     overkill — the only writes the workflow does are scaling
#     specific Deployments and applying a single Job manifest in `llm`.
#
# Why everything in one file:
#   The three pieces (ECR repo, IAM policy expansion, EKS access entry)
#   are tightly coupled — none of them is useful without the others. A
#   single file makes the change reviewable as one unit and keeps the
#   future "remove RAGAS" removal trivial.

# ---------------------------------------------------------------------------
# ECR repo for the ragas-eval image
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "ragas_eval" {
  name                 = "ragas-eval"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "ragas_eval" {
  repository = aws_ecr_repository.ragas_eval.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images, expire older."
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# ---------------------------------------------------------------------------
# Extend gha_eval role: push to ragas-eval repo
# ---------------------------------------------------------------------------

# Separate policy (rather than editing aws_iam_policy.gha_eval_ecr) keeps
# the diff to gha-oidc.tf at zero. The role can carry multiple policies;
# AWS evaluates them as union.
resource "aws_iam_policy" "gha_eval_ragas_ecr" {
  name        = "${var.cluster_name}-gha-eval-ragas-ecr"
  description = "ECR push permissions for ragas-eval repo (sibling to eval)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # ecr:GetAuthorizationToken is already granted in gha_eval_ecr's
        # AuthToken statement (action on Resource=*). Don't duplicate.
        Sid    = "PushToRagasEvalRepo"
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
        Resource = aws_ecr_repository.ragas_eval.arn
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "gha_eval_ragas_ecr" {
  role       = aws_iam_role.gha_eval.name
  policy_arn = aws_iam_policy.gha_eval_ragas_ecr.arn
}

# ---------------------------------------------------------------------------
# Extend gha_eval role: EKS describe (so aws eks update-kubeconfig works)
# ---------------------------------------------------------------------------

resource "aws_iam_policy" "gha_eval_eks_describe" {
  name        = "${var.cluster_name}-gha-eval-eks-describe"
  description = "EKS read perms so the RAGAS workflow can run aws eks update-kubeconfig"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EksReadForKubeconfig"
        Effect = "Allow"
        # ListClusters is on Resource="*" because it's an account-wide
        # operation by design (no per-cluster ARN to scope it to).
        # DescribeCluster narrows to the specific cluster.
        Action   = ["eks:ListClusters"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = module.eks.cluster_arn
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "gha_eval_eks_describe" {
  role       = aws_iam_role.gha_eval.name
  policy_arn = aws_iam_policy.gha_eval_eks_describe.arn
}

# ---------------------------------------------------------------------------
# EKS access entry: gha_eval → namespace-scope edit on `llm`
# ---------------------------------------------------------------------------
#
# Cluster authentication is API_AND_CONFIG_MAP (see eks.tf). We use the
# new aws_eks_access_entry resource here rather than adding to the eks
# module's access_entries map because (a) keeps the change self-contained
# in this file and (b) avoids touching eks.tf for what is conceptually
# RAGAS-specific access.
#
# Policy: AmazonEKSAdminViewPolicy at namespace scope grants read+write
# on namespaced resources within the bound namespace. Effective perms:
#   * scale, get, list, watch on Deployments in `llm`
#   * create, delete, get, list on Jobs in `llm`
# Cluster-wide admin would be overkill — the workflow doesn't touch
# anything outside `llm`.

resource "aws_eks_access_entry" "gha_eval" {
  cluster_name      = module.eks.cluster_name
  principal_arn     = aws_iam_role.gha_eval.arn
  kubernetes_groups = [] # empty groups; access driven by the policy below
  type              = "STANDARD"
}

resource "aws_eks_access_policy_association" "gha_eval_llm_admin" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.gha_eval.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy"
  access_scope {
    type       = "namespace"
    namespaces = ["llm"]
  }

  # The policy association depends on the access entry existing first.
  # Terraform infers this from the principal_arn reference, but the
  # explicit dependency is cheap insurance against ordering races.
  depends_on = [aws_eks_access_entry.gha_eval]
}

# ---------------------------------------------------------------------------
# Outputs — paste into GHA repo Variables
# ---------------------------------------------------------------------------

output "ragas_eval_ecr_url" {
  value       = aws_ecr_repository.ragas_eval.repository_url
  description = "Set as the RAGAS_EVAL_ECR_REPOSITORY_URL repo variable in GitHub Actions"
}

# eks_cluster_name was probably already exposed somewhere, but in case
# it isn't — surface it here for the EKS_CLUSTER_NAME repo variable the
# RAGAS workflow needs.
output "eks_cluster_name_for_ragas" {
  value       = module.eks.cluster_name
  description = "Set as the EKS_CLUSTER_NAME repo variable in GitHub Actions"
}
