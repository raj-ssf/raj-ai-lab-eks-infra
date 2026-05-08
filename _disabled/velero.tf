# Velero — disaster-recovery backup for the cluster.
#
# What this provisions:
#   - S3 bucket <cluster>-velero for backup metadata + Kopia chunks
#   - IAM role + Pod Identity for the velero SA, granting:
#       * S3 r/w on the velero bucket (object operations + ListBucket)
#       * EC2 snapshot APIs (Describe/Create/Delete tags + volumes + snapshots)
#         — used when Velero takes EBS-snapshot-based PV backups (faster
#         than file-system, but single-region; we use fs-backup primarily
#         for portability)
#   - velero namespace + ServiceAccount (Pod Identity needs both)
#   - Helm release: vmware-tanzu/velero with the AWS plugin
#   - Schedule CR: nightly-all → backs up all user namespaces every
#       night, 7-day retention
#
# What this protects against:
#   - PVC data loss from `terraform destroy` of the cluster (Vault
#     secrets, Keycloak Postgres, Langfuse Postgres+ClickHouse, Qdrant
#     embeddings, vLLM model caches, ArgoCD repo cache, etc.). Without
#     Velero, a destroy + apply rebuilds the cluster but leaves all
#     stateful workloads with empty databases.
#   - Accidental `kubectl delete pvc` — restore the volume from the
#     last nightly snapshot.
#   - Cluster version upgrades that go sideways and need a rollback
#     to a known-good namespace state.
#
# What this does NOT protect against:
#   - Logical corruption (e.g., Keycloak upgrade migrates schema in a
#     way that breaks rollback) — Velero captures the state at backup
#     time, but if you restore an old Postgres into a new Keycloak
#     binary, you may need a separate downgrade plan.
#   - Postgres consistency: file-system snapshots of an active Postgres
#     can be torn. For a learning lab, "torn snapshot → re-init" is
#     acceptable; for production you'd add Velero backup hooks that
#     trigger pg_dump pre-snapshot. Documented as a known limitation.
#
# Why fs-backup (Kopia) instead of EBS snapshots:
#   - Kopia chunks land in S3 → portable across regions / accounts.
#     EBS snapshots are AWS-account + region scoped.
#   - Kopia deduplicates across backups → smaller storage footprint.
#   - EBS snapshots are 30-50% faster but offer no portability win for
#     a single-region lab. Kopia's perf is fine for our PVC sizes
#     (largest is the 38GB vllm-model-cache; backup runs in ~5 min).

