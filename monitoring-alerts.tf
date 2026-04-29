# Phase #26: PrometheusRule alerts for the AI lab services.
#
# kube-prometheus-stack is configured with *NilUsesHelmValues = false
# (see prometheus-stack.tf), so Prometheus picks up any
# PrometheusRule cluster-wide regardless of labels. The release label
# below is kept anyway as a future-proofing convention that matches
# langgraph-service's ServiceMonitor.
#
# Alertmanager is intentionally disabled in the lab (no receivers
# wired up — see prometheus-stack.tf:227). These rules therefore
# DON'T page anyone; they surface in:
#   - Prometheus UI: /alerts at https://prometheus.${var.domain}
#     (or via port-forward to the prometheus pod)
#   - Grafana UI: Alerts → Alert rules (the sidecar bridges
#     PrometheusRule CRs into Grafana's unified alerting view)
# That's still useful — an operator can quickly see "is anything
# firing right now?" without scanning every dashboard panel. To
# convert these into pageable alerts, enable alertmanager in
# prometheus-stack.tf and wire receivers (Slack/PagerDuty/etc.).
#
# Rule design principles:
#   - All `for:` durations >= 5m to absorb transient spikes (cold
#     starts, scrape gaps) without crying wolf.
#   - Labels carry severity (warning|critical) and service so a
#     future Alertmanager route can split critical → page,
#     warning → Slack channel.
#   - Annotations include both a summary (one-line) and a
#     description with the runbook-style "what to check next".

