resource "aws_iam_policy" "cert_manager_route53" {
  name        = "${var.cluster_name}-cert-manager-route53"
  description = "Allow cert-manager to solve ACME DNS-01 challenges in the ekstest.com hosted zone"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "route53:GetChange"
        Resource = "arn:aws:route53:::change/*"
      },
      {
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets",
        ]
        Resource = "arn:aws:route53:::hostedzone/${data.aws_route53_zone.main.zone_id}"
      },
      {
        Effect   = "Allow"
        Action   = "route53:ListHostedZonesByName"
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role" "cert_manager" {
  name               = "${var.cluster_name}-cert-manager"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy_attachment" "cert_manager_route53" {
  role       = aws_iam_role.cert_manager.name
  policy_arn = aws_iam_policy.cert_manager_route53.arn
}

resource "aws_eks_pod_identity_association" "cert_manager" {
  cluster_name    = module.eks.cluster_name
  namespace       = "cert-manager"
  service_account = "cert-manager"
  role_arn        = aws_iam_role.cert_manager.arn
}

resource "kubernetes_namespace" "cert_manager" {
  metadata {
    name = "cert-manager"
  }
}

resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  namespace  = kubernetes_namespace.cert_manager.metadata[0].name
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = "v1.16.2"

  values = [
    yamlencode({
      crds = {
        enabled = true
        keep    = true
      }
      serviceAccount = {
        create = true
        name   = "cert-manager"
        # No annotations needed: Pod Identity binds the SA to the role.
      }
    })
  ]

  depends_on = [
    module.eks,
    aws_eks_pod_identity_association.cert_manager,
    helm_release.alb_controller,
  ]
}
