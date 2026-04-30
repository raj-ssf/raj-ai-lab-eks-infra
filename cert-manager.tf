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
    helm_release.alb_controller,
  ]
}

# =============================================================================
# Phase #70b: NetworkPolicy for cert-manager controller pod.
#
# Same pattern as Phase #70's external-dns NetworkPolicy. Lower-stakes
# than the webhook (controller failure stalls renewals; webhook
# failure blocks Cert/Issuer/ClusterIssuer CRUD), so the controller
# is the natural next step in the incremental rollout.
#
# Traffic profile:
#   Ingress  None expected. Controller exposes /metrics on :9402 but
#            no ServiceMonitor scrapes it today (verified: no
#            cert-manager ServiceMonitor in cluster). Default-deny.
#
#   Egress   3 destinations, identical shape to external-dns:
#            - CoreDNS (53) for DNS resolution
#            - Pod Identity Agent (169.254.170.23:80) for Route53
#              creds (DNS-01 challenges)
#            - 0.0.0.0/0 except IMDS (443) for:
#              * K8s API server
#              * ACME directory at acme-v02.api.letsencrypt.org
#              * Route53 API (route53.amazonaws.com)
#              * DNS-01 self-check via DoH at 1.1.1.1:443
#                (chart's default --dns01-recursive-nameservers)
#
# Failure mode if a rule is wrong:
#   - DNS rule wrong  → ACME calls fail with "no such host"; new
#                       Certificate resources stay Pending until
#                       fixed. Existing certs unaffected (already
#                       issued, valid for 90 days).
#   - Pod Identity    → Route53 DNS-01 challenges fail with "no
#     wrong             valid AWS credentials". HTTP-01 still works
#                       (no AWS creds needed for that path).
#   - 443 rule wrong  → Cannot reach Let's Encrypt OR K8s API.
#                       Reconciliation halts entirely.
#
# IMDS exception (169.254.169.254/32): same defense-in-depth
# rationale as external-dns. Pod Identity uses 169.254.170.23,
# not IMDS; blocking IMDS prevents any future SDK fallback to
# the node's IAM role. Aligned with EC2 metadataOptions IMDSv2
# enforcement at the L3 layer.
#
# Phase #70c (next): cert-manager-webhook NetworkPolicy. Different
# shape — webhook is INGRESS-heavy (admission calls from K8s API
# server), and the chart sets failurePolicy=Fail so getting
# ingress wrong = blocked Cert CRUD cluster-wide. Bigger stakes.
# Phase #70d: cert-manager-cainjector (smallest scope; only
# K8s API egress).
# =============================================================================

