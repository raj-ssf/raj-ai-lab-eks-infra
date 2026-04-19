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

  module "cert_manager_irsa" {
    source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
    version = "~> 5.44"

    role_name = "${var.cluster_name}-cert-manager"

    role_policy_arns = {
      route53 = aws_iam_policy.cert_manager_route53.arn
    }

    oidc_providers = {
      main = {
        provider_arn               = module.eks.oidc_provider_arn
        namespace_service_accounts = ["cert-manager:cert-manager"]
      }
    }
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
          annotations = {
            "eks.amazonaws.com/role-arn" = module.cert_manager_irsa.iam_role_arn
          }
        }
      })
    ]

    depends_on = [
      module.eks,
      module.cert_manager_irsa,
    ]
  }