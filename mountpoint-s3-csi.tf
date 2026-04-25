# S3 Mountpoint CSI driver — mounts S3 bucket prefixes as read-only
# filesystems, backing Kubernetes PersistentVolumes with S3 objects
# instead of EBS blocks. Used for the "giant model" storage tier
# (Llama 3.1 405B AWQ, ~230 GB) where a dedicated gp3 PVC of that
# size ($18/mo idle) isn't justified for a rarely-run test.
#
# Architecture:
#   - EKS add-on (AWS-managed, auto-upgrades via EKS lifecycle)
#   - IAM role with read-only S3 access on the model-weights bucket
#     (GetObject + ListBucket only — no writes, enforced at IAM so
#     the mount is effectively read-only regardless of the driver's
#     default allow-writes behavior)
#   - Pod Identity association (not IRSA) for consistency with this
#     cluster's other workload-to-IAM bindings
#   - Driver runs as a DaemonSet in kube-system; service account
#     name is `s3-csi-driver-sa` (driver-level auth mode — a single
#     identity handles all S3 Mountpoint volumes cluster-wide, vs
#     pod-level auth which would need per-pod IAM)
#
# The application pod (llm/vllm-llama-405b) does NOT need its own
# S3 permissions — the CSI driver handles the S3 I/O on the pod's
# behalf; the pod just sees a mounted POSIX directory at /model.
#
# First-access cost: weights stream from S3 as they're mmap-faulted
# during vLLM's layer-loading phase. Over a VPC S3 gateway endpoint
# (free egress), 230 GB at ~5 Gbps sustained ≈ 6 min cold start.
# Subsequent pod restarts replay the same pattern (no local cache
# between pods). For the 405B-once-in-a-demo use case, this is fine;
# for tight-iteration loops use one of the hot-model PVCs instead.

data "aws_iam_policy_document" "s3_csi_driver_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "s3_csi_driver" {
  name               = "${var.cluster_name}-s3-csi-driver"
  assume_role_policy = data.aws_iam_policy_document.s3_csi_driver_trust.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "s3_csi_driver" {
  # ListBucket on the bucket itself — required for directory listings
  # (Mountpoint emits ListObjects calls to populate `ls` results).
  statement {
    sid     = "MountpointListBucket"
    effect  = "Allow"
    actions = ["s3:ListBucket"]
    resources = [
      aws_s3_bucket.model_weights.arn,
    ]
  }
  # GetObject on objects — the actual weight-file reads. Deliberately
  # no PutObject / DeleteObject / AbortMultipartUpload: IAM enforces
  # read-only at the identity level, so even if a driver bug or
  # misconfigured mountOption tried to write, S3 would return 403.
  statement {
    sid     = "MountpointGetObject"
    effect  = "Allow"
    actions = ["s3:GetObject"]
    resources = [
      "${aws_s3_bucket.model_weights.arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "s3_csi_driver" {
  name   = "s3-mountpoint-readonly"
  role   = aws_iam_role.s3_csi_driver.id
  policy = data.aws_iam_policy_document.s3_csi_driver.json
}

resource "aws_eks_pod_identity_association" "s3_csi_driver" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "s3-csi-driver-sa"
  role_arn        = aws_iam_role.s3_csi_driver.arn
}

resource "aws_eks_addon" "s3_csi_driver" {
  cluster_name = module.eks.cluster_name
  addon_name   = "aws-mountpoint-s3-csi-driver"
  # addon_version deliberately unset — EKS picks the latest version
  # compatible with the current cluster_version (1.34). To pin:
  #   aws eks describe-addon-versions \
  #     --addon-name aws-mountpoint-s3-csi-driver \
  #     --kubernetes-version 1.34
  # and paste the returned defaultVersion into addon_version.
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_pod_identity_association.s3_csi_driver,
  ]

  tags = local.common_tags
}