# ---------------------------------------------------------------------------
# S3 bucket for backups
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "velero" {
  bucket = "${var.cluster_name}-velero"

  # force_destroy = true on this one because the bucket holds derivable
  # state (we can always re-take a backup). Unlike training/model-weights
  # buckets which hold the only copy of trained adapters / pre-uploaded
  # weights, losing the velero bucket just means losing backup history.
  force_destroy = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "velero" {
  bucket = aws_s3_bucket.velero.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "velero" {
  bucket = aws_s3_bucket.velero.id

  # Versioning OFF for the velero bucket: Velero manages its own backup
  # generations via Schedule TTL. S3 versioning on top would double-bill
  # storage for old chunks Velero already considers expired.
  versioning_configuration {
    status = "Disabled"
  }
}

resource "aws_s3_bucket_public_access_block" "velero" {
  bucket                  = aws_s3_bucket.velero.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "velero" {
  bucket = aws_s3_bucket.velero.id

  # Velero's Schedule TTL deletes objects logically (marks them for
  # deletion in its own metadata), but a bucket-level lifecycle is the
  # backstop that ensures un-tracked or orphaned objects don't accumulate
  # forever. 30d gives Velero plenty of headroom over our 7d Schedule TTL.
  rule {
    id     = "expire-stale-backups"
    status = "Enabled"
    filter {}
    expiration {
      days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ---------------------------------------------------------------------------
# IAM role + Pod Identity
# ---------------------------------------------------------------------------

resource "aws_iam_role" "velero" {
  name               = "${var.cluster_name}-velero"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_policy" "velero" {
  name        = "${var.cluster_name}-velero"
  description = "Velero backup permissions: S3 r/w on velero bucket, EC2 snapshot APIs"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3BucketObjects"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:PutObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = "${aws_s3_bucket.velero.arn}/*"
      },
      {
        Sid      = "S3BucketList"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.velero.arn
      },
      {
        # EBS snapshot APIs for PV-snapshot-based backups (alternative
        # path to fs-backup). Velero's volume-snapshot plugin uses
        # these to take/restore EBS snapshots directly. Keeping the
        # perms even though we default to fs-backup, so users can
        # opt into snapshot mode per-Backup if needed.
        Sid    = "EBSSnapshots"
        Effect = "Allow"
        Action = [
          "ec2:DescribeVolumes",
          "ec2:DescribeSnapshots",
          "ec2:CreateTags",
          "ec2:CreateVolume",
          "ec2:CreateSnapshot",
          "ec2:DeleteSnapshot",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "velero" {
  role       = aws_iam_role.velero.name
  policy_arn = aws_iam_policy.velero.arn
}

resource "aws_eks_pod_identity_association" "velero" {
  cluster_name    = module.eks.cluster_name
  namespace       = "velero"
  service_account = "velero"
  role_arn        = aws_iam_role.velero.arn
}

# ---------------------------------------------------------------------------
# Namespace + ServiceAccount
# ---------------------------------------------------------------------------

resource "kubernetes_namespace" "velero" {
  metadata {
    name = "velero"
    labels = {
      "kubernetes.io/metadata.name" = "velero"
      # No istio-injection: Velero talks to the K8s API server (cluster
      # internal, not meshed) and to S3 (egress, not meshed). The
      # node-agent DaemonSet uses hostPath mounts to read PVC contents
      # — no inter-pod mTLS required.
    }
  }
}

# Pod Identity binds (cluster, namespace, SA-name) → IAM role but does
# NOT create the K8s ServiceAccount. Same lesson as training-pod /
# eval-pod: SA needs to exist for Pod Identity to bind, and the Helm
# chart's serviceAccount.server.create=false (set in values below)
# means the chart won't create it either.
resource "kubernetes_service_account" "velero" {
  metadata {
    name      = "velero"
    namespace = kubernetes_namespace.velero.metadata[0].name
  }
  automount_service_account_token = true # velero needs to talk to K8s API
}

# ---------------------------------------------------------------------------
# Helm install
# ---------------------------------------------------------------------------

resource "helm_release" "velero" {
  name       = "velero"
  repository = "https://vmware-tanzu.github.io/helm-charts"
  chart      = "velero"
  version    = "8.5.0"
  namespace  = kubernetes_namespace.velero.metadata[0].name

  values = [yamlencode({
    # Skip the chart's velero-upgrade-crds pre-install hook. The hook
    # pulls docker.io/bitnami/kubectl:1.34 to re-apply CRDs across
    # chart upgrades — but that exact tag doesn't exist on Docker Hub
    # (post-Broadcom Bitnami repath). For a fresh install, CRDs ship
    # with the chart's crds/ dir, so the hook is dead weight. If we
    # ever need to do an in-place chart upgrade with new CRDs, flip
    # this back to true (and pin a working bitnami/kubectl tag if 1.34
    # still doesn't exist by then).
    upgradeCRDs = false

    # --- Storage location: our S3 bucket ----------------------------------
    configuration = {
      backupStorageLocation = [{
        name     = "default"
        provider = "aws"
        bucket   = aws_s3_bucket.velero.id
        config = {
          region = "us-west-2"
        }
      }]
      volumeSnapshotLocation = [{
        name     = "default"
        provider = "aws"
        config = {
          region = "us-west-2"
        }
      }]
      # Default to fs-backup (Kopia) for all volumes unless a Backup
      # opts out. Tradeoff written up at the top of this file.
      defaultVolumesToFsBackup = true
    }

    # --- AWS plugin (init container) --------------------------------------
    initContainers = [{
      name            = "velero-plugin-for-aws"
      image           = "velero/velero-plugin-for-aws:v1.11.0"
      imagePullPolicy = "IfNotPresent"
      volumeMounts = [{
        mountPath = "/target"
        name      = "plugins"
      }]
    }]

    # --- ServiceAccount: use ours, not the chart's ------------------------
    serviceAccount = {
      server = {
        # We declare it via kubernetes_service_account.velero so
        # Pod Identity binds correctly. No annotations needed:
        # Pod Identity uses the EKS webhook keyed off the
        # association resource, not SA annotations.
        create = false
        name   = "velero"
      }
    }

    # --- Node-agent DaemonSet for fs backups ------------------------------
    deployNodeAgent = true

    # --- Resources --------------------------------------------------------
    resources = {
      requests = { cpu = "200m", memory = "256Mi" }
      limits   = { cpu = "1", memory = "512Mi" }
    }
    nodeAgent = {
      resources = {
        requests = { cpu = "100m", memory = "128Mi" }
        limits   = { cpu = "1", memory = "1Gi" }
      }
    }

    # --- Metrics ----------------------------------------------------------
    # Velero exposes Prometheus metrics on /metrics:8085. Add a
    # ServiceMonitor so kube-prometheus-stack scrapes it.
    metrics = {
      enabled = true
      serviceMonitor = {
        enabled = true
      }
    }
  })]

  depends_on = [
    kubernetes_namespace.velero,
    kubernetes_service_account.velero,
    aws_eks_pod_identity_association.velero,
  ]
}

# ---------------------------------------------------------------------------
# Schedule: nightly backup of everything except system namespaces
# ---------------------------------------------------------------------------

resource "kubectl_manifest" "velero_nightly_schedule" {
  yaml_body = yamlencode({
    apiVersion = "velero.io/v1"
    kind       = "Schedule"
    metadata = {
      name      = "nightly-all"
      namespace = kubernetes_namespace.velero.metadata[0].name
    }
    spec = {
      # 02:00 UTC daily. Off-hours for any Pacific-time interactive
      # use; before any Pacific-morning work session.
      schedule = "0 2 * * *"
      template = {
        # Back up everything except infra namespaces that either
        # (a) regenerate from TF on apply, or (b) hold no useful state.
        excludedNamespaces = [
          "kube-system",
          "kube-public",
          "kube-node-lease",
          "velero",          # don't recursively back ourselves up
          "istio-system",    # mesh control plane regenerates from TF
          "kyverno",         # policies regenerate from TF
          "cert-manager",    # certs are renewable from ACME
          "external-dns",    # records regenerate from HTTPRoute state
          "karpenter",       # NodePool regenerates from TF
        ]
        # 7 days retention. Combined with the bucket-level 30-day
        # lifecycle, expired backups GC within a week and tarball
        # objects orphan within a month.
        ttl                      = "168h"
        storageLocation          = "default"
        defaultVolumesToFsBackup = true
        snapshotMoveData         = false
      }
    }
  })

  depends_on = [
    helm_release.velero,
  ]
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "velero_backup_bucket" {
  value       = aws_s3_bucket.velero.id
  description = "S3 bucket holding Velero backup metadata + Kopia chunks."
}

output "velero_role_arn" {
  value       = aws_iam_role.velero.arn
  description = "IAM role assumed by velero pods via Pod Identity."
}
