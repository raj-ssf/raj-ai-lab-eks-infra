# Fine-tuning F1: foundations.
#
# What this file provisions:
#   - The `training` namespace (where PyTorchJobs run)
#   - An S3 bucket `<cluster>-training` with two prefixes:
#       datasets/   (read-only by training pod)
#       adapters/   (write by training pod, read by vllm pod)
#   - IAM role + Pod Identity for the training pod's ServiceAccount
#       (training/training-pod) granting r/w on its scoped prefixes
#   - Inline S3 read on adapters/* attached to the existing vllm IAM
#       role (model-weights.tf) so the vllm Deployment in the llm ns
#       can read fine-tuned LoRAs without a second SA
#   - ECR repo for the training image (Axolotl + dependencies; built
#       in F2 via GHA + cosign sign matching the other 5 service repos)
#
# Pod Identity (not IRSA) is used here for the same reason as every
# other AWS-touching workload in this lab: SA annotations are at risk
# of being stripped by reconcile loops (ArgoCD selfHeal, certain
# kubernetes_namespace TF resources) — Pod Identity puts the binding
# OUTSIDE Kubernetes via the aws_eks_pod_identity_association resource.

# ---------------------------------------------------------------------------
# Namespace
# ---------------------------------------------------------------------------

resource "kubernetes_namespace" "training" {
  metadata {
    name = "training"
    labels = {
      "kubernetes.io/metadata.name" = "training"
      # No istio-injection: training Jobs have no inbound traffic
      # (they pull datasets, push adapters, nothing routes TO them).
      # The sidecar would just add startup latency without security
      # value. If we ever add an HTTPRoute to a training-status API,
      # revisit.
    }
  }
}

# ---------------------------------------------------------------------------
# S3 bucket
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "training" {
  bucket = "${var.cluster_name}-training"

  # Lab-scoped data; not blocking deletion for cluster teardown.
  force_destroy = false
}

resource "aws_s3_bucket_server_side_encryption_configuration" "training" {
  bucket = aws_s3_bucket.training.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "training" {
  bucket = aws_s3_bucket.training.id

  # Versioning on for adapters: if a training run produces a bad
  # LoRA that gets uploaded, we can roll back to a previous version
  # without re-running training. Datasets typically aren't mutated
  # in-place but versioning is cheap when objects are infrequently
  # overwritten.
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "training" {
  bucket                  = aws_s3_bucket.training.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# Training pod IAM + Pod Identity
# ---------------------------------------------------------------------------

resource "aws_iam_role" "training_pod" {
  name               = "${var.cluster_name}-training-pod"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_policy" "training_pod_s3" {
  name        = "${var.cluster_name}-training-pod-s3"
  description = "Read training datasets, write fine-tuned adapters back to S3."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadDatasets"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = "${aws_s3_bucket.training.arn}/datasets/*"
      },
      {
        Sid      = "WriteAdapters"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.training.arn}/adapters/*"
      },
      {
        Sid      = "ListBucketScoped"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.training.arn
        Condition = {
          # Restrict ListBucket to the two prefixes we care about.
          # Without this, a compromised training pod could enumerate
          # the bucket root.
          StringLike = {
            "s3:prefix" = ["datasets/*", "adapters/*", "datasets/", "adapters/"]
          }
        }
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "training_pod_s3" {
  role       = aws_iam_role.training_pod.name
  policy_arn = aws_iam_policy.training_pod_s3.arn
}

resource "aws_eks_pod_identity_association" "training_pod" {
  cluster_name    = module.eks.cluster_name
  namespace       = kubernetes_namespace.training.metadata[0].name
  service_account = "training-pod"
  role_arn        = aws_iam_role.training_pod.arn
}

# The ServiceAccount the PyTorchJob references. Pod Identity binds an
# IAM role to the (cluster, namespace, SA-name) tuple via
# aws_eks_pod_identity_association above — but that does NOT create the
# K8s ServiceAccount object itself. Other Pod Identity workloads in this
# lab (vllm, langfuse, etc.) get their SA from a Helm chart's
# serviceAccount.create=true. Training has no chart — the workload is a
# raw PyTorchJob YAML — so we declare the SA here in TF.
#
# No annotations needed: Pod Identity uses the EKS Pod Identity webhook,
# which keys off the association (not the SA annotation). This is the
# advantage over IRSA — no eks.amazonaws.com/role-arn annotation that
# ArgoCD or other reconcilers might strip.
resource "kubernetes_service_account" "training_pod" {
  metadata {
    name      = "training-pod"
    namespace = kubernetes_namespace.training.metadata[0].name
  }
}

# ---------------------------------------------------------------------------
# vLLM read access on adapters/* — extends the existing vllm IAM role
# (model-weights.tf) with a scoped policy. No new ServiceAccount needed;
# the existing vllm SA + Pod Identity association handles auth, this just
# adds the new permission.
# ---------------------------------------------------------------------------

resource "aws_iam_policy" "vllm_read_adapters" {
  name        = "${var.cluster_name}-vllm-read-adapters"
  description = "Allow the vllm Deployment to read fine-tuned LoRA adapters from S3."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadAdapters"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = "${aws_s3_bucket.training.arn}/adapters/*"
      },
      {
        Sid      = "ListAdaptersPrefix"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.training.arn
        Condition = {
          StringLike = {
            "s3:prefix" = ["adapters/*", "adapters/"]
          }
        }
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "vllm_read_adapters" {
  role       = aws_iam_role.vllm.name
  policy_arn = aws_iam_policy.vllm_read_adapters.arn
}

# ---------------------------------------------------------------------------
# ECR repo for the training image (built in F2)
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "training" {
  name                 = "training"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "training" {
  repository = aws_ecr_repository.training.name

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
# Outputs — copy into apps repo's training Dockerfile + Job manifests
# ---------------------------------------------------------------------------

output "training_bucket_name" {
  value       = aws_s3_bucket.training.id
  description = "S3 bucket for datasets + fine-tuned adapters."
}

output "training_ecr_url" {
  value       = aws_ecr_repository.training.repository_url
  description = "ECR repo for the training image (Axolotl + deps)."
}
