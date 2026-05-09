# =============================================================================
# Phase #80b: prometheus-adapter — exposes Prometheus metrics through the
# K8s `custom.metrics.k8s.io/v1beta1` API so HPAs can scale workloads on
# any Prometheus series.
#
# Why we need this beyond the metrics-server addon (Phase #68):
#
#   metrics-server                 prometheus-adapter
#   --------------                 ------------------
#   v1beta1.metrics.k8s.io         v1beta1.custom.metrics.k8s.io
#   resource metrics only          arbitrary Prometheus metrics
#   CPU, memory                    vllm:num_requests_waiting,
#                                  http_requests_per_second,
#                                  qdrant:active_searches, etc.
#   built-in K8s API               separate API service (this addon)
#
# Phase #67 + #68 + Phase #60 wired CPU-based HPAs (HorizontalPodAutoscaler
# referencing `resource: cpu`). Those work for stateless web workloads
# where CPU correlates with load. They DON'T work for vllm: GPU is the
# bottleneck, not CPU. Python's vllm-openai server has roughly constant
# CPU (~3-5 cores) regardless of how many concurrent requests are
# in-flight on the GPU. Scaling on CPU would never trigger.
#
# The right vllm scaling signal is `vllm:num_requests_waiting` — the
# count of queued requests not yet picked up by the continuous-batching
# scheduler. > 5 sustained = backpressure → spawn more pods.
#
# Phase #80 progression (this is #80b):
#   #80a  prefix caching + GPU mem on vllm-llama-8b   done
#   #80b  prometheus-adapter (this commit)            in-flight
#   #80c  HPA on vllm-llama-8b targeting              follow-up
#         vllm:num_requests_waiting
#
# Adapter rule design:
#
# Each rule maps a SET of Prometheus series → a SINGLE K8s custom-metrics
# API endpoint. The 4 fields:
#
#   seriesQuery    Prometheus selector for the series this rule covers
#   resources      How to map Prom labels → K8s resource (pod/ns/...)
#   name.matches   Regex to extract the K8s API metric name from the
#                  Prometheus series name (colons aren't allowed in K8s
#                  API names — must rewrite vllm:num_requests_waiting →
#                  vllm_num_requests_waiting)
#   metricsQuery   PromQL template the adapter runs to compute the
#                  actual value when HPA queries
#
# We expose:
#   vllm:num_requests_waiting    → vllm_num_requests_waiting    (Pods)
#   vllm:num_requests_running    → vllm_num_requests_running    (Pods)
#   vllm:gpu_cache_usage_perc    → vllm_gpu_cache_usage_perc    (Pods)
#   vllm:gpu_prefix_cache_hit_rate → vllm_gpu_prefix_cache_hit_rate (Pods)
#
# All as Pods-type metrics (per-pod values; HPA averages across the pod
# set). Object-type would also work for some (cache_hit_rate is more of
# a Service-level signal) but Pods is simpler and sufficient.
#
# Failure modes:
#   - rule mismatch  → HPA shows `<unknown>`, doesn't scale (same trap
#                      as Phase #60 missing metrics-server). Verify with:
#                        kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1
#                        kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1/namespaces/llm/pods/*/vllm_num_requests_waiting
#   - empty series   → HPA value defaults to 0 (NOT <unknown>) when the
#                      series exists in Prometheus history but has no
#                      current value. Important: when vllm replicas=0,
#                      no metrics emit, so HPA sees 0. Phase #80c's
#                      HPA must use minReplicas≥1 to keep at least one
#                      vllm pod warm; HPA doesn't scale from 0.
# =============================================================================

