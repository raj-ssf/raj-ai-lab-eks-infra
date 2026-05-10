resource "aws_iam_role" "alb_controller" {
  name               = "${var.cluster_name}-alb-controller"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn # defined in pod-identity.tf
}

resource "aws_eks_pod_identity_association" "alb_controller" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.alb_controller.arn
}

resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.11.0"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  # No SA role-arn annotation: Pod Identity binds the SA to the role.

  set {
    name  = "region"
    value = var.region
  }

  set {
    name  = "vpcId"
    value = var.vpc_id
  }

  # Disable backend SG management. The terraform-aws-modules/eks module
  # re-tags 3 SGs (cluster SG + node SG + AWS-managed eks-cluster-sg)
  # with `kubernetes.io/cluster/<name>=owned` on every apply, giving
  # AWS LBC multiple cluster-tagged SGs per ENI. AWS LBC's
  # ReconcileForNodePortEndpoints requires EXACTLY ONE — fails, never
  # registers targets. With enableBackendSecurityGroup=false, AWS LBC
  # skips the SG query. Node SG already permits intra-cluster traffic
  # (terraform-aws-modules/eks default), so NodePort still works.
  set {
    name  = "enableBackendSecurityGroup"
    value = "false"
  }

  depends_on = [
    module.eks,
    aws_eks_pod_identity_association.alb_controller,
  ]
}
