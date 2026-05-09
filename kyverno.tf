# =============================================================================
# Phase 6: Kyverno admission controller — preventive policies.
#
# Pairs with Trivy (Phase 5d). Trivy is detective — scans existing state
# for CVEs / config / RBAC issues and produces VulnerabilityReport CRs.
# Kyverno is preventive — runs as a ValidatingAdmissionWebhook on
# CREATE/UPDATE for every K8s resource, blocks/mutates at admission time
# before bad config ever lands in the cluster.
#
# Differences from the original (Istio-coupled) kyverno.tf in _disabled:
#   - NO ECR-signature-verification IAM. The original lab had cosign-
#     signed images in ECR (rag-service, langgraph-service, chat-ui,
#     ingestion-service); none of those exist in this cluster yet.
#     When ECR signed images come back in Phase 4f or later, restore
#     the kyverno_ecr_read IAM policy + Pod Identity association +
#     Kyverno verifyImages policy.
#   - Webhook image overrides kept — chart's hardcoded
#     `bitnami/kubectl:1.30.2` is gone from docker.io after the
#     Broadcom rename, breaks every helm upgrade. Override to
#     `bitnamilegacy/kubectl:1.33.4-debian-12-r0` which still exists.
#
# Future policies (Phase 6b/c): start with chart's policies/baseline
# samples (require resource limits, disallow privileged, require
# readOnlyRootFilesystem, etc.) in Audit mode first, flip to Enforce
# once we know what would break.
# =============================================================================

resource "kubernetes_namespace" "kyverno" {
  metadata {
    name = "kyverno"
  }
}

resource "helm_release" "kyverno" {
  name       = "kyverno"
  namespace  = kubernetes_namespace.kyverno.metadata[0].name
  repository = "https://kyverno.github.io/kyverno"
  chart      = "kyverno"
  version    = "3.3.5"

  # Chart's post-upgrade hook Jobs can take a while if any new admission
  # controller replica pulls a fresh image during the upgrade window.
  timeout = 900

  values = [
    yamlencode({
      # admissionController serves the ValidatingAdmissionWebhook that
      # the K8s API server calls on every CREATE/UPDATE. Single-pod
      # kyverno = cluster-wide blast radius for K8s admission. 3
      # replicas + Service round-robin = single-pod failure degrades
      # gracefully.
      admissionController = {
        replicas = 3
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
      }
      # Background / cleanup / reports controllers use leader election,
      # so multi-replica only adds standby cost without throughput gain.
      # Their failure modes are tolerable: gaps in PolicyReport
      # generation, missed CleanupPolicy firings, missed report
      # aggregations. None block live admission.
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

      # Kyverno chart 3.3.5 hardcodes `bitnami/kubectl:1.30.2` for two
      # post-upgrade hook Jobs (webhooks-cleanup + policy-reports-
      # cleanup). That image was removed from Docker Hub during the
      # Broadcom rename — pulls 404 indefinitely, helm upgrade hangs.
      # Override to bitnamilegacy/kubectl which still exists.
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
  ]
}

output "kyverno_policy_reports_hint" {
  value       = "kubectl get policyreport -A | head -20"
  description = "Once policies are defined, view their PolicyReport CRs (one per pod under each policy)"
}
