# =============================================================================
# Phase 5d: Trivy Operator — automated CVE / config / RBAC / secrets scanning.
#
# Trivy Operator continuously scans the cluster and produces CRDs:
#   - VulnerabilityReport     CVEs in container images
#   - ConfigAuditReport       K8s manifest misconfigs (pod security,
#                             missing limits, privileged containers)
#   - ExposedSecretReport     leaked secrets in container filesystems
#   - RbacAssessmentReport    overpermissive ClusterRoleBindings
#   - InfraAssessmentReport   node-level CIS benchmark findings
#
# Trade-offs vs alternatives:
#   - vs Kyverno      Different layer. Kyverno blocks/mutates at
#                     admission (preventive). Trivy scans existing
#                     state (detective). Both belong in a complete
#                     security posture; Kyverno is a future phase.
#   - vs ECR scanning AWS ECR's own scan-on-push (already enabled
#                     in alb-controller.tf etc.) covers ECR images.
#                     Trivy covers EVERYTHING — Bitnami images,
#                     Cilium images, public registries — anywhere
#                     ECR's per-account scope doesn't reach.
#   - vs Falco        Different scope. Falco is runtime detection
#                     (we have Tetragon for that). Trivy is static
#                     image analysis.
#
# Storage: VulnerabilityReports are stored as CRs in each scanned
# pod's namespace. Prometheus-adapter / kube-state-metrics can surface
# them as metrics (trivy_image_vulnerabilities_total), and Grafana
# can build a "CVE pressure" dashboard from those.
# =============================================================================

resource "kubernetes_namespace" "trivy_system" {
  metadata {
    name = "trivy-system"
  }
}

resource "helm_release" "trivy_operator" {
  name       = "trivy-operator"
  namespace  = kubernetes_namespace.trivy_system.metadata[0].name
  repository = "https://aquasecurity.github.io/helm-charts/"
  chart      = "trivy-operator"
  # 2026-05-10: bumped chart 0.24.1 → 0.32.1 (app 0.22.0 → 0.30.1) to fix
  # vulnerability scan jobs failing with "unrecognized scan job condition:
  # FailureTarget / SuccessCriteriaMet". Newer Kubernetes Job API added
  # those condition types; trivy-operator 0.22.0 was unaware and the
  # reconciler errored on every scan attempt. Result: zero
  # vulnerabilityreports CRs ever produced, which left the
  # namespace:vulnerability_factor:high_critical recording rule (StackRox
  # parity gap #3) empty. Multiple intervening releases also include
  # config audit + RBAC scan fixes worth picking up.
  # Bump cadence: check https://github.com/aquasecurity/trivy-operator/releases
  # for CRD schema changes before upgrading.
  version = "0.32.1"

  values = [
    yamlencode({
      # Standalone mode — each scan Job downloads the vuln DB itself.
      # Slightly more bandwidth than ClientServer (which centralizes
      # the DB on a trivy-server pod) but simpler config; fine at lab
      # scale (~20 unique images).
      trivy = {
        ignoreUnfixed = false
        severity      = "MEDIUM,HIGH,CRITICAL"
      }

      # Operator: 1 replica is fine; KEDA-style HA isn't needed
      # because operator failure just pauses scan scheduling, doesn't
      # affect cluster traffic.
      operator = {
        replicas = 1
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }

        # Scan every workload image. Disable specific scanner types
        # later if noise is too high.
        vulnerabilityScannerEnabled        = true
        configAuditScannerEnabled          = true
        rbacAssessmentScannerEnabled       = true
        infraAssessmentScannerEnabled      = true
        exposedSecretScannerEnabled        = true
        clusterComplianceEnabled           = true

        # Scan job interval + concurrency. Default 168h (= weekly)
        # is too lax for a dev lab; bump to 24h. concurrent=10
        # caps simultaneous scan jobs to avoid swamping nodes.
        scanJobsConcurrentLimit = 10
      }

      # ServiceMonitor for trivy-operator's /metrics endpoint —
      # surfaces trivy_image_vulnerabilities_count_*, trivy_role_*,
      # etc. to kube-prometheus-stack for alerting on "new CRITICAL
      # CVE detected" patterns.
      serviceMonitor = {
        enabled = true
        labels = {
          release = "kube-prometheus-stack"
        }
      }
    })
  ]

  depends_on = [
    module.eks,
    helm_release.kube_prometheus_stack,
  ]
}

output "trivy_vuln_reports_hint" {
  value       = "kubectl get vulnerabilityreports -A"
  description = "List all VulnerabilityReport CRs (one per scanned image per namespace)"
}
