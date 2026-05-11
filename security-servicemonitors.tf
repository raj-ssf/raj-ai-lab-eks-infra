# =============================================================================
# Security-stack ServiceMonitors.
#
# kube-prometheus-stack auto-discovers ServiceMonitor CRs, but each of the
# security tools (Tetragon, Trivy, Kyverno, Hubble, Cilium-envoy) ships
# with metrics endpoints but no ServiceMonitor by default. Without these,
# every "security dashboard" query returns empty.
#
# This file closes StackRox parity gap #2 (no unified dashboard): wires
# all six security signal sources into Prometheus so a Grafana dashboard
# can join across them.
#
# Source → Prometheus mapping:
#   tetragon                  → tetragon_events_total{policy=…}, tetragon_msg_op_total
#   tetragon-operator         → controller_runtime_reconcile_*
#   trivy-operator            → trivy_image_vulnerabilities{severity=…}, trivy_*_total
#   kyverno-svc-metrics       → kyverno_policy_results_total, kyverno_admission_requests_total
#   hubble-metrics            → hubble_flows_processed_total{verdict=…}, hubble_drop_total
#   cilium-envoy              → envoy_cluster_*, envoy_listener_*
# =============================================================================

resource "kubectl_manifest" "sm_tetragon" {
  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      name      = "tetragon"
      namespace = "monitoring"
      labels    = { release = "kube-prometheus-stack" }
    }
    spec = {
      namespaceSelector = { matchNames = ["tetragon"] }
      selector = {
        matchLabels = { "app.kubernetes.io/name" = "tetragon" }
      }
      endpoints = [{
        port     = "metrics"
        interval = "30s"
        path     = "/metrics"
      }]
    }
  })

  depends_on = [helm_release.tetragon, helm_release.kube_prometheus_stack]
}

resource "kubectl_manifest" "sm_tetragon_operator" {
  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      name      = "tetragon-operator"
      namespace = "monitoring"
      labels    = { release = "kube-prometheus-stack" }
    }
    spec = {
      namespaceSelector = { matchNames = ["tetragon"] }
      selector = {
        matchLabels = { "app.kubernetes.io/name" = "tetragon-operator" }
      }
      endpoints = [{
        port     = "metrics"
        interval = "30s"
        path     = "/metrics"
      }]
    }
  })

  depends_on = [helm_release.tetragon, helm_release.kube_prometheus_stack]
}

resource "kubectl_manifest" "sm_trivy_operator" {
  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      name      = "trivy-operator"
      namespace = "monitoring"
      labels    = { release = "kube-prometheus-stack" }
    }
    spec = {
      namespaceSelector = { matchNames = ["trivy-system"] }
      selector = {
        matchLabels = { "app.kubernetes.io/name" = "trivy-operator" }
      }
      endpoints = [{
        # trivy-operator Service is headless (clusterIP: None) with port 80
        # mapped to targetPort `metrics`. Headless Services don't do port
        # translation — clients connect to pod IPs on the actual container
        # port. Prom-operator's `port: <name>` would 80→8080 misroute, so
        # specify the real container port directly.
        targetPort = 8080
        interval   = "60s" # Trivy emits aggregate rollups, 60s is plenty
        path       = "/metrics"
      }]
    }
  })

  depends_on = [helm_release.trivy_operator, helm_release.kube_prometheus_stack]
}

resource "kubectl_manifest" "sm_kyverno" {
  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      name      = "kyverno"
      namespace = "monitoring"
      labels    = { release = "kube-prometheus-stack" }
    }
    spec = {
      namespaceSelector = { matchNames = ["kyverno"] }
      selector = {
        # Kyverno's metrics service is `kyverno-svc-metrics` —
        # different from `kyverno-svc` (the admission webhook).
        matchLabels = {
          "app.kubernetes.io/component" = "kyverno"
          "app.kubernetes.io/instance"  = "kyverno"
        }
      }
      endpoints = [{
        port     = "metrics-port"
        interval = "30s"
        path     = "/metrics"
      }]
    }
  })

  depends_on = [helm_release.kyverno, helm_release.kube_prometheus_stack]
}

resource "kubectl_manifest" "sm_hubble" {
  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      name      = "hubble"
      namespace = "monitoring"
      labels    = { release = "kube-prometheus-stack" }
    }
    spec = {
      namespaceSelector = { matchNames = ["kube-system"] }
      selector = {
        matchLabels = { "k8s-app" = "hubble" }
      }
      endpoints = [{
        port     = "hubble-metrics"
        interval = "30s"
        path     = "/metrics"
      }]
    }
  })

  depends_on = [helm_release.cilium, helm_release.kube_prometheus_stack]
}

resource "kubectl_manifest" "sm_cilium_envoy" {
  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      name      = "cilium-envoy"
      namespace = "monitoring"
      labels    = { release = "kube-prometheus-stack" }
    }
    spec = {
      namespaceSelector = { matchNames = ["kube-system"] }
      selector = {
        matchLabels = { "k8s-app" = "cilium-envoy" }
      }
      endpoints = [{
        port     = "envoy-metrics"
        interval = "30s"
        path     = "/metrics"
      }]
    }
  })

  depends_on = [helm_release.cilium, helm_release.kube_prometheus_stack]
}
