# =============================================================================
# Risk correlation — Prometheus recording rules that fuse the 4 security
# signal axes into per-workload risk scores. Closes StackRox parity gap #3.
#
# The model:
#   workload_risk_score = sum of {
#     vulnerability_factor    (HIGH+CRITICAL CVE count, scaled)
#     privileged_factor       (Trivy config audit: privileged / hostNetwork / hostPath)
#     runtime_detection_factor (Tetragon events from our 7 policies on this workload)
#     network_anomaly_factor   (Hubble denied flows TO this workload)
#   }
#
# Each factor is normalized so the dashboard query
# `topk(20, workload_risk_score)` ranks the most-at-risk workloads.
#
# Output metrics (consumed by the dashboard):
#   workload:vulnerability_factor:high_critical_count
#   workload:privileged_factor:configaudit_high
#   workload:runtime_detection_factor:tetragon_events_24h
#   workload:network_anomaly_factor:denied_flows_24h
#   workload:risk_score:total
#
# Labels carried through: namespace, workload (Deployment / StatefulSet name).
# =============================================================================

resource "kubectl_manifest" "security_recording_rules" {
  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PrometheusRule"
    metadata = {
      name      = "security-risk-correlation"
      namespace = "monitoring"
      labels = {
        # kube-prometheus-stack's Prometheus picks up PrometheusRules
        # carrying its release label.
        release = "kube-prometheus-stack"
        # Marker so we can grep these out of all rules.
        purpose = "stackrox-parity-risk-correlation"
      }
    }
    spec = {
      groups = [
        {
          name     = "security-risk-correlation"
          interval = "60s"
          rules = [
            # ----- Factor 1: vulnerability (namespace-level) -----
            # All sources agree on `namespace` label, so namespace is the
            # universal join key. Workload-level joins require label_replace
            # transforms (Trivy emits `workload`, Tetragon emits `pod`,
            # Hubble emits `destination_workload`) — defer to v2 of this
            # rule set.
            {
              record = "namespace:vulnerability_factor:high_critical"
              expr   = "sum by (exported_namespace) (trivy_image_vulnerabilities{severity=\"High\"}) + 3 * sum by (exported_namespace) (trivy_image_vulnerabilities{severity=\"Critical\"} or vector(0))"
            },

            # ----- Factor 2: privileged-pod configuration findings -----
            {
              record = "namespace:privileged_factor:configaudit_high"
              expr   = "sum by (exported_namespace) (trivy_resource_configaudits{severity=\"High\"})"
            },

            # ----- Factor 3: runtime detection activity (24h) -----
            # 2026-05-10 metric correction: tetragon_events_total is a generic
            # event counter (every PROCESS_EXEC across the cluster, firehose).
            # tetragon_policy_events_total is the PER-POLICY counter and only
            # fires for actual TracingPolicy matches — much smaller signal,
            # much more useful. The `policy` label carries the policy name.
            {
              record = "namespace:runtime_detection_factor:tetragon_events_24h"
              expr   = "sum by (exported_namespace) (increase(tetragon_policy_events_total{policy=~\"detect-.*\"}[24h]))"
            },

            # ----- Factor 4 (Hubble denied flows) deferred -----
            # The default Hubble metric set doesn't tag drops with workload
            # context — `hubble_drop_total` has only `protocol` and `reason`
            # labels, not source/destination workload. To attribute drops to
            # workloads we'd need to enable additional Hubble metric flags in
            # cilium.tf: `--metrics=drop:destinationContext=workload-name`.
            # Followup: add that flag and re-enable a network_anomaly factor.

            # ----- Combined risk score (per namespace) -----
            # Weights:
            #   vuln × 1      (already weights HIGH=1, CRITICAL=3)
            #   priv × 5      (a privileged finding outranks ~5 HIGH CVEs)
            #   runtime × 2   (runtime detections weighted between vuln and priv)
            #
            # Sum semantics via `sum by + or`: each factor produces series
            # keyed on exported_namespace; OR-unions them so namespaces
            # appearing in ANY factor survive; `sum by` then totals weighted
            # contributions per namespace.
            #
            # Caveat with `or vector(0)`: a scalar-OR was clobbering labels
            # to "no labels" — the entire union collapsed to a single
            # unlabeled aggregate. Replaced with same-label OR.
            {
              record = "namespace:risk_score:total"
              expr   = "sum by (exported_namespace) ( (namespace:vulnerability_factor:high_critical) or (5 * namespace:privileged_factor:configaudit_high) or (2 * namespace:runtime_detection_factor:tetragon_events_24h) )"
            },
          ]
        },
      ]
    }
  })

  depends_on = [
    helm_release.kube_prometheus_stack,
    kubectl_manifest.sm_tetragon,
    kubectl_manifest.sm_trivy_operator,
    kubectl_manifest.sm_hubble,
  ]
}
