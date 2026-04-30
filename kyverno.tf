# Kyverno admission controller — enforces image-signature verification on
# pods whose images come from our ECR. Partners with cosign signing in the
# rag-service GHA workflow (see raj-ai-lab-eks/.github/workflows/).
#
# Kyverno verifies signatures by fetching the .sig OCI artifact from ECR;
# its service account needs ECR read permissions, which we provide via Pod
# Identity (same pattern as the other 5 workloads on this cluster).

resource "kubernetes_namespace" "kyverno" {
  metadata {
    name = "kyverno"
  }
}

# --- IAM: Kyverno reads ECR to fetch signature artifacts ---------------------

resource "aws_iam_policy" "kyverno_ecr_read" {
  name        = "${var.cluster_name}-kyverno-ecr-read"
  description = "Allow Kyverno admission controller to fetch cosign signature artifacts from ECR"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:DescribeImages",
        ]
        # Widened 2026-04-25 to include langgraph-service alongside
        # rag-service, and 2026-04-26 to include chat-ui. Unlike the
        # GHA push roles (which we split per-service for least-
        # privilege isolation), Kyverno runs a single admission-
        # controller pod with a single IAM role — can't split per-
        # service. New signed-image workloads need to be added here
        # when they enter Enforce mode.
        Resource = [
          aws_ecr_repository.rag_service.arn,
          aws_ecr_repository.langgraph_service.arn,
          aws_ecr_repository.chat_ui.arn,
          aws_ecr_repository.ingestion_service.arn,
        ]
      },
    ]
  })
}

resource "aws_iam_role" "kyverno" {
  name               = "${var.cluster_name}-kyverno"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy_attachment" "kyverno_ecr" {
  role       = aws_iam_role.kyverno.name
  policy_arn = aws_iam_policy.kyverno_ecr_read.arn
}

# Kyverno's admission controller SA is `kyverno-admission-controller` (chart
# default). The verifyImages rule path runs inside that pod.
resource "aws_eks_pod_identity_association" "kyverno" {
  cluster_name    = module.eks.cluster_name
  namespace       = kubernetes_namespace.kyverno.metadata[0].name
  service_account = "kyverno-admission-controller"
  role_arn        = aws_iam_role.kyverno.arn
}

# --- Helm release ------------------------------------------------------------

resource "helm_release" "kyverno" {
  name       = "kyverno"
  namespace  = kubernetes_namespace.kyverno.metadata[0].name
  repository = "https://kyverno.github.io/kyverno"
  chart      = "kyverno"
  version    = "3.3.5"

  # Phase #58 first-attempt 2026-04-30 timed out at default 300s
  # on the post-upgrade hook (helm waits for new admissionController
  # pods to reach Ready; with 3 replicas pulling images + CRD
  # webhook reconcile happening concurrently, 300s wasn't enough
  # even though pods all became Ready by ~5min). 900s leaves margin
  # for chart upgrades that scale-up admission pods.
  timeout = 900

  values = [
    yamlencode({
      # Phase #58: admissionController bumped 1 → 3. The original
      # comment documented "run 3 replicas for HA and reduced
      # webhook timeout risk" but the value was never applied —
      # fixing now.
      #
      # Why this is the highest-priority kyverno bump: the admission
      # controller serves the ValidatingAdmissionWebhook the K8s API
      # calls on every CREATE/UPDATE pod. Single-pod kyverno =
      # cluster-wide blast radius. If the one pod OOMs, gets
      # rescheduled, or has a slow GC pause, EVERY pod creation in
      # rag/qdrant/keycloak/argocd/llm/langfuse/training/kubeflow
      # (the namespaces in deny-unverified-images-critical-
      # namespaces at kyverno-policies-catchall.tf:158) fails until
      # kyverno is back. With 3 replicas + the K8s Service
      # round-robin sending webhook requests across all healthy
      # pods, single-pod failure degrades gracefully — surviving
      # pods carry the admission load.
      admissionController = {
        replicas = 3
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
      }
      # background/cleanup/reports controllers stay at 1: they use
      # leader election, so multi-replica only adds standby cost
      # without throughput gain. Their failure modes are lower-
      # impact: gaps in PolicyReport generation (background),
      # missed CleanupPolicy firings (cleanup), missed report
      # aggregations (reports). None block live admission. Phase
      # #58b candidate if standby-failover-time matters.
      backgroundController = {
        replicas = 1
        resources = {
          requests = { cpu = "50m", memory = "128Mi" }
          limits   = { cpu = "200m", memory = "256Mi" }
        }
      }
      cleanupController = {
        replicas = 1
        resources = {
          requests = { cpu = "50m", memory = "64Mi" }
          limits   = { cpu = "100m", memory = "128Mi" }
        }
      }
      reportsController = {
        replicas = 1
        resources = {
          requests = { cpu = "50m", memory = "128Mi" }
          limits   = { cpu = "200m", memory = "256Mi" }
        }
      }
    })
  ]

  depends_on = [
    module.eks,
    helm_release.alb_controller,
    aws_eks_pod_identity_association.kyverno,
  ]
}
