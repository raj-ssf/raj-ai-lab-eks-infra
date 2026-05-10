# =============================================================================
# Phase 4e (companion to KEDA install in Phase 5c): a working ScaledObject
# demonstrating the cron + prometheus stacked-trigger pattern.
#
# Target: argo-rollouts-dashboard (Phase 4d). Always-warm during business
# hours, scale-to-zero off-hours. The dashboard is unauth'd anyway, so
# off-hours scale-to-zero doubles as a "no exposure when nobody's looking"
# behavior.
#
# Trigger composition:
#   cron        9am-2am PT  →  min replicas = 1
#   prometheus  unused for now (no useful demand metric for the
#               dashboard); add later as `keda_prometheus_threshold:
#               http_requests_total{service="argo-rollouts-dashboard"}`.
#
# Effective replica count = MAX(triggers). Off-hours: 0 (saves ~$0.01/hr
# of pod cpu/memory). Business hours: 1 always-warm.
# =============================================================================

resource "kubectl_manifest" "rollouts_dashboard_scaledobject" {
  yaml_body = yamlencode({
    apiVersion = "keda.sh/v1alpha1"
    kind       = "ScaledObject"
    metadata = {
      name      = "argo-rollouts-dashboard"
      namespace = "argo-rollouts"
    }
    spec = {
      scaleTargetRef = {
        apiVersion = "apps/v1"
        kind       = "Deployment"
        name       = "argo-rollouts-dashboard"
      }
      pollingInterval = 30
      cooldownPeriod  = 600 # 10 minutes idle before scale-to-zero
      minReplicaCount = 0
      maxReplicaCount = 1
      triggers = [
        {
          type = "cron"
          metadata = {
            timezone        = "America/Los_Angeles"
            start           = "0 9 * * *"  # 9 AM PT
            end             = "0 2 * * *"  # 2 AM PT next day
            desiredReplicas = "1"
          }
        },
      ]
    }
  })

  depends_on = [
    helm_release.keda,
    helm_release.argo_rollouts,
  ]
}

# =============================================================================
# Verify with:
#   kubectl get scaledobject -n argo-rollouts
#   kubectl describe scaledobject -n argo-rollouts argo-rollouts-dashboard
#
# Watch the dashboard scale 0↔1 across the 9am/2am boundary:
#   kubectl get deploy -n argo-rollouts argo-rollouts-dashboard -w
# =============================================================================
