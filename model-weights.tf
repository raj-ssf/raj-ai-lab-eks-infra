# Model weights staging bucket + Pod Identity for the vLLM serving workload.
#
# Pattern mirrors bedrock.tf: aws_iam_policy + aws_iam_role with the shared
# pod_identity_trust + aws_eks_pod_identity_association binding an in-cluster
# ServiceAccount to the role. No IRSA / OIDC federation — Pod Identity's
# trust is on a fixed service principal so destroy+recreate of the cluster
# keeps the role valid.
#
# Runtime cost when idle: $0. Bucket is empty until weights are uploaded,
# S3 storage is $0.023/GB-month once populated (~$1/mo for a 38 GB AWQ
# checkpoint). The expensive part is the GPU node group, which lives
# behind a toggle and stays off by default.
#
# Layout convention inside the bucket:
#   s3://${bucket}/llama-3.3-70b-instruct-awq-int4/
#     config.json, tokenizer.json, model-*.safetensors, ...
# The vLLM pod's init container does `s5cmd cp 's3://.../llama-3.3-.../*' /model/`
# into an emptyDir sized to fit the checkpoint on the node's local NVMe.

resource "aws_s3_bucket" "model_weights" {
  bucket = "${var.cluster_name}-model-weights"
}

resource "aws_s3_bucket_versioning" "model_weights" {
  bucket = aws_s3_bucket.model_weights.id
  versioning_configuration {
    # Versioning on so an accidental s5cmd rm during staging doesn't
    # permanently lose a checkpoint we spent 30 min downloading from HF.
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "model_weights" {
  bucket = aws_s3_bucket.model_weights.id
  rule {
    apply_server_side_encryption_by_default {
      # SSE-S3 (AES-256, AWS-managed key) — simpler than SSE-KMS, no extra
      # kms:Decrypt permissions needed on the pod's IAM role. Escalate to
      # KMS if the lab ever handles sensitive fine-tuned weights.
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "model_weights" {
  bucket                  = aws_s3_bucket.model_weights.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- IAM: vLLM serving pod reads model weights from the bucket ---------------

resource "aws_iam_policy" "vllm_model_weights_read" {
  name        = "${var.cluster_name}-vllm-model-weights-read"
  description = "Allow vLLM pods to pull model weights from the model-weights S3 bucket"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # ListBucket at the bucket root so s5cmd can enumerate prefixes.
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.model_weights.arn
      },
      {
        # Read-only on objects. No PutObject — staging uploads happen from
        # a dev workstation (saml2aws profile `raj`), not from inside pods.
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = "${aws_s3_bucket.model_weights.arn}/*"
      },
    ]
  })
}

resource "aws_iam_role" "vllm" {
  name               = "${var.cluster_name}-vllm"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy_attachment" "vllm_model_weights_read" {
  role       = aws_iam_role.vllm.name
  policy_arn = aws_iam_policy.vllm_model_weights_read.arn
}

# Binds the IAM role to ServiceAccount `vllm` in namespace `llm`. The
# namespace doesn't need to exist yet — the association activates whenever
# a pod in that ns mounts that SA. ArgoCD will create the ns when it
# syncs the llm/ app.
resource "aws_eks_pod_identity_association" "vllm" {
  cluster_name    = module.eks.cluster_name
  namespace       = "llm"
  service_account = "vllm"
  role_arn        = aws_iam_role.vllm.arn
}

# --- Outputs -----------------------------------------------------------------

output "model_weights_bucket" {
  value       = aws_s3_bucket.model_weights.id
  description = "Use for `aws s3 cp` / `s5cmd cp` when staging a new model checkpoint"
}

output "model_weights_bucket_arn" {
  value = aws_s3_bucket.model_weights.arn
}

output "vllm_role_arn" {
  value = aws_iam_role.vllm.arn
}

# =============================================================================
# Model-weights stager — one-shot K8s Job that downloads HuggingFace weights
# directly onto a worker node and s5cmd-uploads to the S3 bucket. Beats
# staging from a laptop by ~10x (AWS backbone + 10 Gbps NIC vs home upload).
#
# The IAM role persists after a Job finishes — future re-stages (new model,
# new quant) reuse it. The Job pod is ephemeral; this file only holds the
# identity/permissions side. Job manifest is applied ad-hoc (not ArgoCD-
# managed) since it's one-shot operational work, not a declared service.
# =============================================================================

resource "aws_iam_policy" "model_weights_stager" {
  name        = "${var.cluster_name}-model-weights-stager"
  description = "Allow in-cluster Job to upload model weights from HuggingFace into the model-weights S3 bucket"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.model_weights.arn
      },
      {
        # Write + read + multipart + delete (so rerunning overwrites cleanly)
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = "${aws_s3_bucket.model_weights.arn}/*"
      },
    ]
  })
}

resource "aws_iam_role" "model_weights_stager" {
  name               = "${var.cluster_name}-model-weights-stager"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy_attachment" "model_weights_stager" {
  role       = aws_iam_role.model_weights_stager.name
  policy_arn = aws_iam_policy.model_weights_stager.arn
}

resource "aws_eks_pod_identity_association" "model_weights_stager" {
  cluster_name    = module.eks.cluster_name
  namespace       = "default"
  service_account = "model-weights-stager"
  role_arn        = aws_iam_role.model_weights_stager.arn
}

output "model_weights_stager_role_arn" {
  value = aws_iam_role.model_weights_stager.arn
}
