# NVIDIA DCGM (Data Center GPU Manager) exporter — Prometheus metrics for
# the GPU plane. Complements nvidia-device-plugin.tf (which handles
# resource-scheduling exposure of nvidia.com/gpu to kubelet). DCGM sits at
# a lower level, pulling per-GPU telemetry straight from the driver:
# utilization %, memory (used/free/total), temperature, power (watts),
# SM (streaming multiprocessor) activity, clocks, NVLink throughput,
# ECC error counters, XID fault codes.
#
# Deployment shape:
#   - Helm chart from https://nvidia.github.io/dcgm-exporter/helm-charts
#   - DaemonSet in kube-system, nodeSelector pins to nvidia.com/gpu=true
#     so it only lands on GPU nodes (zero idle overhead when Karpenter
#     has scaled GPU capacity to zero)
#   - Tolerates the nvidia.com/gpu:NoSchedule taint
#   - ServiceMonitor label release=kube-prometheus-stack so Prometheus
#     picks it up via its built-in selector
#   - Grafana dashboard 12239 imported via ConfigMap with the
#     grafana_dashboard label (kube-prometheus-stack's Grafana sidecar
#     auto-discovers and imports)

resource "helm_release" "dcgm_exporter" {
  name       = "dcgm-exporter"
  namespace  = "kube-system"
  repository = "https://nvidia.github.io/dcgm-exporter/helm-charts"
  chart      = "dcgm-exporter"
  version    = "4.8.1"

  values = [
    yamlencode({
      # Only land on GPU nodes
      nodeSelector = {
        "nvidia.com/gpu" = "true"
      }
      tolerations = [
        {
          key      = "nvidia.com/gpu"
          operator = "Exists"
          effect   = "NoSchedule"
        },
      ]
      # DCGM memory scales with GPU count + metric field count. 256Mi was
      # OOMKilled on a 4× L4 g6.12xlarge. Bumped to 512Mi request / 1Gi
      # limit so a single pod can cover 4–8 GPU boxes cleanly.
      resources = {
        requests = { cpu = "100m", memory = "512Mi" }
        limits   = { cpu = "500m", memory = "1Gi" }
      }
      # ServiceMonitor for kube-prometheus-stack's Prometheus to scrape.
      # Label 'release=kube-prometheus-stack' matches the Prometheus's
      # serviceMonitorSelector (set when the stack was installed).
      serviceMonitor = {
        enabled  = true
        interval = "30s"
        additionalLabels = {
          release = "kube-prometheus-stack"
        }
      }
      # DCGM itself needs a few Linux capabilities to read GPU telemetry
      # via the NVML library. Chart defaults are already correct; no
      # securityContext override required.
    })
  ]

  depends_on = [
    module.eks,
    helm_release.kube_prometheus_stack,
  ]
}

# Grafana dashboard for DCGM Exporter. Delivered as a ConfigMap with the
# grafana_dashboard label so kube-prometheus-stack's Grafana sidecar
# auto-discovers and imports on its next scan (~30s interval).
#
# Source note: we pull NVIDIA's up-to-date JSON directly from the DCGM
# Exporter GitHub repo rather than grafana.com/api/dashboards/12239. The
# grafana.com-published revision is ancient (schemaVersion 16) and its
# legacy Prometheus query format fails migration on modern Grafana with
# 'templating: failed to upgrade legacy queries', leaving the dashboard
# blank. NVIDIA's main-branch JSON is schemaVersion 22 with clean
# label-values template variables.
data "http" "dcgm_dashboard_json" {
  url = "https://raw.githubusercontent.com/NVIDIA/dcgm-exporter/main/grafana/dcgm-exporter-dashboard.json"
}

resource "kubernetes_config_map_v1" "dcgm_dashboard" {
  metadata {
    name      = "dcgm-exporter-dashboard"
    namespace = "monitoring"
    labels = {
      # kube-prometheus-stack's Grafana sidecar watches for ConfigMaps with
      # this label and imports their JSON as dashboards. The value is
      # arbitrary — presence of the key is what triggers the import.
      grafana_dashboard = "1"
    }
  }
  data = {
    "dcgm-exporter.json" = data.http.dcgm_dashboard_json.response_body
  }

  depends_on = [
    helm_release.kube_prometheus_stack,
  ]
}
