# =============================================================================
# Phase 5b: Tetragon — eBPF runtime security observability + enforcement.
#
# Tetragon is the security sub-project of Cilium. Same eBPF foundation
# as the cilium-agent (just different hooks): tracepoints / kprobes /
# uprobes that observe process exec, file I/O, network sockets, and
# syscalls — and CAN ENFORCE (kill / signal / ratelimit) inline in the
# kernel, not just alert.
#
# Why Tetragon over Falco for this lab:
#   - Same eBPF foundation as Cilium (already running). Falco runs its
#     own data plane (separate DaemonSet, separate Falco rules engine).
#     Tetragon piggybacks on Cilium's identity and policy infrastructure
#     — events tag with Cilium identity (pod-source / dest), Hubble
#     can correlate flow + process events.
#   - Inline enforcement (block syscall, kill process, send signal)
#     in addition to detection. Falco is detection-only by design;
#     it emits events, downstream tooling decides what to do.
#   - Smaller surface area for a Cilium-native lab. Falco brings its
#     own rule format, plugin system, sidekick → SIEM tooling.
#
# Deployment shape:
#   - DaemonSet on every EC2 worker (Fargate excluded — same nodeSelector
#     pattern as cilium-agent: Fargate has no eBPF kernel access for
#     Tetragon's hooks).
#   - tetragon-operator manages TracingPolicy CRDs (the enforcement /
#     observation specifications).
#   - Default Tetragon ships with several built-in policies — process
#     exec tracking (syscalls.process), namespace info attachment
#     (ProcessLifeCycle). We start there; add custom TracingPolicies
#     in follow-up phases.
#
# Output: Tetragon emits JSON events to /var/log/tetragon/tetragon.log
# AND to stdout (visible via kubectl logs). Phase 6 can wire these to
# Datadog / Loki / SIEM via a logfile collector.
# =============================================================================

resource "kubernetes_namespace" "tetragon" {
  metadata {
    name = "tetragon"
  }
}

resource "helm_release" "tetragon" {
  name       = "tetragon"
  namespace  = kubernetes_namespace.tetragon.metadata[0].name
  repository = "https://helm.cilium.io"
  chart      = "tetragon"
  # Pin — 1.2.x line is GA-stable. Cilium charts have separate cadence
  # from the cilium agent itself (Tetragon at 1.2.x is contemporary
  # with Cilium 1.16.x).
  version = "1.2.0"

  values = [
    yamlencode({
      # Tetragon agent DaemonSet — runs on every EC2 worker. Fargate
      # exclusion via top-level affinity (chart key, not under
      # `tetragon.*`). Same nodeSelector pattern as cilium-agent —
      # Fargate has no eBPF kernel access for Tetragon's hooks. Without
      # this, 2 of 5 DS pods land on Fargate and get
      # "UnsupportedPodSpec: HostNetwork, hostPath volumes, Privileged".
      affinity = {
        nodeAffinity = {
          requiredDuringSchedulingIgnoredDuringExecution = {
            nodeSelectorTerms = [{
              matchExpressions = [{
                key      = "karpenter.sh/nodepool"
                operator = "Exists"
              }]
            }]
          }
        }
      }

      tetragon = {
        resources = {
          requests = { cpu = "100m", memory = "128Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }

        exportFilename = "tetragon.log"
      }

      # Tetragon-operator runs the TracingPolicy CRD controller. Pin
      # to EC2 — same reasoning as cilium-operator (but operator is
      # NOT hostNetwork like cilium-operator, so Fargate would
      # technically work; pinning to EC2 for consistency + because
      # the operator queries cilium-agent locally for identity info).
      tetragonOperator = {
        nodeSelector = {
          "karpenter.sh/nodepool" = "general"
        }
        resources = {
          requests = { cpu = "10m", memory = "32Mi" }
          limits   = { cpu = "100m", memory = "128Mi" }
        }
      }

      # Service for the tetragon-grpc endpoint (port 54321) so a
      # tetragon CLI client can stream events. Not externally exposed.
      export = {
        stdout = {
          enabled = true
        }
      }
    })
  ]

  depends_on = [
    module.eks,
    helm_release.cilium, # share the cilium-agent identity infrastructure
  ]
}

output "tetragon_event_stream_hint" {
  value       = "kubectl logs -n tetragon -l app.kubernetes.io/name=tetragon -c export-stdout -f --max-log-requests=10"
  description = "Tail Tetragon process-exec events from all nodes (one log per node)"
}
