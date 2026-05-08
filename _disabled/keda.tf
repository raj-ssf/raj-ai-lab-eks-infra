# =============================================================================
# Phase #80d: KEDA — autoscaling above HPA's structural limits.
#
# What KEDA adds beyond the existing HPA + prometheus-adapter combo:
#
#   1. SCALE FROM 0:
#      HPA cannot scale from 0 because its metric source goes <unknown>
#      when no pods are running. Phase #80b's prometheus-adapter
#      exposes vllm:num_requests_waiting as a custom metric, but
#      the metric series is empty when pods=0, so HPA can't read a
#      value to act on. KEDA polls Prometheus DIRECTLY (independent
#      of pod state) — empty PromQL result is just `0`, which is a
#      legitimate scaling signal.
#
#   2. STACKED TRIGGERS:
#      A KEDA ScaledObject can declare multiple triggers; the
#      effective replica count is MAX across all triggers. This lets
#      us combine:
#        cron trigger      time-based always-warm during
#                          demo/work hours (9am-2am PT)
#        prometheus trigger queue-depth-based scale-up under load
#      During business hours: max(1 cron, 0+load) → always ≥ 1
#      Off-hours, idle: max(0, 0) → 0 (cost savings)
#      Off-hours, load: max(0, prometheus-driven) → spawn
#
#   3. EXPLICIT cooldownPeriod:
#      HPA's scale-down policy is heuristic; KEDA's cooldownPeriod
#      is direct ("don't scale down until N seconds idle"). Cleaner
#      semantic for "stay warm 10min after last request, then drop
#      to 0".
#
# Why we do this NOW (Phase #80d):
#   Phase #82d removed the prewarm-cronjobs because they bypassed
#   HPA's min=1 floor and caused user-facing 503s during the
#   2am-PT scale-down window. The fix locked vllm-llama-8b at
#   always-warm 24/7 (~$580/mo vs ~$330/mo with the windowed
#   pattern). Phase #80d restores the cost-windowed pattern
#   declaratively via KEDA — single source of truth, no
#   conflicts with HPA's floor enforcement.
#
# Cost trade-off after Phase #80d (replaces the post-#82d baseline):
#   Phase #82d (HPA min=1, no cron):      $580/mo always-warm
#   Phase #80d (KEDA cron 9am-2am):       ~$330/mo windowed
#                                          + ~$0/mo off-hours idle
#                                          + cold-start cost on
#                                          first off-hours request
#   Net savings: ~$250/mo. Same as pre-#82d Phase #54 windowing
#   but without the structural conflict.
#
# Cold-start UX off-hours:
#   First request after a 10-min idle period (KEDA's cooldown +
#   off-hours window): KEDA scales 0→1, Karpenter spawns a g6.
#   xlarge (~3 min), vllm cold-starts (~2 min), pod becomes
#   Ready (~30s). Total ~5-6 min. langgraph's ensure_warm node
#   handles the wait gracefully (returns to user with a
#   "scaling up..." status; client polls until ready).
#
#   This is acceptable for a lab serving demo traffic. Production
#   chat at 1000 users would NEVER have a 10-min idle window
#   (organic traffic keeps it warm), so the cost-savings would
#   be real with no user impact.
#
# Phase #80 progression (with this commit):
#   #80a  prefix caching                              done (verified)
#   #80b  prometheus-adapter                          done (verified)
#   #80c  HPA on vllm-llama-8b (queue-depth)          done (verified)
#   #80d  KEDA install (this) + ScaledObject (gitops) in-flight —
#                                                    replaces HPA
#   #80e  ServiceMonitor scope expansion              done (verified)
# =============================================================================

resource "kubernetes_namespace" "keda" {
  metadata {
    name = "keda"
    # NOT mesh-injected: KEDA's controller-manager + metrics-server
    # call the K8s API and Prometheus only. Adding a sidecar would
    # complicate the metrics-server's API-extension TLS path
    # (similar trap to prometheus-adapter in Phase #80b — solved
    # there with traffic.sidecar.istio.io/excludeInboundPorts).
    # Keep it simple: leave KEDA outside the mesh.
  }
}

resource "helm_release" "keda" {
  name       = "keda"
  namespace  = kubernetes_namespace.keda.metadata[0].name
  repository = "https://kedacore.github.io/charts"
  chart      = "keda"
  # Pin for reproducibility. Bump cadence: check
  # https://github.com/kedacore/keda/releases for breaking changes
  # to the ScaledObject CRD before upgrading.
  version = "2.16.1"

  values = [
    yamlencode({
      # 2 replicas of the operator + metrics-server for HA.
      # Operator is in the path of every ScaledObject reconcile
      # (creates/manages the underlying HPA + scales the
      # Deployment); single-pod failure pauses all KEDA-driven
      # autoscaling cluster-wide. Same Phase #59-#62 reasoning.
      operator = {
        replicaCount = 2
        affinity = {
          podAntiAffinity = {
            preferredDuringSchedulingIgnoredDuringExecution = [{
              weight = 100
              podAffinityTerm = {
                labelSelector = {
                  matchLabels = {
                    "app.kubernetes.io/name" = "keda-operator"
                  }
                }
                topologyKey = "kubernetes.io/hostname"
              }
            }]
          }
        }
      }

      # KEDA's metrics-adapter is a k8s aggregated API server that
      # the K8s HPA controller calls into. Same setup pattern as
      # prometheus-adapter (Phase #80b). 2 replicas for HA.
      metricsServer = {
        replicaCount = 2
      }

      # Resource sizing — KEDA controllers are lightweight
      # (Go-based, ~50-100MB memory at idle).
      resources = {
        operator = {
          requests = { cpu = "50m", memory = "100Mi" }
          limits   = { cpu = "200m", memory = "256Mi" }
        }
        metricServer = {
          requests = { cpu = "50m", memory = "100Mi" }
          limits   = { cpu = "200m", memory = "256Mi" }
        }
      }

      # ServiceMonitor for KEDA's own /metrics — surfaces the
      # operator's reconcile latency + per-trigger query timings
      # to kube-prometheus-stack. Useful for catching "KEDA is
      # querying Prometheus but Prometheus is slow" issues.
      prometheus = {
        metricServer = {
          enabled = true
          serviceMonitor = {
            enabled = true
            additionalLabels = {
              release = "kube-prometheus-stack"
            }
          }
        }
        operator = {
          enabled = true
          serviceMonitor = {
            enabled = true
            additionalLabels = {
              release = "kube-prometheus-stack"
            }
          }
        }
      }
    })
  ]

  depends_on = [
    helm_release.kube_prometheus_stack,
  ]
}
