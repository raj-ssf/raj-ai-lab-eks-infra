data "aws_caller_identity" "current" {}

resource "aws_iam_policy" "rag_service_bedrock" {
  name        = "${var.cluster_name}-rag-service-bedrock"
  description = "Allow rag-service to invoke Bedrock Claude 3.5 Haiku via the us.* cross-region inference profile"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
        ]
        Resource = [
          "arn:aws:bedrock:${var.region}:${data.aws_caller_identity.current.account_id}:inference-profile/us.anthropic.*",
          "arn:aws:bedrock:${var.region}:${data.aws_caller_identity.current.account_id}:inference-profile/us.amazon.*",
          "arn:aws:bedrock:*::foundation-model/anthropic.*",
          "arn:aws:bedrock:*::foundation-model/amazon.*",
        ]
      },
    ]
  })
}

module "rag_service_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name = "${var.cluster_name}-rag-service"

  role_policy_arns = {
    bedrock = aws_iam_policy.rag_service_bedrock.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["rag:rag-service"]
    }
  }
}

output "rag_service_irsa_arn" {
  value = module.rag_service_irsa.iam_role_arn
}
