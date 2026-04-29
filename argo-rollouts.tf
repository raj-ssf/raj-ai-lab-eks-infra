# Phase #28: Argo Rollouts controller install.
#
# Foundation for canary deploys: this file ONLY installs the controller
# + dashboard. The actual conversion of langgraph-service from
# kind:Deployment → kind:Rollout (with Istio traffic-shifting weights
# and AnalysisTemplate gates referencing the rag_*/langgraph_* metrics)
# is the next phase. Splitting them keeps blast radius small — this
# apply lands new CRDs and a controller; nothing in the cluster reads
# them yet.
#
# How Argo Rollouts works:
#   - Rollout CR replaces Deployment. Spec is nearly identical
#     (template, replicas, selector) but adds a strategy.canary or
#     strategy.blueGreen block.
#   - Controller manages two ReplicaSets per Rollout (stable + canary)
#     and runs an AnalysisRun (a series of PromQL queries against the
#     existing kube-prometheus-stack) at each canary step.
#   - For traffic-shifting (vs replica-shifting), the Rollout's
#     strategy.canary.trafficRouting.istio block edits a referenced
#     Istio VirtualService to weight stable/canary destinations.
#     That's why this lab — already running Istio mesh-wide — is a
#     good fit; we get gradual traffic shift without a separate
#     service-mesh install (Linkerd/Flagger/etc.).
#
# Namespace placement: argo-rollouts. NOT added to the Kyverno
# catchall's enforced namespace list (kyverno-policies-catchall.tf:158
# — rag, qdrant, keycloak, argocd, llm, langfuse, training, kubeflow).
# Reason: the chart pulls from quay.io/argoproj/argo-rollouts which
# isn't on the trusted-unsigned allowlist, and adding it without
# verifying signatures would weaken the catchall. Cleaner to keep this
# control-plane-y workload outside the enforced perimeter.
# Future: if we want full enforcement here, verify cosign signatures
# on quay.io/argoproj/argo-rollouts (mirror of argo-cd's
# verify-argocd-image-signatures pattern in kyverno-cosign.tf) and
# then add argo-rollouts to the namespace list.
#
# Istio sidecar injection: NOT enabled. The controller speaks only to
# the Kubernetes API (and Prometheus during analysis), neither of
# which needs a mesh sidecar. Adding one would just add latency to
# controller→API calls and force us to write an AuthorizationPolicy
# for the controller's egress.

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
  # Pin matches the argocd chart pattern in argocd.tf. Bump cadence:
  # check https://github.com/argoproj/argo-helm/releases for argo-
  # rollouts-* tags before bumping. Major version bumps may require
  # CRD migration — chart README always notes when.
  version = "2.37.7"

  values = [
    yamlencode({
      # Install the dashboard sub-component. It's a small (~10MB image,
      # 50Mi memory) read-only UI showing Rollout state visually —
      # useful while we're learning the canary workflow because the
      # CLI's `kubectl argo rollouts status` is text-only and
      # frequent-pause heavy. Operator can port-forward to it for
      # now; HTTPRoute exposure is a future phase if we want it
      # at rollouts.${var.domain}.
      dashboard = {
        enabled = true
        resources = {
          requests = {
            cpu    = "10m"
            memory = "32Mi"
          }
          limits = {
            cpu    = "100m"
            memory = "128Mi"
          }
        }
      }

      controller = {
        # Single replica is correct: Argo Rollouts uses leader election
        # but the chart defaults to 2 replicas which is overkill for
        # the lab's traffic. Bump to 2+ if we ever need HA control-
        # plane semantics (e.g., during a node drain mid-canary).
        replicas = 1
        resources = {
          requests = {
            cpu    = "100m"
            memory = "128Mi"
          }
          limits = {
            cpu    = "500m"
            memory = "512Mi"
          }
        }
        # Expose the controller's /metrics so kube-prometheus-stack
        # can scrape its built-in operational metrics (rollout_phase,
        # rollout_info, controller_clientset_k8s_request_total etc.).
        # Useful even before any Rollout exists — lets us see when the
        # controller is processing CRD updates vs idle.
        metrics = {
          enabled = true
          serviceMonitor = {
            enabled = true
            additionalLabels = {
              # Future-proofing for the day someone flips
              # serviceMonitorSelectorNilUsesHelmValues=true. Today
              # it's false in prometheus-stack.tf:27 so this label is
              # decorative, but matches the langgraph-service
              # ServiceMonitor convention.
              release = "kube-prometheus-stack"
            }
          }
        }
      }

      # Notifications controller (Slack/Teams/etc.) is part of the
      # chart but disabled here — same reasoning as alertmanager in
      # prometheus-stack.tf: no receivers wired up in the lab. Once
      # canaries are running and we want auto-rollback notifications,
      # wire receivers here AND enable alertmanager in one PR.
      notifications = {
        enabled = false
      }

      # CRDs are installed by the chart by default
      # (installCRDs=true); leaving the default. Note that uninstalling
      # the helm release WILL delete the CRDs (and therefore any
      # Rollout CRs in the cluster). If we ever uninstall, drain
      # Rollouts first or keepCRDs=true here.
    })
  ]

  # Order: needs the cluster reachable. ALB controller dependency
  # mirrors the prometheus-stack pattern — historically that's where
  # we hit webhook-race ordering issues during cluster bootstrap.
  depends_on = [
    module.eks,
    helm_release.alb_controller,
  ]
}

