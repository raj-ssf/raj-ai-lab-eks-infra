resource "aws_iam_policy" "external_dns" {
  name        = "${var.cluster_name}-external-dns"
  description = "Allow external-dns to manage Route 53 records in the ${var.domain} hosted zone"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "route53:ChangeResourceRecordSets"
        Resource = "arn:aws:route53:::hostedzone/${data.aws_route53_zone.main.zone_id}"
      },
      {
        Effect = "Allow"
        Action = [
          "route53:ListHostedZones",
          "route53:ListResourceRecordSets",
          "route53:ListTagsForResource",
        ]
        Resource = "*"
      },
    ]
  })
}

module "external_dns_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name = "${var.cluster_name}-external-dns"

  role_policy_arns = {
    route53 = aws_iam_policy.external_dns.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-dns:external-dns"]
    }
  }
}

resource "kubernetes_namespace" "external_dns" {
  metadata {
    name = "external-dns"
  }
}

resource "helm_release" "external_dns" {
  name       = "external-dns"
  namespace  = kubernetes_namespace.external_dns.metadata[0].name
  repository = "https://kubernetes-sigs.github.io/external-dns"
  chart      = "external-dns"
  version    = "1.15.0"

  values = [
    yamlencode({
      provider = {
        name = "aws"
      }
      env = [
        {
          name  = "AWS_REGION"
          value = var.region
        },
      ]
      serviceAccount = {
        create = true
        name   = "external-dns"
        annotations = {
          "eks.amazonaws.com/role-arn" = module.external_dns_irsa.iam_role_arn
        }
      }
      domainFilters = [var.domain]
      policy        = "sync"
      txtOwnerId    = var.cluster_name
      sources = [
        "service",
        "ingress",
      ]
      registry = "txt"
      logLevel = "info"
      interval = "1m"
    })
  ]

  depends_on = [
    module.eks,
    module.external_dns_irsa,
    helm_release.alb_controller,
  ]
}