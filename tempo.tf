resource "helm_release" "tempo" {
  name       = "tempo"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  repository = "https://grafana.github.io/helm-charts"
  chart      = "tempo"    # single-binary (monolithic) chart
  version    = "1.24.4"

  values = [
    yamlencode({
      tempo = {
        # Retention: 7 days. Store locally on a PVC; S3 backend is optional.
        retention = "168h"

        storage = {
          trace = {
            backend = "local"
            local = {
              path = "/var/tempo/traces"
            }
            wal = {
              path = "/var/tempo/wal"
            }
          }
        }

        # Enable the OTLP receiver (gRPC + HTTP). Clients (rag-service) will
        # send via OTLP gRPC on 4317.
        receivers = {
          otlp = {
            protocols = {
              grpc = {
                endpoint = "0.0.0.0:4317"
              }
              http = {
                endpoint = "0.0.0.0:4318"
              }
            }
          }
        }

        # Metrics generator: derives RED metrics (rate, errors, duration) from
        # traces and writes them as Prometheus metrics. Grafana Service Graph
        # and APM views depend on this.
        metricsGenerator = {
          enabled = true
          remoteWriteUrl = "http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090/api/v1/write"
        }
      }

      persistence = {
        enabled          = true
        storageClassName = "gp3"
        accessModes      = ["ReadWriteOnce"]
        size             = "10Gi"
      }

      resources = {
        requests = {
          cpu    = "100m"
          memory = "256Mi"
        }
        limits = {
          cpu    = "500m"
          memory = "1Gi"
        }
      }

      # Service exposes:
      #   3100 HTTP (Grafana queries here)
      #   4317 OTLP gRPC (apps send traces here)
      #   4318 OTLP HTTP
      service = {
        type = "ClusterIP"
      }
    })
  ]

  depends_on = [
    helm_release.kube_prometheus_stack,    # metrics-generator needs Prometheus remote_write
    helm_release.alb_controller,           # avoid webhook race (other Helm releases creating Services)
  ]
}

# Grafana sidecar picks up any ConfigMap labeled grafana_datasource=1 and
# auto-registers it. This wires the Tempo datasource so Grafana's Explore →
# Traces view works without manual setup.
resource "kubernetes_config_map_v1" "grafana_tempo_datasource" {
  metadata {
    name      = "grafana-tempo-datasource"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      grafana_datasource = "1"
    }
  }

  data = {
    "tempo.yaml" = yamlencode({
      apiVersion = 1
      datasources = [{
        name      = "Tempo"
        type      = "tempo"
        access    = "proxy"
        url       = "http://tempo.monitoring.svc.cluster.local:3100"
        uid       = "tempo"
        isDefault = false
        jsonData = {
          # Link traces → metrics via service.name + status_code labels
          tracesToMetrics = {
            datasourceUid = "prometheus"
            tags = [
              { key = "service.name", value = "service" },
              { key = "status_code",  value = "status_code" },
            ]
          }
          # Link traces → logs (once we add Loki later; stub for now)
          serviceMap = {
            datasourceUid = "prometheus"
          }
          nodeGraph = {
            enabled = true
          }
        }
      }]
    })
  }

  depends_on = [helm_release.tempo]
}
