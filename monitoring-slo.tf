# Phase #29: SLO multi-window, multi-burn-rate (MWMBR) alerts.
#
# Layered on top of the simpler Phase #26 alerts (monitoring-alerts.tf).
# Both stay — the threshold-and-for-duration alerts in Phase #26 catch
# coarse breaks ("service is down") while these MWMBR alerts catch
# error-budget burn rate ("service is healthy enough but consuming the
# budget faster than the SLO allows").
#
# Pattern reference: Google SRE Workbook, "Alerting on SLOs" chapter.
# Canonical 3-tier window/threshold matrix:
#
#   Severity   Long window   Short window   Burn rate   Budget exhausted in
#   ----------------------------------------------------------------------
#   critical   1h            5m             14.4x       ~2 hours
#   critical   6h            30m            6x          ~5 hours
#   warning    3d            6h             1x          ~30 days (full budget)
#
# Each alert requires BOTH the long AND short window to exceed the
# burn rate. Long-window agreement keeps it stable; short-window
# agreement keeps it recent. Without the AND, a recovered incident
# would keep paging on the long-window memory of the bad period.
#
# What "burn rate" means: error_rate / (1 - SLO_target). For a 95%
# SLO, the error budget is 0.05 (5% of calls); a burn rate of 14.4x
# means the current error rate is 0.72 (72% errors), which would
# exhaust the entire 30-day budget in 30d / 14.4 ≈ 2 days. That's why
# 14.4x is "fast burn / page now".
#
# Inline expressions (vs recording rules): keeping the math literal in
# each alert. Recording rules would be DRYer but obscure what each
# alert actually checks. For 6 alerts in two SLOs it's tractable;
# would refactor to recording rules at >2 SLOs per service.
#
# Metric assumptions:
#   rag_retrieve_duration_seconds_bucket   — Phase #24, le=2.5 exists
#   http_request_duration_seconds_bucket   — emitted by
#     prometheus_fastapi_instrumentator (Phase #14a auto-instrument);
#     includes handler= label for filtering /healthz, /metrics out.
# If the langgraph metric name differs in practice, the alert will
# simply never fire (no rows on either side) rather than crash —
# safe default for a lab.
#
# How to verify after apply:
#   kubectl -n monitoring get prometheusrule ai-lab-slo-alerts
#   kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090
#   open http://localhost:9090/alerts
#   # Use the /graph tab to plot any of the burn-rate expressions
#   # below — should be ~0 in a healthy lab.

