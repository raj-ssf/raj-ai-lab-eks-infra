data "aws_caller_identity" "current" {}

resource "aws_iam_policy" "rag_service_bedrock" {
  name        = "${var.cluster_name}-rag-service-bedrock"
  description = "Allow rag-service to invoke Bedrock Nova/Titan/Claude models via the us.* cross-region inference profile"

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

resource "aws_iam_role" "rag_service" {
  name               = "${var.cluster_name}-rag-service"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy_attachment" "rag_service_bedrock" {
  role       = aws_iam_role.rag_service.name
  policy_arn = aws_iam_policy.rag_service_bedrock.arn
}

resource "aws_eks_pod_identity_association" "rag_service" {
  cluster_name    = module.eks.cluster_name
  namespace       = "rag"
  service_account = "rag-service"
  role_arn        = aws_iam_role.rag_service.arn
}

output "rag_service_role_arn" {
  value = aws_iam_role.rag_service.arn
}
