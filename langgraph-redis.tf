# =============================================================================
# Phase #75: langgraph-redis HA via Bitnami Redis chart with replication
# + Sentinel.
#
# Replaces the single-pod langgraph-redis Deployment in the gitops repo
# (raj-ai-lab-eks/langgraph-service/base/redis.yaml — Phase #5 design).
# That design intentionally accepted restart-amnesty for the cost-bucket
# token bucket use case, but langgraph-redis ALSO holds Chainlit
# conversation memory (per Phase #45 chat-ui blueGreen→canary commit
# context: "Chainlit's client reconnect kicks in ... rebuilds session
# state from langgraph-redis store"). Conversation loss on Redis pod
# restart is user-visible and worth the HA cost.
#
# Architecture (Bitnami chart's `architecture: replication`):
#
#   StatefulSet (1 master + 2 replicas)
#     Each pod runs redis + sentinel sidecar. Sentinel provides
#     automatic master election + failover. Master accepts writes;
#     replicas serve reads. Quorum 2/3 tolerates 1 pod loss.
#
#   Services
#     langgraph-redis-ha-master    routes to the CURRENT master only.
#                                  Sentinel updates the Service
#                                  endpoint on failover (~10s).
#                                  Clients connect here for both
#                                  reads + writes (simplest pattern;
#                                  master handles both).
#     langgraph-redis-ha-replicas  read-only replicas. Useful for
#                                  read-heavy workloads. Not used by
#                                  langgraph-service today.
#     langgraph-redis-ha-headless  per-pod stable DNS (ordinal-based).
#
#   PVCs (1Gi gp3 per pod, 3 total)
#     Per-pod persistence so individual pod restarts don't wipe
#     state. The original "restart-amnesty" design was at the
#     CLUSTER level (single pod = cluster); with replication, that
#     amnesty is no longer aligned with a 3-pod cluster (losing 1
#     pod isn't supposed to lose state). Per-pod 1Gi storage =
#     ~$0.30/pod/mo × 3 = $0.90/mo. Negligible vs lab teardown.
#
# Migration plan (two-commit phase):
#
#   Phase #75a (this commit, infra)
#     Deploy Bitnami chart with name `langgraph-redis-ha`. Old
#     `langgraph-redis` Deployment + Service in the gitops repo
#     stay running. langgraph-service still talks to the old
#     instance (no behavior change yet).
#
#   Phase #75b (gitops repo, follow-up)
#     1. langgraph-service rollout.yaml: update REDIS_URL env to
#        point at langgraph-redis-ha-master:6379
#     2. Delete redis.yaml + remove from kustomization.yaml
#     3. ArgoCD reconciles — old Deployment + Service deleted,
#        langgraph-service rolls onto the new master Service.
#     Brief data loss during cutover (existing emptyDir state
#     doesn't migrate). Daily cost-bucket counters reset (acceptable
#     by original design); in-flight conversations lose state
#     (Chainlit auto-reconnects via Phase #44 consistent-hash DR).
#
# Mesh integration: langgraph namespace is meshed (Phase #55), so
# new pods get Istio sidecars. Existing intra-namespace Istio AuthZ
# (allow-intra-namespace in istio-zero-trust.tf) covers langgraph-
# service → langgraph-redis-ha calls.
#
# AUTH: keeping disabled (matches original design). Within-namespace
# meshed traffic is mTLS-protected; AUTH would add a layer of
# secret management (Vault KV + agent inject) for marginal benefit.
# Production would enable AUTH + TLS; lab acceptable.
# =============================================================================

resource "helm_release" "langgraph_redis_ha" {
  name       = "langgraph-redis-ha"
  namespace  = "langgraph"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "redis"
  # Bitnami chart pinned for reproducibility.
  version = "20.6.2"

  values = [
    yamlencode({
      # 1 master + 2 replicas + Sentinel sidecars in each pod.
      architecture = "replication"

      # No AUTH — matches original Phase #5 design. mTLS-mesh provides
      # transport-level auth; full Redis AUTH would add Vault/Secret
      # management for marginal lab benefit.
      auth = {
        enabled = false
      }

      master = {
        # Per-pod 1Gi PVC. Small — daily-bucket data is tiny + Chainlit
        # session state is bounded.
        persistence = {
          enabled      = true
          size         = "1Gi"
          storageClass = "gp3"
          accessModes  = ["ReadWriteOnce"]
        }
        resources = {
          requests = { cpu = "100m", memory = "128Mi" }
          limits   = { cpu = "200m", memory = "256Mi" }
        }
      }

      replica = {
        replicaCount = 2
        persistence = {
          enabled      = true
          size         = "1Gi"
          storageClass = "gp3"
          accessModes  = ["ReadWriteOnce"]
        }
        resources = {
          requests = { cpu = "100m", memory = "128Mi" }
          limits   = { cpu = "200m", memory = "256Mi" }
        }
      }

      # Sentinel: enabled by default at architecture=replication. Each
      # redis pod runs a sentinel sidecar that participates in master
      # election. Quorum 2/3 — tolerates 1 sentinel loss.
      sentinel = {
        enabled = true
        # Failover detection: how long master must be unreachable
        # before sentinels initiate election. 5000ms is the chart
        # default — short enough to react to real failure, long
        # enough to avoid election storms on transient network
        # blips.
        downAfterMilliseconds = 5000
      }

      # Chart's PodDisruptionBudget — minAvailable=2 so voluntary
      # disruptions (drains, chart upgrades) can't drop quorum.
      pdb = {
        create       = true
        minAvailable = 2
      }

      # ServiceMonitor for Prometheus scrape — consistent with the
      # observability story Phase #67 + #68 + #69 set up.
      metrics = {
        enabled = true
        serviceMonitor = {
          enabled = true
          # Match label so kube-prometheus-stack picks it up.
          additionalLabels = {
            release = "kube-prometheus-stack"
          }
        }
      }

      # Anti-affinity: chart default is preferred. Cluster has 3
      # static nodes available; cross-node spread satisfiable.
      # podAntiAffinityPreset = "hard" would force required, but
      # consistent with Phase #59/60/62 lessons we leave it
      # preferred for graceful degradation under capacity pressure.
    })
  ]

  depends_on = [
    module.eks,
    helm_release.istiod,
    kubernetes_storage_class_v1.gp3,
    kubernetes_namespace.langgraph,
  ]
}

output "langgraph_redis_ha_master_endpoint" {
  value       = "langgraph-redis-ha-master.langgraph.svc.cluster.local:6379"
  description = "Master Service for langgraph-service to connect to. Sentinel updates this Service's endpoint on failover automatically."
}
