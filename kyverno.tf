# Kyverno admission controller — enforces image-signature verification on
# pods whose images come from our ECR. Partners with cosign signing in the
# rag-service GHA workflow (see raj-ai-lab-eks/.github/workflows/).
#
# Kyverno verifies signatures by fetching the .sig OCI artifact from ECR;
# its service account needs ECR read permissions, which we provide via Pod
# Identity (same pattern as the other 5 workloads on this cluster).

resource "kubernetes_namespace" "kyverno" {
  metadata {
    name = "kyverno"
  }
}

# --- IAM: Kyverno reads ECR to fetch signature artifacts ---------------------

resource "aws_iam_policy" "kyverno_ecr_read" {
  name        = "${var.cluster_name}-kyverno-ecr-read"
  description = "Allow Kyverno admission controller to fetch cosign signature artifacts from ECR"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:DescribeImages",
        ]
        # Widened 2026-04-25 to include langgraph-service alongside
        # rag-service, and 2026-04-26 to include chat-ui. Unlike the
        # GHA push roles (which we split per-service for least-
        # privilege isolation), Kyverno runs a single admission-
        # controller pod with a single IAM role — can't split per-
        # service. New signed-image workloads need to be added here
        # when they enter Enforce mode.
        Resource = [
          aws_ecr_repository.rag_service.arn,
          aws_ecr_repository.langgraph_service.arn,
          aws_ecr_repository.chat_ui.arn,
          aws_ecr_repository.ingestion_service.arn,
        ]
      },
    ]
  })
}

resource "aws_iam_role" "kyverno" {
  name               = "${var.cluster_name}-kyverno"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy_attachment" "kyverno_ecr" {
  role       = aws_iam_role.kyverno.name
  policy_arn = aws_iam_policy.kyverno_ecr_read.arn
}

# Kyverno's admission controller SA is `kyverno-admission-controller` (chart
# default). The verifyImages rule path runs inside that pod.
resource "aws_eks_pod_identity_association" "kyverno" {
  cluster_name    = module.eks.cluster_name
  namespace       = kubernetes_namespace.kyverno.metadata[0].name
  service_account = "kyverno-admission-controller"
  role_arn        = aws_iam_role.kyverno.arn
}

# --- Helm release ------------------------------------------------------------