resource "kubectl_manifest" "cert_manager_webhook_netpol" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "cert-manager-webhook"
      namespace = kubernetes_namespace.cert_manager.metadata[0].name
    }
    spec = {
      podSelector = {
        matchLabels = {
          "app.kubernetes.io/name"      = "webhook"
          "app.kubernetes.io/instance"  = "cert-manager"
          "app.kubernetes.io/component" = "webhook"
        }
      }
      policyTypes = ["Ingress", "Egress"]

      # Phase #70c: cert-manager-webhook NetworkPolicy.
      #
      # Higher stakes than #70b — the chart sets failurePolicy=Fail on
      # both ValidatingWebhookConfiguration + MutatingWebhookConfiguration
      # for cert-manager. If the webhook pod is unreachable, ALL Cert /
      # Issuer / ClusterIssuer / Order / Challenge CRUD across the
      # cluster gets rejected with admission errors until the webhook
      # comes back.
      #
      # Ingress shape (different from #70/#70b):
      #
      #   - 10250/TCP (https)        admission-webhook calls from the
      #                              EKS managed kube-apiserver. Source
      #                              IPs are the API server's, which
      #                              live OUTSIDE the cluster's pod
      #                              network — can't be matched via
      #                              namespaceSelector. ipBlock-based
      #                              tightening would need the EKS
      #                              public/private endpoint IP range,
      #                              which isn't a documented constant.
      #                              Allow from anywhere on this port.
      #                              The webhook does mutual TLS auth
      #                              with the API server's client cert,
      #                              so L3 broadness is acceptable —
      #                              authn happens at L7.
      #
      #   - 6080/TCP (healthcheck)   kubelet liveness/readiness probes.
      #                              kubelet runs on the same node as
      #                              the pod; AWS VPC CNI evaluates
      #                              kubelet→pod traffic before
      #                              NetworkPolicy in most setups, but
      #                              allowing 6080 explicitly is the
      #                              unambiguous form. Without this, a
      #                              CNI behavioral change could cause
      #                              probes to fail → pod marked
      #                              Unready → endpoint dropped → API
      #                              server can't reach webhook → admission
      #                              storm.
      #
      #   - 9402/TCP (metrics)       Prometheus scrape port. No
      #                              ServiceMonitor today (verified
      #                              Phase #70b commit) but allowing
      #                              ingress here means future metric
      #                              scraping doesn't require another
      #                              NetworkPolicy edit.
      #
      # Egress shape (much smaller than #70/#70b — webhook makes no
      # AWS API calls, so no Pod Identity Agent rule needed):
      #
      #   - DNS (53/UDP+TCP) → CoreDNS for resolving K8s API endpoint
      #   - K8s API (443/TCP) → for self-reads (its own TLS Secret,
      #                          other Cert resources for validation)
      #
      # Apply path safety: NetworkPolicy applies only to NEW
      # connections. The current admission-webhook calls from the API
      # server use long-lived HTTP/2 streams; existing streams keep
      # flowing during the apply. Failure mode if a rule is wrong:
      # the next admission call (typically within seconds for an
      # active cluster) hangs/fails, and Cert CRUD starts breaking.
      # Watch closely after apply — a quick `kubectl create
      # certificate ...` test surfaces breakage immediately.
      ingress = [{
        ports = [
          { protocol = "TCP", port = 10250 }, # admission webhook
          { protocol = "TCP", port = 6080 },  # kubelet probes
          { protocol = "TCP", port = 9402 },  # metrics
        ]
      }]

      egress = [
        # --- DNS via CoreDNS -----------------------------------------
        {
          to = [{
            namespaceSelector = {
              matchLabels = {
                "kubernetes.io/metadata.name" = "kube-system"
              }
            }
            podSelector = {
              matchLabels = {
                "k8s-app" = "kube-dns"
              }
            }
          }]
          ports = [
            { protocol = "UDP", port = 53 },
            { protocol = "TCP", port = 53 },
          ]
        },

        # --- K8s API (443/TCP) ---------------------------------------
        {
          to = [{
            ipBlock = {
              cidr = "0.0.0.0/0"
              except = [
                "169.254.169.254/32", # IMDS — defense in depth
              ]
            }
          }]
          ports = [{
            protocol = "TCP"
            port     = 443
          }]
        },
      ]
    }
  })

  depends_on = [
    helm_release.cert_manager,
  ]
}

resource "kubectl_manifest" "cert_manager_controller_netpol" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "cert-manager-controller"
      namespace = kubernetes_namespace.cert_manager.metadata[0].name
    }
    spec = {
      podSelector = {
        matchLabels = {
          "app.kubernetes.io/name"      = "cert-manager"
          "app.kubernetes.io/instance"  = "cert-manager"
          "app.kubernetes.io/component" = "controller"
        }
      }
      policyTypes = ["Ingress", "Egress"]

      ingress = []

      egress = [
        # --- DNS via CoreDNS -----------------------------------------
        {
          to = [{
            namespaceSelector = {
              matchLabels = {
                "kubernetes.io/metadata.name" = "kube-system"
              }
            }
            podSelector = {
              matchLabels = {
                "k8s-app" = "kube-dns"
              }
            }
          }]
          ports = [
            { protocol = "UDP", port = 53 },
            { protocol = "TCP", port = 53 },
          ]
        },

        # --- Pod Identity Agent --------------------------------------
        {
          to = [{
            ipBlock = {
              cidr = "169.254.170.23/32"
            }
          }]
          ports = [{
            protocol = "TCP"
            port     = 80
          }]
        },

        # --- HTTPS to internet (K8s API + ACME + Route53 + DoH) ------
        {
          to = [{
            ipBlock = {
              cidr = "0.0.0.0/0"
              except = [
                "169.254.169.254/32", # IMDS — defense in depth
              ]
            }
          }]
          ports = [{
            protocol = "TCP"
            port     = 443
          }]
        },
      ]
    }
  })

  depends_on = [
    helm_release.cert_manager,
  ]
}
