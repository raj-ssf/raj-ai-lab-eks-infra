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
      # Phase #61: cert-manager-webhook 1 → 2 replicas. The webhook
      # is in the admission path of EVERY Certificate, Issuer, and
      # ClusterIssuer CRUD in the cluster (validating + mutating
      # webhooks both run here). Single-pod failure during chart
      # upgrade or OOM = stalled cert issuance and renewal.
      #
      # The lab has ~10 Certificates today (chat, grafana, vault,
      # keycloak, langfuse, argocd, rollouts, prometheus, gateway
      # listeners, and more) all auto-renewed via Let's Encrypt.
      # If the webhook is down at renewal time, the renewal
      # CertificateRequest sits Pending until the webhook comes
      # back. With 90-day cert lifetimes and 30-day renewBefore
      # this is unlikely to cause an outage, but it's a real gap.
      #
      # Anti-affinity: preferredDuringSchedulingIgnoredDuringExecution
      # weight=100 topologyKey=hostname. cert-manager isn't AZ-pinned,
      # so cross-node spread is satisfiable (3 static nodes across 3
      # AZs). Same Phase #59/60 lesson — preferred over required so
      # the second pod schedules even in node-constrained moments.
      #
      # Why NOT bump controller (top-level replicaCount) or cainjector:
      # both use leader election (Lease in cert-manager ns). A second
      # replica is warm-standby only — adds memory cost without
      # throughput. Failover takes ~15s on lease expiry. controller
      # failure delays new Certificate issuance briefly but doesn't
      # block; cainjector failure delays CA-bundle patching of CRDs
      # but doesn't affect existing certs. Phase #61b candidate if
      # we want true HA on these too.
      webhook = {
        replicaCount = 2
        affinity = {
          podAntiAffinity = {
            preferredDuringSchedulingIgnoredDuringExecution = [{
              weight = 100
              podAffinityTerm = {
                labelSelector = {
                  matchLabels = {
                    "app.kubernetes.io/name"      = "webhook"
                    "app.kubernetes.io/instance"  = "cert-manager"
                    "app.kubernetes.io/component" = "webhook"
                  }
                }
                topologyKey = "kubernetes.io/hostname"
              }
            }]
          }
        }
      }
    })
  ]

  depends_on = [
    module.eks,
    aws_eks_pod_identity_association.cert_manager,
  ]
}


# Phase 3 (Cilium migration): cert-manager controller, webhook, and
# cainjector NetworkPolicies removed. The standard K8s NetworkPolicy
# (Phase #70b/c/d in the old lab) was blocking egress to coredns +
# Pod Identity agent during Phase 3 debugging. Phase 5 will reintroduce
# policy as CiliumNetworkPolicy with hubble flow visibility for
# easier debugging of denied connections.