resource "kubectl_manifest" "ai_lab_slo_alerts" {
  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PrometheusRule"
    metadata = {
      name      = "ai-lab-slo-alerts"
      namespace = "monitoring"
      labels = {
        app     = "ai-lab"
        slo     = "true"
        release = "kube-prometheus-stack"
      }
    }
    spec = {
      groups = [
        # =============================================================
        # SLO 1: rag-service /retrieve latency
        # Target: 95% of /retrieve calls complete in <= 2.5s
        # Window: rolling 30 days
        # Error budget: 5% (calls slower than 2.5s)
        # =============================================================
        # Why 2.5s: matches the dashboard's red threshold in Phase #25
        # and the simple alert's threshold in Phase #26. SLO target
        # numerically aligns with operator expectations on the board.
        {
          name     = "rag-service.slo.retrieve-latency"
          interval = "30s"
          rules = [
            {
              alert = "RagRetrieveLatencySLOFastBurn"
              # 1h * 5m windows, burn rate 14.4x
              # error_rate = 1 - (slow_calls / total_calls)
              expr = <<-EOT
                (
                  (1 - (sum(rate(rag_retrieve_duration_seconds_bucket{le="2.5"}[1h]))
                        / clamp_min(sum(rate(rag_retrieve_duration_seconds_count[1h])), 1e-9)))
                  > (14.4 * 0.05)
                )
                and
                (
                  (1 - (sum(rate(rag_retrieve_duration_seconds_bucket{le="2.5"}[5m]))
                        / clamp_min(sum(rate(rag_retrieve_duration_seconds_count[5m])), 1e-9)))
                  > (14.4 * 0.05)
                )
              EOT
              for  = "2m"
              labels = {
                severity   = "critical"
                service    = "rag-service"
                slo        = "retrieve-latency"
                burn_speed = "fast"
              }
              annotations = {
                summary     = "rag-service /retrieve latency SLO burning fast (2h to exhaust)"
                description = "More than 72% of /retrieve calls are exceeding 2.5s over the last hour AND last 5m. At this rate the 30-day error budget exhausts in ~2 hours. Check vllm-bge-m3 and vllm-bge-reranger pod status, GPU node availability, and the per-stage latency panel on the rag-service dashboard."
              }
            },
            {
              alert = "RagRetrieveLatencySLOMediumBurn"
              # 6h * 30m windows, burn rate 6x
              expr = <<-EOT
                (
                  (1 - (sum(rate(rag_retrieve_duration_seconds_bucket{le="2.5"}[6h]))
                        / clamp_min(sum(rate(rag_retrieve_duration_seconds_count[6h])), 1e-9)))
                  > (6 * 0.05)
                )
                and
                (
                  (1 - (sum(rate(rag_retrieve_duration_seconds_bucket{le="2.5"}[30m]))
                        / clamp_min(sum(rate(rag_retrieve_duration_seconds_count[30m])), 1e-9)))
                  > (6 * 0.05)
                )
              EOT
              for  = "5m"
              labels = {
                severity   = "critical"
                service    = "rag-service"
                slo        = "retrieve-latency"
                burn_speed = "medium"
              }
              annotations = {
                summary     = "rag-service /retrieve latency SLO burning at medium rate (~5h to exhaust)"
                description = "Sustained slow-call rate above 30%. Budget exhausts in ~5 hours at this rate. Likely capacity issue or partially-degraded reranker; check the per-stage latency panel for which stage owns the regression."
              }
            },
            {
              alert = "RagRetrieveLatencySLOSlowBurn"
              # 3d * 6h windows, burn rate 1x (consuming entire budget over 30d)
              expr = <<-EOT
                (
                  (1 - (sum(rate(rag_retrieve_duration_seconds_bucket{le="2.5"}[3d]))
                        / clamp_min(sum(rate(rag_retrieve_duration_seconds_count[3d])), 1e-9)))
                  > (1 * 0.05)
                )
                and
                (
                  (1 - (sum(rate(rag_retrieve_duration_seconds_bucket{le="2.5"}[6h]))
                        / clamp_min(sum(rate(rag_retrieve_duration_seconds_count[6h])), 1e-9)))
                  > (1 * 0.05)
                )
              EOT
              for  = "1h"
              labels = {
                severity   = "warning"
                service    = "rag-service"
                slo        = "retrieve-latency"
                burn_speed = "slow"
              }
              annotations = {
                summary     = "rag-service /retrieve latency SLO error budget on track to fully exhaust"
                description = "Slow-call rate has averaged above 5% over the last 3 days AND last 6 hours. At 1x burn the budget exhausts in 30 days — i.e., we're spending the budget exactly as fast as it accrues. Time to investigate the underlying trend (e.g., document corpus growth slowing Qdrant query, or chunk size drift increasing rerank work)."
              }
            },
          ]
        },

        # =============================================================
        # SLO 2: langgraph-service end-to-end latency
        # Target: 95% of /invoke calls complete in <= 10s
        # Window: rolling 30 days
        # Error budget: 5%
        # =============================================================
        # Why 10s: /invoke fans out through 18 graph nodes including
        # multiple LLM calls (classify, retrieve, execute, reflect,
        # judge, safety_output) so the SLO target is much looser than
        # rag-service. Adjust as the workload matures.
        # The histogram is from prometheus_fastapi_instrumentator's
        # default exporter; bucket le="10.0" exists in the default
        # bucket set (.005, .01, .025, .05, .075, .1, .25, .5, .75,
        # 1, 2.5, 5, 7.5, 10, +Inf).
        # Filtered to handler="/invoke" so /healthz, /metrics, /readyz,
        # and chat-ui's session-mgmt endpoints don't dilute the SLO.
        {
          name     = "langgraph-service.slo.invoke-latency"
          interval = "30s"
          rules = [
            {
              alert = "LanggraphInvokeLatencySLOFastBurn"
              expr  = <<-EOT
                (
                  (1 - (sum(rate(http_request_duration_seconds_bucket{job="langgraph-service",handler="/invoke",le="10.0"}[1h]))
                        / clamp_min(sum(rate(http_request_duration_seconds_count{job="langgraph-service",handler="/invoke"}[1h])), 1e-9)))
                  > (14.4 * 0.05)
                )
                and
                (
                  (1 - (sum(rate(http_request_duration_seconds_bucket{job="langgraph-service",handler="/invoke",le="10.0"}[5m]))
                        / clamp_min(sum(rate(http_request_duration_seconds_count{job="langgraph-service",handler="/invoke"}[5m])), 1e-9)))
                  > (14.4 * 0.05)
                )
              EOT
              for   = "2m"
              labels = {
                severity   = "critical"
                service    = "langgraph-service"
                slo        = "invoke-latency"
                burn_speed = "fast"
              }
              annotations = {
                summary     = "langgraph-service /invoke latency SLO burning fast (2h to exhaust)"
                description = "More than 72% of /invoke calls exceed 10s over the last hour AND last 5m. Check the langgraph-service-overview dashboard P95 latency by node panel — a single slow node (most often execute or reflect) dominates the tail. Also check rag-service since /invoke depends on it."
              }
            },
            {
              alert = "LanggraphInvokeLatencySLOMediumBurn"
              expr  = <<-EOT
                (
                  (1 - (sum(rate(http_request_duration_seconds_bucket{job="langgraph-service",handler="/invoke",le="10.0"}[6h]))
                        / clamp_min(sum(rate(http_request_duration_seconds_count{job="langgraph-service",handler="/invoke"}[6h])), 1e-9)))
                  > (6 * 0.05)
                )
                and
                (
                  (1 - (sum(rate(http_request_duration_seconds_bucket{job="langgraph-service",handler="/invoke",le="10.0"}[30m]))
                        / clamp_min(sum(rate(http_request_duration_seconds_count{job="langgraph-service",handler="/invoke"}[30m])), 1e-9)))
                  > (6 * 0.05)
                )
              EOT
              for   = "5m"
              labels = {
                severity   = "critical"
                service    = "langgraph-service"
                slo        = "invoke-latency"
                burn_speed = "medium"
              }
              annotations = {
                summary     = "langgraph-service /invoke latency SLO burning at medium rate (~5h to exhaust)"
                description = "Sustained slow-call rate above 30%. Likely a partially-degraded upstream (vLLM cold-start, rag-service rerank flap, Bedrock throttling). Cross-reference with the rag-service SLO alerts — if both are firing, root cause is downstream of langgraph."
              }
            },
            {
              alert = "LanggraphInvokeLatencySLOSlowBurn"
              expr  = <<-EOT
                (
                  (1 - (sum(rate(http_request_duration_seconds_bucket{job="langgraph-service",handler="/invoke",le="10.0"}[3d]))
                        / clamp_min(sum(rate(http_request_duration_seconds_count{job="langgraph-service",handler="/invoke"}[3d])), 1e-9)))
                  > (1 * 0.05)
                )
                and
                (
                  (1 - (sum(rate(http_request_duration_seconds_bucket{job="langgraph-service",handler="/invoke",le="10.0"}[6h]))
                        / clamp_min(sum(rate(http_request_duration_seconds_count{job="langgraph-service",handler="/invoke"}[6h])), 1e-9)))
                  > (1 * 0.05)
                )
              EOT
              for   = "1h"
              labels = {
                severity   = "warning"
                service    = "langgraph-service"
                slo        = "invoke-latency"
                burn_speed = "slow"
              }
              annotations = {
                summary     = "langgraph-service /invoke latency SLO error budget on track to fully exhaust"
                description = "Slow-call rate above 5% over 3 days AND 6 hours. The trend is the problem — investigate corpus growth, prompt drift toward longer-tail content, or model upgrades that changed token-throughput characteristics."
              }
            },
          ]
        },
      ]
    }
  })

  depends_on = [helm_release.kube_prometheus_stack]
}