resource "helm_release" "kyverno" {
  name       = "kyverno"
  namespace  = kubernetes_namespace.kyverno.metadata[0].name
  repository = "https://kyverno.github.io/kyverno"
  chart      = "kyverno"
  version    = "3.3.5"

  # Phase #58 first-attempt 2026-04-30 timed out at default 300s
  # on the post-upgrade hook (helm waits for new admissionController
  # pods to reach Ready; with 3 replicas pulling images + CRD
  # webhook reconcile happening concurrently, 300s wasn't enough
  # even though pods all became Ready by ~5min). 900s leaves margin
  # for chart upgrades that scale-up admission pods.
  timeout = 900

  values = [
    yamlencode({
      # Phase #58: admissionController bumped 1 → 3. The original
      # comment documented "run 3 replicas for HA and reduced
      # webhook timeout risk" but the value was never applied —
      # fixing now.
      #
      # Why this is the highest-priority kyverno bump: the admission
      # controller serves the ValidatingAdmissionWebhook the K8s API
      # calls on every CREATE/UPDATE pod. Single-pod kyverno =
      # cluster-wide blast radius. If the one pod OOMs, gets
      # rescheduled, or has a slow GC pause, EVERY pod creation in
      # rag/qdrant/keycloak/argocd/llm/langfuse/training/kubeflow
      # (the namespaces in deny-unverified-images-critical-
      # namespaces at kyverno-policies-catchall.tf:158) fails until
      # kyverno is back. With 3 replicas + the K8s Service
      # round-robin sending webhook requests across all healthy
      # pods, single-pod failure degrades gracefully — surviving
      # pods carry the admission load.
      admissionController = {
        replicas = 3
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
      }
      # background/cleanup/reports controllers stay at 1: they use
      # leader election, so multi-replica only adds standby cost
      # without throughput gain. Their failure modes are lower-
      # impact: gaps in PolicyReport generation (background),
      # missed CleanupPolicy firings (cleanup), missed report
      # aggregations (reports). None block live admission. Phase
      # #58b candidate if standby-failover-time matters.
      backgroundController = {
        replicas = 1
        resources = {
          requests = { cpu = "50m", memory = "128Mi" }
          limits   = { cpu = "200m", memory = "256Mi" }
        }
      }
      cleanupController = {
        replicas = 1
        resources = {
          requests = { cpu = "50m", memory = "64Mi" }
          limits   = { cpu = "100m", memory = "128Mi" }
        }
      }
      reportsController = {
        replicas = 1
        resources = {
          requests = { cpu = "50m", memory = "128Mi" }
          limits   = { cpu = "200m", memory = "256Mi" }
        }
      }

      # Phase #58 + Broadcom-rename fix: kyverno chart 3.3.5 hardcodes
      # `bitnami/kubectl:1.30.2` for two post-upgrade hook Jobs
      # (webhooks-cleanup + policy-reports-cleanup). That image was
      # removed from Docker Hub during the late-2024 Bitnami →
      # Broadcom rename — pulls now return 404. Result: every helm
      # upgrade hangs indefinitely on these hook Jobs in
      # ImagePullBackOff, and helm marks the upgrade as failed
      # AFTER its 5-15 min timeout.
      #
      # Discovered live during Phase #58's first apply:
      #   pod/kyverno-clean-reports-r5fsq:
      #     "failed to resolve reference docker.io/bitnami/kubectl:
      #      1.30.2: not found"
      #
      # Override to `docker.io/bitnamilegacy/kubectl:1.33.4-debian-
      # 12-r0` which IS available (same image we used in Phase #54
      # for the 405B staging Job after hitting this exact gotcha).
      # The Kyverno catchall allowlist already includes
      # `docker.io/bitnamilegacy/*` so admission won't block these
      # hook pods.
      #
      # Why not upstream-fix kyverno chart: the bug exists in
      # released 3.3.x; an upgrade to 3.4+ is its own change and
      # may bring API surface drift. Override is the surgical fix.
      webhooksCleanup = {
        image = {
          registry   = "docker.io"
          repository = "bitnamilegacy/kubectl"
          tag        = "1.33.4-debian-12-r0"
        }
      }
      policyReportsCleanup = {
        image = {
          registry   = "docker.io"
          repository = "bitnamilegacy/kubectl"
          tag        = "1.33.4-debian-12-r0"
        }
      }
    })
  ]

  depends_on = [
    module.eks,
    helm_release.alb_controller,
    aws_eks_pod_identity_association.kyverno,
  ]
}

