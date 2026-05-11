# =============================================================================
# Grafana "Cluster Security Posture" dashboard — the StackRox single-pane.
#
# Closes StackRox parity gap #2: one dashboard joining all 6 security signal
# sources we just wired into Prometheus. Lands as a ConfigMap with the
# `grafana_dashboard: "1"` label so kube-prometheus-stack's grafana-sidecar
# auto-discovers and provisions it on next reconcile (~30s after apply).
#
# Panel layout (12-col grid):
#   Row 1 (KPI tiles, 6×3 each):
#     - Total HIGH+CRITICAL CVEs across cluster
#     - Kyverno admission denials (24h)
#     - Tetragon runtime alerts by policy (24h)
#     - Cilium network policy denies (24h)
#   Row 2 (timeseries, 12×6):
#     - Vulnerability count over time, stacked by severity
#   Row 3 (timeseries split, 6×6 each):
#     - Tetragon events by policy_name
#     - Hubble dropped flows by verdict reason
#   Row 4 (table, 12×6):
#     - Top 10 most-vulnerable images
#
# This is the operational equivalent of the StackRox dashboard. Add panels
# for additional StackRox capabilities (compliance frameworks, image risk
# scoring) once we have the underlying recording rules.
# =============================================================================

locals {
  security_dashboard_json = jsonencode({
    title         = "Cluster Security Posture"
    uid           = "cluster-security-posture"
    schemaVersion = 39
    version       = 1
    refresh       = "30s"
    time          = { from = "now-24h", to = "now" }
    timezone      = ""
    tags          = ["security", "stackrox-parity"]
    panels = [
      # ============ Row 1 — KPI tiles ============
      {
        id    = 1
        title = "HIGH+CRITICAL CVEs in cluster"
        type  = "stat"
        gridPos = { h = 4, w = 6, x = 0, y = 0 }
        targets = [{
          expr    = "sum(trivy_image_vulnerabilities{severity=~\"High|Critical\"})"
          refId   = "A"
          instant = true
        }]
        fieldConfig = {
          defaults = {
            color = { mode = "thresholds" }
            thresholds = {
              mode = "absolute"
              steps = [
                { color = "green", value = null },
                { color = "yellow", value = 1 },
                { color = "red", value = 10 },
              ]
            }
            unit = "short"
          }
        }
        options = {
          colorMode   = "background"
          graphMode   = "area"
          reduceOptions = { calcs = ["lastNotNull"], fields = "", values = false }
        }
      },
      {
        id    = 2
        title = "Kyverno admission DENIALS (24h)"
        type  = "stat"
        gridPos = { h = 4, w = 6, x = 6, y = 0 }
        targets = [{
          expr    = "sum(increase(kyverno_admission_requests_total{allowed=\"false\"}[24h]))"
          refId   = "A"
          instant = true
        }]
        fieldConfig = {
          defaults = {
            color = { mode = "thresholds" }
            thresholds = {
              mode = "absolute"
              steps = [
                { color = "green", value = null },
                { color = "yellow", value = 1 },
                { color = "red", value = 20 },
              ]
            }
            unit = "short"
          }
        }
        options = {
          colorMode   = "background"
          graphMode   = "area"
          reduceOptions = { calcs = ["lastNotNull"], fields = "", values = false }
        }
      },
      {
        id    = 3
        title = "Tetragon runtime alerts (24h)"
        type  = "stat"
        gridPos = { h = 4, w = 6, x = 0, y = 4 }
        targets = [{
          # tetragon_events_total counts every event; restrict to our 7 policies
          expr    = "sum(increase(tetragon_events_total{policy=~\"detect-.*\"}[24h]))"
          refId   = "A"
          instant = true
        }]
        fieldConfig = {
          defaults = {
            color = { mode = "thresholds" }
            thresholds = {
              mode = "absolute"
              steps = [
                { color = "green", value = null },
                { color = "yellow", value = 1 },
                { color = "red", value = 100 },
              ]
            }
            unit = "short"
          }
        }
        options = {
          colorMode   = "background"
          graphMode   = "area"
          reduceOptions = { calcs = ["lastNotNull"], fields = "", values = false }
        }
      },
      {
        id    = 4
        title = "Cilium policy DENIES (24h)"
        type  = "stat"
        gridPos = { h = 4, w = 6, x = 6, y = 4 }
        targets = [{
          expr    = "sum(increase(cilium_policy_verdict_total{action=\"deny\"}[24h]))"
          refId   = "A"
          instant = true
        }]
        fieldConfig = {
          defaults = {
            color = { mode = "thresholds" }
            thresholds = {
              mode = "absolute"
              steps = [
                { color = "green", value = null },
                { color = "yellow", value = 10 },
                { color = "red", value = 1000 },
              ]
            }
            unit = "short"
          }
        }
        options = {
          colorMode   = "background"
          graphMode   = "area"
          reduceOptions = { calcs = ["lastNotNull"], fields = "", values = false }
        }
      },

      # ============ Row 2 — Vulnerability stack ============
      {
        id    = 5
        title = "Vulnerabilities by severity (cluster-wide)"
        type  = "timeseries"
        gridPos = { h = 8, w = 24, x = 0, y = 8 }
        targets = [
          {
            expr         = "sum by (severity) (trivy_image_vulnerabilities)"
            refId        = "A"
            legendFormat = "{{severity}}"
          },
        ]
        fieldConfig = {
          defaults = {
            color = { mode = "palette-classic" }
            custom = {
              drawStyle      = "line"
              fillOpacity    = 30
              lineWidth      = 2
              stacking       = { mode = "normal", group = "A" }
              showPoints     = "never"
            }
          }
        }
      },

      # ============ Row 3 — Tetragon policy hits + Hubble drops ============
      {
        id    = 6
        title = "Tetragon detections by policy"
        type  = "timeseries"
        gridPos = { h = 8, w = 12, x = 0, y = 16 }
        targets = [{
          expr         = "sum by (policy) (rate(tetragon_events_total{policy=~\"detect-.*\"}[5m]))"
          refId        = "A"
          legendFormat = "{{policy}}"
        }]
        fieldConfig = {
          defaults = {
            color = { mode = "palette-classic" }
            custom = {
              drawStyle   = "line"
              fillOpacity = 10
              lineWidth   = 2
              showPoints  = "never"
            }
          }
        }
      },
      {
        id    = 7
        title = "Hubble dropped flows by reason"
        type  = "timeseries"
        gridPos = { h = 8, w = 12, x = 12, y = 16 }
        targets = [{
          expr         = "sum by (reason) (rate(hubble_drop_total[5m]))"
          refId        = "A"
          legendFormat = "{{reason}}"
        }]
        fieldConfig = {
          defaults = {
            color = { mode = "palette-classic" }
            custom = {
              drawStyle   = "bars"
              fillOpacity = 60
              lineWidth   = 1
              stacking    = { mode = "normal", group = "A" }
              showPoints  = "never"
            }
          }
        }
      },

      # ============ Row 4 — Risk-correlated top workloads (StackRox-style) ============
      #
      # This is the "killer panel" — the workload:risk_score:total recording
      # rule fuses vulnerability × privilege × runtime × network signals into
      # a single per-workload number. Sorting descending gives the operator
      # the same prioritization StackRox does.
      {
        id    = 9
        title = "Risk-ranked namespaces (composite score: vuln + priv + runtime)"
        type  = "table"
        gridPos = { h = 10, w = 24, x = 0, y = 24 }
        targets = [{
          expr    = "topk(20, namespace:risk_score:total)"
          refId   = "A"
          format  = "table"
          instant = true
        }]
        transformations = [{
          id      = "organize"
          options = {
            excludeByName = { Time = true, __name__ = true }
            renameByName = {
              Value     = "Risk score"
              namespace = "Namespace"
            }
          }
        }]
        fieldConfig = {
          defaults = {
            color = { mode = "thresholds" }
            thresholds = {
              mode  = "absolute"
              steps = [
                { color = "green", value = null },
                { color = "yellow", value = 5 },
                { color = "orange", value = 25 },
                { color = "red", value = 100 },
              ]
            }
            custom = { cellOptions = { type = "color-background" } }
          }
          overrides = [{
            matcher    = { id = "byName", options = "Risk score" }
            properties = [{ id = "custom.width", value = 120 }]
          }]
        }
      },

      # ============ Row 5a — Top workloads receiving denied traffic ============
      {
        id    = 10
        title = "Top 15 workloads receiving denied network traffic (1h)"
        type  = "table"
        gridPos = { h = 8, w = 12, x = 0, y = 34 }
        targets = [{
          expr    = "topk(15, sum by (destination, reason) (increase(hubble_drop_total[1h])))"
          refId   = "A"
          format  = "table"
          instant = true
        }]
        transformations = [{
          id      = "organize"
          options = {
            excludeByName = { Time = true, __name__ = true }
            renameByName = {
              Value       = "Denied flows (1h)"
              destination = "Destination workload"
              reason      = "Reason"
            }
          }
        }]
      },

      # ============ Row 5b — Top vulnerable images ============
      {
        id    = 8
        title = "Top 10 most-vulnerable images (HIGH+CRITICAL)"
        type  = "table"
        gridPos = { h = 8, w = 12, x = 12, y = 34 }
        targets = [{
          expr    = "topk(10, sum by (image_repository, image_tag) (trivy_image_vulnerabilities{severity=~\"High|Critical\"}))"
          refId   = "A"
          format  = "table"
          instant = true
        }]
        transformations = [{
          id      = "organize"
          options = {
            excludeByName = { Time = true }
            renameByName  = { Value = "HIGH+CRITICAL vulnerabilities" }
          }
        }]
      },
    ]
  })
}

resource "kubectl_manifest" "grafana_security_dashboard" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      name      = "grafana-dashboard-cluster-security-posture"
      namespace = "monitoring"
      labels = {
        # This label is what kube-prometheus-stack's grafana-sidecar
        # watches for. Set in the chart's grafana.sidecar.dashboards.label.
        grafana_dashboard = "1"
      }
    }
    data = {
      "cluster-security-posture.json" = local.security_dashboard_json
    }
  })

  depends_on = [
    helm_release.kube_prometheus_stack,
    kubectl_manifest.sm_tetragon,
    kubectl_manifest.sm_trivy_operator,
    kubectl_manifest.sm_kyverno,
    kubectl_manifest.sm_hubble,
  ]
}

output "security_dashboard_url" {
  value       = "https://grafana.${var.domain}/d/cluster-security-posture/cluster-security-posture"
  description = "StackRox-equivalent unified security posture dashboard"
}
