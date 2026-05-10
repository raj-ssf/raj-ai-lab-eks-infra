# =============================================================================
# Phase 4d: Argo Rollouts — progressive delivery controller.
#
# Foundation for canary / blueGreen deploys. Installs the controller +
# dashboard + 5 CRDs (Rollout, AnalysisRun, AnalysisTemplate,
# ClusterAnalysisTemplate, Experiment). Future phases convert specific
# workloads from kind:Deployment → kind:Rollout with strategy.canary
# blocks that gate on AnalysisTemplates referencing Prometheus metrics.
#
# Differences from the Istio-era argo-rollouts.tf in _disabled:
#   - No istio-injection on the namespace (Istio gone). When we wire
#     traffic-shifting Rollouts in a later phase, switch from Istio's
#     VirtualService weighting to Cilium Gateway API's HTTPRoute
#     weight rules (Gateway API v1 supports the same shape).
#   - HTTPRoute backendRefs point directly at the argo-rollouts-dashboard
#     Service, not oauth2-proxy. SECURITY CAVEAT documented below; Phase
#     4f or 5 should add oauth2-proxy + Keycloak OIDC for the dashboard.
# =============================================================================

resource "kubernetes_namespace" "argo_rollouts" {
  metadata {
    name = "argo-rollouts"
  }
}

resource "helm_release" "argo_rollouts" {
  name       = "argo-rollouts"
  namespace  = kubernetes_namespace.argo_rollouts.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-rollouts"
  version    = "2.37.7"

  values = [
    yamlencode({
      dashboard = {
        enabled = true
        resources = {
          requests = { cpu = "10m", memory = "32Mi" }
          limits   = { cpu = "100m", memory = "128Mi" }
        }
      }

      controller = {
        # 2 replicas for HA — Lease-based leader election lets a
        # standby take over within ~15s on a node drain or controller
        # OOM, instead of a multi-minute pause on canary cycles.
        replicas = 2
        resources = {
          requests = { cpu = "100m", memory = "128Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
        # /metrics scrape via ServiceMonitor — emits rollout_phase,
        # rollout_info, controller_clientset_k8s_request_total etc.
        # Useful even without a Rollout in the cluster: shows the
        # controller's API churn vs idle.
        metrics = {
          enabled = true
          serviceMonitor = {
            enabled = true
            additionalLabels = {
              release = "kube-prometheus-stack"
            }
          }
        }
      }

      # Notifications controller (Slack / Teams / etc.) disabled — no
      # receivers wired in this lab. Pair its enable with alertmanager
      # receivers when they go live.
      notifications = {
        enabled = false
      }
    })
  ]

  depends_on = [
    module.eks,
  ]
}

# =============================================================================
# HTTPRoute exposing the dashboard at rollouts.${var.domain}.
#
# SECURITY CAVEAT: argo-rollouts-dashboard has NO native auth. The
# dashboard is read-only (state of Rollouts, AnalysisRuns, image
# hashes), but that operational state IS sensitive. Today's reliance:
#   - Hostname is unpublished outside this repo
#   - NLB is internet-facing but TLS-only
#   - Cluster RBAC still gates kubectl-level mutation
#
# Phase 4f / 5 hardening: add oauth2-proxy in front, point the HTTPRoute
# at oauth2-proxy:80 instead of the dashboard Service. Shared Keycloak
# realm session cookie with grafana / argocd / langfuse.
# =============================================================================

resource "kubectl_manifest" "rollouts_httproute" {
  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "rollouts-dashboard"
      namespace = kubernetes_namespace.argo_rollouts.metadata[0].name
      labels    = { app = "argo-rollouts-dashboard" }
    }
    spec = {
      parentRefs = [{
        name        = "shared-gateway"
        namespace   = "gateway-system"
        sectionName = "rollouts-https"
      }]
      hostnames = ["rollouts.${var.domain}"]
      rules = [{
        matches = [{
          path = { type = "PathPrefix", value = "/" }
        }]
        backendRefs = [{
          # Routed through oauth2-proxy first (Keycloak OIDC). oauth2-proxy
          # then forwards authenticated requests to argo-rollouts-dashboard:3100
          # via its `--upstream` config (see oauth2-proxy.tf helm values).
          # Closes the "no native auth" gap on the dashboard.
          name = "oauth2-proxy"
          port = 80
        }]
      }]
    }
  })

  depends_on = [
    helm_release.argo_rollouts,
    kubectl_manifest.shared_gateway,
  ]
}