# =============================================================================
# Phase #65b: NetworkPolicy for kyverno (4 controller pods).
#
# kyverno is NOT meshed (it's an admission webhook that the EKS-managed
# kube-apiserver calls; the API server is outside the mesh, sees no
# Istio mTLS). So the meshed-app pattern in app-network-policies.tf
# doesn't apply directly. Different shape here.
#
# Highest stakes of all the controller-shape policies in #70b-d/#70e:
# the chart sets failurePolicy=Fail on:
#   - kyverno's policy-validating webhook (every Policy/ClusterPolicy
#     create/update) — minor blast radius
#   - the deny-unverified-images-* admission webhook (every pod CREATE
#     in the 8 namespaces in kyverno-policies-catchall.tf:158:
#     rag, qdrant, keycloak, argocd, llm, langfuse, training, kubeflow)
#     — MAJOR blast radius. If kyverno-svc:443 is unreachable, EVERY
#     new pod in those namespaces gets rejected at admission.
#
# The 4 kyverno controller pods have different shapes — using a single
# NetworkPolicy with namespace-wide selector instead of 4 per-component
# policies. The shared rules are conservative; admission-webhook (the
# one that matters for cluster correctness) gets enough on top via
# the 9443 + 443 ingress rules to function. Background/cleanup/reports
# controllers do mostly egress to K8s API + ECR; the same broad egress
# rules cover them.
#
# Ingress (3 ports):
#
#   9443/TCP (admission)    Webhook calls from kube-apiserver.
#                           Source IPs are EKS control-plane CIDRs,
#                           outside the cluster's pod network — same
#                           pattern as cert-manager-webhook (#70c).
#                           Allow from anywhere; mTLS auth at L7
#                           via the CA-bundled webhook config.
#
#   443/TCP                 cleanup-controller's webhook port (also
#                           kyverno-svc's exposed port). Same kube-
#                           apiserver source pattern.
#
#   8000/TCP (metrics)      Prometheus scrape. Already in the
#                           monitoring NP's egress allowlist (Phase
#                           #70g). Allowing here for completeness.
#
# Egress:
#
#   53/UDP+TCP → CoreDNS    Standard.
#   80/TCP → 169.254.170.23  Pod Identity Agent (the controllers
#                            need AWS creds for Kyverno's image-
#                            signature verification path that fetches
#                            cosign artifacts from ECR — Phase #58's
#                            kyverno-ecr-read IAM policy in this same
#                            file).
#   443/TCP → 0.0.0.0/0      K8s API + ECR (cosign signature fetches)
#     except IMDS            + any future image-registry verification
#                            sources (rekor, etc.).
#
# Smoke test post-apply (CRITICAL — failurePolicy=Fail makes this
# a fast-fail signal):
#
#   kubectl -n default run npol-smoketest --image=alpine \
#     --restart=Never --rm -i --tty=false -- echo ok
#
#   # If admission accepts the pod create, kyverno's webhook is
#   # reachable. If admission times out with "context deadline
#   # exceeded" or "connection refused", a NetworkPolicy rule is
#   # wrong and you should `terraform destroy -target=
#   # kubectl_manifest.kyverno_netpol` to unblock pod creates
#   # cluster-wide while you fix it.
#
# IMDS exception (169.254.169.254/32) is defense-in-depth same as
# the controller-shape policies. Pod Identity uses 169.254.170.23,
# not IMDS.
# =============================================================================

resource "kubectl_manifest" "kyverno_netpol" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "kyverno"
      namespace = kubernetes_namespace.kyverno.metadata[0].name
    }
    spec = {
      podSelector = {} # all kyverno-* controller pods
      policyTypes = ["Ingress", "Egress"]

      # --- Ingress: webhook + metrics ports ----------------------------
      ingress = [{
        ports = [
          { protocol = "TCP", port = 9443 }, # admission-controller webhook
          { protocol = "TCP", port = 443 },  # cleanup-controller webhook
          { protocol = "TCP", port = 8000 }, # Prometheus metrics
        ]
      }]

      # --- Egress ------------------------------------------------------
      egress = [
        # DNS via CoreDNS
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
        # Pod Identity Agent — kyverno-admission-controller calls ECR
        # for cosign signature artifacts via the IAM role attached
        # earlier in this file (kyverno_ecr_read).
        {
          to = [{
            ipBlock = {
              cidr = "169.254.170.23/32"
            }
          }]
          ports = [{ protocol = "TCP", port = 80 }]
        },
        # 443 outbound — K8s API + ECR + future signature-verification
        # backends. Except IMDS (defense-in-depth, force Pod Identity
        # path).
        {
          to = [{
            ipBlock = {
              cidr = "0.0.0.0/0"
              except = [
                "169.254.169.254/32", # IMDS
              ]
            }
          }]
          ports = [{ protocol = "TCP", port = 443 }]
        },
      ]
    }
  })

  depends_on = [
    helm_release.kyverno,
  ]
}
