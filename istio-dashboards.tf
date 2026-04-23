# Istio's prebuilt Grafana dashboards, fetched from the upstream release
# branch and loaded via the dashboard-sidecar label on the ConfigMap.
# Dashboards auto-appear in Grafana under the "Istio" folder within ~60s.

locals {
  istio_dashboard_version = "release-1.24"
  # Filename gotcha: in release-1.24, the mesh + pilot dashboards are
  # published as `*-dashboard.gen.json` (jsonnet-generated) while the
  # others stayed as bare `.json`. The .json requests for mesh/pilot
  # returned 404 (14-byte "404: Not Found\n" bodies) and got silently
  # written into grafana as invalid dashboards.
  istio_dashboards = {
    "istio-mesh-dashboard.json"        = "https://raw.githubusercontent.com/istio/istio/${local.istio_dashboard_version}/manifests/addons/dashboards/istio-mesh-dashboard.gen.json"
    "istio-service-dashboard.json"     = "https://raw.githubusercontent.com/istio/istio/${local.istio_dashboard_version}/manifests/addons/dashboards/istio-service-dashboard.json"
    "istio-workload-dashboard.json"    = "https://raw.githubusercontent.com/istio/istio/${local.istio_dashboard_version}/manifests/addons/dashboards/istio-workload-dashboard.json"
    "istio-performance-dashboard.json" = "https://raw.githubusercontent.com/istio/istio/${local.istio_dashboard_version}/manifests/addons/dashboards/istio-performance-dashboard.json"
    "pilot-dashboard.json"             = "https://raw.githubusercontent.com/istio/istio/${local.istio_dashboard_version}/manifests/addons/dashboards/pilot-dashboard.gen.json"
  }
}

data "http" "istio_dashboards" {
  for_each = local.istio_dashboards
  url      = each.value
}

resource "kubernetes_config_map_v1" "istio_dashboards" {
  metadata {
    name      = "istio-grafana-dashboards"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    # Matches grafana sub-chart's sidecar.dashboards.label / labelValue
    # (see prometheus-stack.tf).
    labels = {
      "grafana_dashboard" = "1"
    }
  }

  data = {
    for filename, _ in local.istio_dashboards :
    filename => data.http.istio_dashboards[filename].response_body
  }

  depends_on = [helm_release.kube_prometheus_stack]
}
