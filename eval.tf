# Fine-tuning F4: eval harness for comparing base vs fine-tuned models.
#
# What this provisions:
#   - ECR repo for the eval image (lm-evaluation-harness + langfuse SDK + AWS tools)
#   - IAM role + Pod Identity for the eval pod's ServiceAccount (llm/eval-pod)
#       * Write on s3://<training-bucket>/eval-results/* (durable result storage)
#       * Read on adapters/* (in case the eval inspects adapter metadata)
#       * Read on datasets/* (in case the eval pulls a custom dataset)
#
# Why the eval lives in the `llm` namespace (not its own):
#   The eval Job calls the in-cluster vllm-llama-8b Service over HTTP.
#   Same-namespace traffic doesn't traverse Istio cross-ns boundaries
#   and doesn't need extra AuthorizationPolicies. The Job runs once,
#   completes, gets cleaned up — no long-lived workload in `llm` to
#   worry about colocation.
#
# Why a separate IAM role (not reuse training-pod):
#   training-pod lives in the training namespace. Pod Identity binds
#   (cluster, namespace, SA-name) → role; an SA in `llm` ns can't
#   reuse the training-pod IAM binding even if it has the same name.
#   Per-namespace SA + per-namespace IAM role is the cleaner pattern.

# ---------------------------------------------------------------------------
# ECR repo for the eval image
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "eval" {
  name                 = "eval"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "eval" {
  repository = aws_ecr_repository.eval.name

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
# Eval pod IAM role + Pod Identity association
# ---------------------------------------------------------------------------

resource "aws_iam_role" "eval_pod" {
  name               = "${var.cluster_name}-eval-pod"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_policy" "eval_pod_s3" {
  name        = "${var.cluster_name}-eval-pod-s3"
  description = "Read training adapters/datasets, write eval results back to S3."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadAdaptersAndDatasets"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = [
          "${aws_s3_bucket.training.arn}/adapters/*",
          "${aws_s3_bucket.training.arn}/datasets/*",
        ]
      },
      {
        Sid    = "WriteEvalResults"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.training.arn}/eval-results/*"
      },
      {
        Sid      = "ListBucketScoped"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.training.arn
        Condition = {
          StringLike = {
            "s3:prefix" = [
              "adapters/*", "adapters/",
              "datasets/*", "datasets/",
              "eval-results/*", "eval-results/",
            ]
          }
        }
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eval_pod_s3" {
  role       = aws_iam_role.eval_pod.name
  policy_arn = aws_iam_policy.eval_pod_s3.arn
}

resource "aws_eks_pod_identity_association" "eval_pod" {
  cluster_name = module.eks.cluster_name
  # Eval Job lives in the llm namespace (per F4 design — colocates
  # with the vLLM target Service it evaluates).
  namespace       = "llm"
  service_account = "eval-pod"
  role_arn        = aws_iam_role.eval_pod.arn
}

# Same lesson as F2's training-pod: Pod Identity binds the IAM role
# to a (cluster, namespace, SA-name) tuple but does NOT create the
# K8s ServiceAccount object itself. Eval has no Helm chart (raw Job
# YAML) so the SA needs to be declared here.
resource "kubernetes_service_account" "eval_pod" {
  metadata {
    name      = "eval-pod"
    namespace = "llm"
  }
  automount_service_account_token = false
}

# ---------------------------------------------------------------------------
# Outputs — copy into apps repo's eval Job manifest
# ---------------------------------------------------------------------------

output "eval_ecr_url" {
  value       = aws_ecr_repository.eval.repository_url
  description = "ECR repo for the eval image (lm-eval-harness)."
}