resource "kubectl_manifest" "ai_lab_alerts" {
  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PrometheusRule"
    metadata = {
      name      = "ai-lab-alerts"
      namespace = "monitoring"
      labels = {
        app     = "ai-lab"
        release = "kube-prometheus-stack"
      }
    }
    spec = {
      groups = [
        # -------------------------------------------------------------
        # rag-service alerts
        # -------------------------------------------------------------
        {
          name     = "rag-service.rules"
          interval = "30s"
          rules = [
            {
              alert = "RagServiceDown"
              expr  = "absent_over_time(up{job=\"rag-service\"}[5m]) == 1 or sum(up{job=\"rag-service\"}) == 0"
              for   = "5m"
              labels = {
                severity = "critical"
                service  = "rag-service"
              }
              annotations = {
                summary     = "rag-service is not being scraped or all replicas are down"
                description = "Prometheus has no healthy targets for job=rag-service for 5m. Check kubectl -n rag get pods, recent ArgoCD syncs, and the ServiceMonitor in rag-service/base/servicemonitor.yaml."
              }
            },
            {
              alert = "RagRetrieveLatencyHigh"
              expr  = "histogram_quantile(0.95, sum by (le) (rate(rag_retrieve_duration_seconds_bucket[10m]))) > 2.5"
              for   = "10m"
              labels = {
                severity = "warning"
                service  = "rag-service"
              }
              annotations = {
                summary     = "/retrieve P95 above 2.5s for 10m"
                description = "End-to-end /retrieve P95 has exceeded the dashboard's red threshold for 10m. Use the rag-service-overview dashboard's per-stage panel to attribute: embed (vllm-bge-m3 cold), qdrant (heavy session), or rerank (TEI under-provisioned)."
              }
            },
            {
              alert = "RagRerankerFailOpen"
              expr  = "sum(rate(rag_reranker_used_total{used=\"false\"}[10m])) / clamp_min(sum(rate(rag_reranker_used_total[10m])), 1e-9) > 0.05"
              for   = "10m"
              labels = {
                severity = "warning"
                service  = "rag-service"
              }
              annotations = {
                summary     = "Reranker falling back to dense ordering >5% of /retrieve calls"
                description = "rerank_chunks is silently failing open (httpx.HTTPError or 5xx from TEI bge-reranker) for >5% of calls over 10m. Retrieval quality is degraded but no errors surfaced. Check kubectl -n llm logs deploy/vllm-bge-reranker and GPU node status."
              }
            },
          ]
        },
        # -------------------------------------------------------------
        # Phase #37: argo-rollouts state alerts
        # -------------------------------------------------------------
        # Closes a gap left by Phases #28-36: today nothing pages if
        # a canary stalls overnight (operator missed a manual promote)
        # or if AnalysisRuns trend toward failure between gated
        # checkpoints. These three alerts watch the controller's own
        # operational metrics (exposed via Phase #28's metrics ServiceMonitor).
        #
        # Metric source: argo-rollouts controller's /metrics endpoint
        # (Phase #28 enabled the ServiceMonitor). Series we use:
        #   rollout_info{name=,namespace=,phase=}    1 = current phase
        #   rollout_phase                            current phase as label
        #   analysis_run_info{phase=,...}            1 = current AR phase
        # Grafana sidecar picks up the metrics; PromQL queries below
        # don't need any additional scrape config.
        {
          name     = "argo-rollouts.rules"
          interval = "30s"
          rules = [
            {
              alert = "RolloutPausedTooLong"
              # Any Rollout in Paused phase for >30m. Catches the
              # case where a canary hits a manual approval / pause
              # step and the operator forgets to come back.
              # Ignores Rollouts whose canary spec doesn't include
              # any indefinite-pause steps (lab's all use timed
              # pauses, but harmless if added later).
              expr = "max by (name, namespace) (rollout_info{phase=\"Paused\"}) == 1"
              for  = "30m"
              labels = {
                severity = "warning"
                service  = "argo-rollouts"
              }
              annotations = {
                summary     = "Rollout {{ $labels.namespace }}/{{ $labels.name }} paused >30m"
                description = "An Argo Rollouts canary has been in Paused phase for over 30 minutes. Either an operator forgot to promote a manual-pause step, or a timed pause step is misconfigured with an excessive duration. Check via: kubectl argo rollouts get rollout {{ $labels.name }} -n {{ $labels.namespace }}. Promote with: kubectl argo rollouts promote {{ $labels.name }} -n {{ $labels.namespace }}."
              }
            },
            {
              alert = "RolloutDegraded"
              # Phase=Degraded means the canary aborted (analysis
              # failed, or the stable+canary pods can't reach
              # quorum). Don't wait — this is critical.
              expr = "max by (name, namespace) (rollout_info{phase=\"Degraded\"}) == 1"
              for  = "5m"
              labels = {
                severity = "critical"
                service  = "argo-rollouts"
              }
              annotations = {
                summary     = "Rollout {{ $labels.namespace }}/{{ $labels.name }} degraded"
                description = "An Argo Rollouts canary entered Degraded phase — usually means analysis failed or the canary RS can't reach Ready. Inspect via: kubectl argo rollouts get rollout {{ $labels.name }} -n {{ $labels.namespace }}. To revert: kubectl argo rollouts undo {{ $labels.name }} -n {{ $labels.namespace }}. To inspect AnalysisRun verdicts: kubectl argo rollouts list analysisruns -n {{ $labels.namespace }}."
              }
            },
            {
              alert = "RolloutAnalysisRunFailed"
              # Any AnalysisRun reaching Failed phase. Faster
              # signal than RolloutDegraded — fires the moment an
              # AnalysisRun fails, before argo-rollouts has
              # transitioned the rollout to Degraded.
              expr = "max by (name, namespace) (analysis_run_info{phase=\"Failed\"}) == 1"
              for  = "1m"
              labels = {
                severity = "critical"
                service  = "argo-rollouts"
              }
              annotations = {
                summary     = "AnalysisRun {{ $labels.namespace }}/{{ $labels.name }} failed"
                description = "An argo-rollouts AnalysisRun reported phase=Failed — the canary will abort imminently. Inspect the failure reason via: kubectl argo rollouts get analysisrun {{ $labels.name }} -n {{ $labels.namespace }}. Most common causes: success/failure threshold tripped on the metric query; Prometheus connection error; PromQL syntax error on the query."
              }
            },
          ]
        },
        # -------------------------------------------------------------
        # langgraph-service alerts
        # -------------------------------------------------------------
        {
          name     = "langgraph-service.rules"
          interval = "30s"
          rules = [
            {
              alert = "LanggraphServiceDown"
              expr  = "absent_over_time(up{job=\"langgraph-service\"}[5m]) == 1 or sum(up{job=\"langgraph-service\"}) == 0"
              for   = "5m"
              labels = {
                severity = "critical"
                service  = "langgraph-service"
              }
              annotations = {
                summary     = "langgraph-service is not being scraped or all replicas are down"
                description = "Prometheus has no healthy targets for job=langgraph-service for 5m. Check kubectl -n langgraph get pods and the /readyz deep-check breakdown."
              }
            },
            {
              alert = "LanggraphReadinessDegraded"
              expr  = "sum(rate(langgraph_requests_total[10m])) > 0 and (sum(up{job=\"langgraph-service\"}) / count(up{job=\"langgraph-service\"})) < 0.5"
              for   = "10m"
              labels = {
                severity = "warning"
                service  = "langgraph-service"
              }
              annotations = {
                summary     = "Fewer than half of langgraph-service replicas are scraping cleanly"
                description = "Some langgraph-service pods are scrape-failing while others serve traffic. /readyz has soft (vllm-llama-8b, vllm-llama-guard, rag-service) and hard (Redis, Keycloak JWKs) deps — the soft ones can degrade for unrelated reasons. kubectl -n langgraph get endpoints langgraph-service shows which pod IPs are missing."
              }
            },
            {
              alert = "LanggraphReasoningCyclesAtCap"
              expr  = "histogram_quantile(0.95, sum by (le) (rate(langgraph_reasoning_cycles_bucket[15m]))) >= 3"
              for   = "15m"
              labels = {
                severity = "warning"
                service  = "langgraph-service"
              }
              annotations = {
                summary     = "Reasoning loop P95 hitting the cycle cap"
                description = "P95 reasoning_cycles is at MAX_REASONING_CYCLES (default 3) — the reflect node is consistently asking for more retrieval. Usually a retrieval-quality issue: check the rag-service dashboard for chunks_returned dropping or the reranker fail-open rate climbing."
              }
            },
            {
              alert = "LanggraphSafetyBlockSpike"
              expr  = "sum(rate(langgraph_safety_action_total{action=~\"blocked_input|blocked_output\"}[5m])) > 0.5"
              for   = "10m"
              labels = {
                severity = "warning"
                service  = "langgraph-service"
              }
              annotations = {
                summary     = "Llama Guard blocking >0.5 req/s sustained"
                description = "Sustained high block rate from the safety_input/safety_output nodes. Could be: (a) adversarial traffic (check Langfuse traces for the blocked prompts), or (b) a Llama Guard model version that's drifted overly conservative (check vllm-llama-guard pod and the staged S3 weights)."
              }
            },
          ]
        },
      ]
    }
  })

  depends_on = [helm_release.kube_prometheus_stack]
}
