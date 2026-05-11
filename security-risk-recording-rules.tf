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
            # exported_namespace=~".+" filters out series without the label
            # entirely (PromQL != "" only matches present-and-empty, not absent).
            {
              record = "namespace:vulnerability_factor:high_critical"
              expr   = "sum by (exported_namespace) (trivy_image_vulnerabilities{severity=\"High\",exported_namespace=~\".+\"}) + 3 * sum by (exported_namespace) (trivy_image_vulnerabilities{severity=\"Critical\",exported_namespace=~\".+\"} or vector(0))"
            },

            # ----- Factor 2: privileged-pod configuration findings -----
            # Filter excludes cluster-scoped resources (ClusterRole,
            # ClusterRoleBinding, etc.) which have no exported_namespace —
            # they previously rolled into an unlabeled aggregate on the
            # dashboard. Cluster-scoped configaudit findings will get their
            # own panel in v2.
            {
              record = "namespace:privileged_factor:configaudit_high"
              expr   = "sum by (exported_namespace) (trivy_resource_configaudits{severity=\"High\",exported_namespace=~\".+\"})"
            },

            # ----- Factor 3: runtime detection activity (24h) -----
            # 2026-05-10 metric correction: tetragon_events_total is a generic
            # event counter (every PROCESS_EXEC across the cluster, firehose).
            # tetragon_policy_events_total is the PER-POLICY counter and only
            # fires for actual TracingPolicy matches — much smaller signal,
            # much more useful. The `policy` label carries the policy name.
            {
              record = "namespace:runtime_detection_factor:tetragon_events_24h"
              expr   = "sum by (exported_namespace) (increase(tetragon_policy_events_total{policy=~\"detect-.*\",exported_namespace=~\".+\"}[24h]))"
            },

            # ----- Factor 4: network anomaly (denied flows TO this namespace) -----
            # Enabled 2026-05-10 once Hubble's drop metric was extended with
            # `labelsContext=source_workload,source_namespace,destination_workload,destination_namespace`
            # in cilium.tf. hubble_drop_total now carries destination_namespace.
            #
            # Semantics: "how much traffic is being blocked from REACHING this
            # namespace." High count = either an attack surface (something
            # repeatedly probing us, getting policy-denied) OR a misconfigured
            # peer trying to reach us. Both warrant attention.
            #
            # Re-keyed with label_replace so the output label is `exported_namespace`,
            # matching the other 3 factors and enabling the sum-by aggregation
            # in namespace:risk_score:total.
            {
              record = "namespace:network_anomaly_factor:denied_flows_24h"
              expr   = "label_replace(sum by (destination_namespace) (increase(hubble_drop_total{destination_namespace=~\".+\"}[24h])), \"exported_namespace\", \"$1\", \"destination_namespace\", \"(.*)\")"
            },

            # ----- Combined risk score (per namespace) -----
            # Weights:
            #   vuln × 1      (already weights HIGH=1, CRITICAL=3)
            #   priv × 5      (a privileged finding outranks ~5 HIGH CVEs)
            #   runtime × 2   (runtime detections weighted between vuln and priv)
            #   network × 0.1 (denied flows are noisy from health-check polling;
            #                  small weight prevents drowning out real signal)
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
              expr   = "sum by (exported_namespace) ( (namespace:vulnerability_factor:high_critical) or (5 * namespace:privileged_factor:configaudit_high) or (2 * namespace:runtime_detection_factor:tetragon_events_24h) or (0.1 * namespace:network_anomaly_factor:denied_flows_24h) )"
            },

            # ----- WORKLOAD-LEVEL FACTORS + RISK SCORE -----
            # Same model as namespace-level but keyed on (exported_namespace,
            # workload). Trivy, Tetragon, and Hubble all emit a `workload`
            # (or destination_workload) label; we standardize to `workload`
            # via label_replace where needed.
            #
            # v3 (2026-05-10): added KSM-based pod-owner bridge for Tetragon.
            # Tetragon emits `workload` as the StatefulSet base name (e.g.
            # `langgraph-redis-ha-node` for pod `langgraph-redis-ha-node-0`),
            # but for Deployments emits the ReplicaSet name. Joining with
            # kube_pod_info gets the canonical "owner workload" name that
            # Trivy and Hubble agree on. Best-effort — workloads with no
            # KSM info still flow through with their original Tetragon name.

            {
              record = "workload:vulnerability_factor:high_critical"
              expr   = "sum by (exported_namespace, workload) (trivy_image_vulnerabilities{severity=\"High\",exported_namespace=~\".+\",workload=~\".+\"}) + 3 * sum by (exported_namespace, workload) (trivy_image_vulnerabilities{severity=\"Critical\",exported_namespace=~\".+\",workload=~\".+\"} or vector(0))"
            },
            {
              # Trivy's configaudit reports use `resource_name` (literal K8s
              # object name like 'argo-rollouts-859bbd5576'); strip trailing
              # `-<hex>` to approximate the Deployment name. The output regex
              # has a fallback group so resource_names WITHOUT a hash suffix
              # (StatefulSet/DaemonSet names) pass through unchanged. The
              # `workload=~".+"` filter at the end drops series where the
              # label_replace failed (cluster-scoped resources with no clear
              # workload identity).
              record = "workload:privileged_factor:configaudit_high"
              expr   = "label_replace(sum by (exported_namespace, resource_name) (trivy_resource_configaudits{severity=\"High\",exported_namespace=~\".+\",resource_name=~\".+\"}), \"workload\", \"$1\", \"resource_name\", \"(.+?)(?:-[a-f0-9]{5,10})?$\")"
            },
            {
              record = "workload:runtime_detection_factor:tetragon_events_24h"
              expr   = "sum by (exported_namespace, workload) (increase(tetragon_policy_events_total{policy=~\"detect-.*\",exported_namespace=~\".+\",workload=~\".+\"}[24h]))"
            },
            {
              # Hubble drop's destination_workload is already at Deployment
              # granularity; rename label so it aligns with the other 3.
              record = "workload:network_anomaly_factor:denied_flows_24h"
              expr   = "label_replace(label_replace(sum by (destination_namespace, destination_workload) (increase(hubble_drop_total{destination_namespace=~\".+\",destination_workload=~\".+\"}[24h])), \"exported_namespace\", \"$1\", \"destination_namespace\", \"(.*)\"), \"workload\", \"$1\", \"destination_workload\", \"(.*)\")"
            },
            {
              # Combined workload-level risk score. Same weights as the
              # namespace-level rule for direct comparison.
              #
              # Cross-source label matching is BEST-EFFORT — Trivy emits
              # ReplicaSet names with hex suffix (stripped above), Tetragon
              # emits the controller base name, Hubble emits whatever the
              # Cilium identity resolver returns. The label_replace above
              # gives us the same `(exported_namespace, workload)` shape on
              # all 4 factors. Perfect 1:1 cross-source matching would need
              # a custom bridge query joining each factor through
              # `kube_pod_info * on(pod, namespace) group_left(...)` —
              # deferred to v4 because it requires reshaping each factor to
              # emit pod labels first (which Trivy configaudit doesn't).
              record = "workload:risk_score:total"
              expr   = "sum by (exported_namespace, workload) ( (workload:vulnerability_factor:high_critical) or (5 * workload:privileged_factor:configaudit_high) or (2 * workload:runtime_detection_factor:tetragon_events_24h) or (0.1 * workload:network_anomaly_factor:denied_flows_24h) )"
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
