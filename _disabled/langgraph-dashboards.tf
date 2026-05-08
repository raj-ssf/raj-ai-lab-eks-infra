# Phase #14: Grafana dashboards for langgraph-service.
#
# Mirrors the istio-dashboards.tf shape — wraps dashboard JSON files as
# a ConfigMap with the grafana_dashboard=1 label that kube-prometheus-
# stack's Grafana sidecar polls (see prometheus-stack.tf, the
# sidecar.dashboards.label config).
#
# Difference from istio-dashboards.tf: those dashboards are upstream
# (fetched via data.http from the Istio release branch). These are
# locally-authored against this lab's custom Prometheus metrics from
# main.py (langgraph_requests_total, langgraph_safety_action_total,
# langgraph_node_duration_seconds, etc. — see Phase #14a in the apps
# repo).
#
# After this lands + tofu apply, dashboards auto-appear in Grafana
# under the "langgraph" tag within ~60s (sidecar polling interval).
# Grafana is reachable via the existing grafana.${var.domain} ingress
# (see prometheus-stack.tf) — auth via Keycloak OIDC.
#
# Iteration workflow:
#   1. Edit dashboards/langgraph-service-overview.json (Grafana's
#      "share dashboard → JSON model" output is the canonical source).
#   2. tofu apply (re-uploads the ConfigMap).
#   3. Grafana sidecar picks up the change in <60s.
# To author NEW panels interactively in Grafana first:
#   1. Click "Add panel" in Grafana, configure visually.
#   2. Save → "Share dashboard" → "JSON model" → copy.
#   3. Paste into dashboards/langgraph-service-overview.json.
#   4. tofu apply locks the change in IaC.

locals {
  langgraph_dashboards = {
    "langgraph-service-overview.json" = file(
      "${path.module}/dashboards/langgraph-service-overview.json"
    )
  }
}

resource "kubernetes_config_map_v1" "langgraph_dashboards" {
  metadata {
    name      = "langgraph-grafana-dashboards"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    # Matches the grafana sub-chart's sidecar.dashboards.label /
    # labelValue config (see prometheus-stack.tf).
    labels = {
      "grafana_dashboard" = "1"
    }
  }

  data = local.langgraph_dashboards

  depends_on = [helm_release.kube_prometheus_stack]
}

# Future expansion: add panels by editing the JSON in dashboards/.
# If the dashboard count grows beyond a single file, change
# local.langgraph_dashboards to a for_each over a directory listing
# (similar to istio_dashboards) — same pattern, just more entries.