# How to verify after `terraform apply`:
#   kubectl -n argo-rollouts get pods
#     # expect: argo-rollouts-<hash>-<id> Running, dashboard pod Running
#   kubectl get crd | grep argoproj
#     # expect: rollouts, analysisruns, analysistemplates,
#     #         clusteranalysistemplates, experiments
#   kubectl argo rollouts version
#     # if `kubectl argo rollouts` plugin not installed locally:
#     #   brew install argoproj/tap/kubectl-argo-rollouts
# How to peek at the dashboard:
#   kubectl -n argo-rollouts port-forward svc/argo-rollouts-dashboard 3100:3100
#   open http://localhost:3100

# =============================================================================
# Phase #38: public HTTPRoute exposing the dashboard at rollouts.${var.domain}
#
# WARNING — SECURITY GAP:
# The argo-rollouts dashboard has NO native per-user authentication.
# Once this HTTPRoute is in place, anyone who knows the hostname can
# READ all Rollout state across the cluster (canary phase, AnalysisRun
# verdicts, image hashes, replica counts). The dashboard is read-only,
# but operational state is itself sensitive.
#
# Today's mitigations:
#   1. Hostname is not published anywhere outside this repo + tfvars,
#      so discovery requires repo access.
#   2. NLB is internet-facing but TLS-only; no path-level enumeration.
#   3. Cluster RBAC still gates kubectl-level mutation; this surface
#      is read-only, so an attacker who finds the URL can observe but
#      not promote/abort/undo rollouts.
#
# Proper hardening — pick one or combine:
#   A. oauth2-proxy in front: deploy oauth2-proxy as a sidecar or
#      separate pod, point the HTTPRoute at it instead of the
#      dashboard service. Same Keycloak realm, shared session cookie
#      with grafana/argocd. ~1 day of work; the canonical pattern.
#   B. Istio JWT validation: RequestAuthentication +
#      AuthorizationPolicy requiring a Keycloak-signed token on the
#      dashboard's argo-rollouts Service. Browser-hostile (no
#      automatic redirect to Keycloak), but easy to bolt on for
#      programmatic / curl-based access.
#   C. Drop this HTTPRoute, port-forward only. Most secure, least
#      convenient.
# Phase #38b candidate: option A (oauth2-proxy).
#
# For now the operational benefit (live canary visualization for the
# Phase #28-37 stack) outweighs the lab risk; documenting the gap
# explicitly here so the next reader doesn't think this is hardened.
# =============================================================================

resource "kubectl_manifest" "rollouts_certificate" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "rollouts-tls"
      namespace = kubernetes_namespace.argo_rollouts.metadata[0].name
    }
    spec = {
      secretName = "rollouts-tls"
      dnsNames   = ["rollouts.${var.domain}"]
      issuerRef = {
        group = "cert-manager.io"
        kind  = "ClusterIssuer"
        name  = "letsencrypt-prod"
      }
      usages      = ["digital signature", "key encipherment"]
      duration    = "2160h" # 90d
      renewBefore = "720h"  # 30d
    }
  })
}

resource "kubectl_manifest" "rollouts_httproute" {
  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "rollouts-dashboard"
      namespace = kubernetes_namespace.argo_rollouts.metadata[0].name
      labels = {
        app = "argo-rollouts-dashboard"
      }
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
          # Phase #42: backendRef switched from
          # argo-rollouts-dashboard:3100 to oauth2-proxy:80.
          # oauth2-proxy intercepts unauthenticated requests, runs
          # the OIDC dance against Keycloak, then forwards
          # authenticated requests to argo-rollouts-dashboard
          # internally as upstream. Service config in
          # oauth2-proxy.tf.
          name = "oauth2-proxy"
          port = 80
        }]
      }]
    }
  })

  depends_on = [
    helm_release.argo_rollouts,
    kubectl_manifest.rollouts_certificate,
    helm_release.oauth2_proxy,
  ]
}
