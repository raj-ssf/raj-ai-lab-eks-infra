# Shared trust policy used by every IAM role that pods assume via EKS Pod
# Identity. Replaces per-cluster OIDC federation (IRSA): the trust is on a
# fixed AWS service principal, so destroying and rebuilding the cluster does
# not invalidate any IAM role.
data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
    actions = [
      "sts:AssumeRole",
      "sts:TagSession",
    ]
  }
}

# AWS Load Balancer Controller IAM policy. The previous IRSA module pulled
# this in via `attach_load_balancer_controller_policy = true`; with plain
# aws_iam_role we fetch the canonical JSON directly from the project.
# Pinned to the chart version installed in alb-controller.tf.
data "http" "alb_controller_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.11.0/docs/install/iam_policy.json"
}

resource "aws_iam_policy" "alb_controller" {
  name        = "${var.cluster_name}-alb-controller"
  description = "Permissions for AWS Load Balancer Controller (pinned to chart v1.11.0 / controller v2.11.0)"
  policy      = data.http.alb_controller_policy.response_body
}