resource "helm_release" "prometheus_adapter" {
  name       = "prometheus-adapter"
  namespace  = "monitoring"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus-adapter"
  # Pinned for reproducibility. Bump cadence: check release notes
  # for breaking changes to the rules schema before upgrading.
  version = "4.13.0"

  values = [
    yamlencode({
      # Point at the in-cluster Prometheus from kube-prometheus-stack.
      prometheus = {
        url  = "http://kube-prometheus-stack-prometheus.monitoring.svc"
        port = 9090
      }

      # 2 replicas for HA — the adapter is in the synchronous path of
      # every HPA reconcile. Single-pod failure pauses ALL custom-
      # metrics-based HPAs cluster-wide. Same Phase #59-#62 reasoning.
      replicas = 2

      # Phase #80b first-apply discovery: APIService stuck in
      # FailedDiscoveryCheck with "EOF" from kube-apiserver →
      # https://<pod-ip>:6443/.../v1beta1. Root cause: the EKS-
      # managed kube-apiserver lives OUTSIDE the cluster's pod
      # network and is NOT in the Istio mesh. When it tries to
      # reach the adapter's API-extension TLS port (6443), the
      # adapter's istio-proxy sidecar intercepts the connection
      # and expects an Istio mTLS handshake. kube-apiserver
      # speaks plain TLS with its own client cert (front-proxy-
      # ca), so the handshake fails with EOF.
      #
      # The fix is to tell Istio to bypass interception for
      # inbound traffic on 6443. Envoy still handles other ports
      # (whatever the chart defaults to for metrics/health) but
      # 6443 traffic flows directly to the adapter container.
      #
      # Same pattern would apply to any K8s aggregated-API server
      # (metrics-server, vault-csi-provider, knative-eventing's
      # broker-filter) deployed in a meshed namespace.
      podAnnotations = {
        "traffic.sidecar.istio.io/excludeInboundPorts" = "6443"
      }

      # Anti-affinity: preferred (Phase #59 lesson — graceful
      # degradation under capacity pressure).
      affinity = {
        podAntiAffinity = {
          preferredDuringSchedulingIgnoredDuringExecution = [{
            weight = 100
            podAffinityTerm = {
              labelSelector = {
                matchLabels = {
                  "app.kubernetes.io/name"     = "prometheus-adapter"
                  "app.kubernetes.io/instance" = "prometheus-adapter"
                }
              }
              topologyKey = "kubernetes.io/hostname"
            }
          }]
        }
      }

      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { cpu = "200m", memory = "256Mi" }
      }

      # Rules block: 4 vllm metrics exposed as Pods-type custom metrics.
      # Default rules (kept disabled — replaced wholesale by `custom`).
      rules = {
        default = false
        custom = [
          # --- vllm:num_requests_waiting -------------------------------
          # The PRIMARY scaling signal for vllm. Count of requests in
          # the prefill/decode queue. >5 sustained = backpressure.
          {
            seriesQuery = "vllm:num_requests_waiting{namespace!=\"\",pod!=\"\"}"
            resources = {
              overrides = {
                namespace = { resource = "namespace" }
                pod       = { resource = "pod" }
              }
            }
            name = {
              matches = "^vllm:(.+)$"
              as      = "vllm_$1"
            }
            metricsQuery = "sum(<<.Series>>{<<.LabelMatchers>>}) by (<<.GroupBy>>)"
          },
          # --- vllm:num_requests_running -------------------------------
          # Currently-decoding requests. Useful as a secondary signal
          # (HPA can target either-or). Same shape as waiting.
          {
            seriesQuery = "vllm:num_requests_running{namespace!=\"\",pod!=\"\"}"
            resources = {
              overrides = {
                namespace = { resource = "namespace" }
                pod       = { resource = "pod" }
              }
            }
            name = {
              matches = "^vllm:(.+)$"
              as      = "vllm_$1"
            }
            metricsQuery = "sum(<<.Series>>{<<.LabelMatchers>>}) by (<<.GroupBy>>)"
          },
          # --- vllm:gpu_cache_usage_perc -------------------------------
          # KV cache fill ratio (0-1). Memory pressure signal — HPA
          # scaling on this is "cache is full, can't admit more
          # requests, scale up." Complementary to queue-depth signal.
          {
            seriesQuery = "vllm:gpu_cache_usage_perc{namespace!=\"\",pod!=\"\"}"
            resources = {
              overrides = {
                namespace = { resource = "namespace" }
                pod       = { resource = "pod" }
              }
            }
            name = {
              matches = "^vllm:(.+)$"
              as      = "vllm_$1"
            }
            metricsQuery = "avg(<<.Series>>{<<.LabelMatchers>>}) by (<<.GroupBy>>)"
          },
          # --- vllm:gpu_prefix_cache_hit_rate --------------------------
          # Phase #80a's success metric. Not a scaling signal — exposed
          # via this adapter so future Grafana panels or alerting rules
          # can query through the K8s custom-metrics API path.
          {
            seriesQuery = "vllm:gpu_prefix_cache_hit_rate{namespace!=\"\",pod!=\"\"}"
            resources = {
              overrides = {
                namespace = { resource = "namespace" }
                pod       = { resource = "pod" }
              }
            }
            name = {
              matches = "^vllm:(.+)$"
              as      = "vllm_$1"
            }
            metricsQuery = "avg(<<.Series>>{<<.LabelMatchers>>}) by (<<.GroupBy>>)"
          },
        ]
      }
    })
  ]

  depends_on = [
    helm_release.kube_prometheus_stack,
  ]
}

output "prometheus_adapter_verify_command" {
  value       = "kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1 | python3 -m json.tool | head -40"
  description = "Run after apply to confirm the adapter registered. Should list vllm_* metric resources under 'pods' resource. Empty list = adapter is up but rules don't match any current Prometheus series (expected when vllm pods are scaled to 0)."
}
