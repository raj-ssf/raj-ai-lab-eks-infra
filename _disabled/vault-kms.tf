# Dedicated KMS key for Vault auto-unseal. Rotating unseal keys is handled
# by AWS (enable_key_rotation = true), so pod restart → auto-unseal → ready.
# Recovery keys (printed on `vault operator init`) are a break-glass if the
# KMS key is ever disabled/deleted.
resource "aws_kms_key" "vault_unseal" {
  description             = "Vault auto-unseal for ${var.cluster_name}"
  enable_key_rotation     = true
  deletion_window_in_days = 7

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-vault-unseal"
  })
}

resource "aws_kms_alias" "vault_unseal" {
  name          = "alias/${var.cluster_name}-vault-unseal"
  target_key_id = aws_kms_key.vault_unseal.id
}

# Vault pod's IAM role + Pod Identity association. Matches the pattern used
# by the other 5 workloads on this cluster.
resource "aws_iam_policy" "vault_kms" {
  name        = "${var.cluster_name}-vault-kms-unseal"
  description = "Allow Vault to auto-unseal via the dedicated KMS key"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:DescribeKey",
      ]
      Resource = aws_kms_key.vault_unseal.arn
    }]
  })
}

resource "aws_iam_role" "vault" {
  name               = "${var.cluster_name}-vault"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy_attachment" "vault_kms" {
  role       = aws_iam_role.vault.name
  policy_arn = aws_iam_policy.vault_kms.arn
}

resource "aws_eks_pod_identity_association" "vault" {
  cluster_name    = module.eks.cluster_name
  namespace       = "vault"
  service_account = "vault"
  role_arn        = aws_iam_role.vault.arn
}

output "vault_unseal_kms_key_id" {
  value       = aws_kms_key.vault_unseal.id
  description = "KMS key ID used by Vault auto-unseal (referenced in vault.tf seal block)"
}
