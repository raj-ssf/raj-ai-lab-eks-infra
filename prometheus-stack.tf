resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }
}

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "65.5.0"

  values = [
    yamlencode({
      # --- Prometheus ---
      prometheus = {
        prometheusSpec = {
          # By default this chart only scrapes ServiceMonitors with a matching
          # `release` label. Setting these to false makes Prometheus pick up
          # ServiceMonitors cluster-wide (rag-service etc.).
          serviceMonitorSelectorNilUsesHelmValues = false
          podMonitorSelectorNilUsesHelmValues     = false
          probeSelectorNilUsesHelmValues          = false
          ruleSelectorNilUsesHelmValues           = false

          retention = "7d"

          storageSpec = {
            volumeClaimTemplate = {
              spec = {
                storageClassName = "gp3"
                accessModes      = ["ReadWriteOnce"]
                resources = {
                  requests = {
                    storage = "20Gi"
                  }
                }
              }
            }
          }

          resources = {
            requests = {
              cpu    = "200m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "2Gi"
            }
          }
        }
      }

      # --- Grafana ---
      grafana = {
        adminUser     = "admin"
        adminPassword = var.grafana_admin_password

        persistence = {
          enabled          = true
          type             = "pvc"
          storageClassName = "gp3"
          size             = "10Gi"
          accessModes      = ["ReadWriteOnce"]
        }

        # Ingress wired in a separate step (grafana-ingress.tf).
        service = {
          type = "ClusterIP"
        }

        # Pre-declare the Tempo datasource via the sidecar (Tempo installed
        # by tempo.tf creates a ConfigMap with the Grafana label below).
        sidecar = {
          datasources = {
            enabled      = true
            label        = "grafana_datasource"
            labelValue   = "1"
            searchNamespace = "ALL"
          }
          dashboards = {
            enabled      = true
            label        = "grafana_dashboard"
            labelValue   = "1"
            searchNamespace = "ALL"
          }
        }

        resources = {
          requests = {
            cpu    = "50m"
            memory = "128Mi"
          }
          limits = {
            cpu    = "500m"
            memory = "512Mi"
          }
        }
      }

      # --- Alertmanager: disabled for lab (no receivers wired up) ---
      alertmanager = {
        enabled = false
      }

      # --- Other components ---
      nodeExporter = {
        enabled = true
      }
      kubeStateMetrics = {
        enabled = true
      }
      # prometheus-operator itself runs the CRD controllers
      prometheusOperator = {
        resources = {
          requests = {
            cpu    = "50m"
            memory = "128Mi"
          }
          limits = {
            cpu    = "200m"
            memory = "256Mi"
          }
        }
      }

      # Keep the default scrape jobs (apiserver, kubelet, cadvisor, etc.)
      # but don't override them here — chart ships sensible defaults.
      defaultRules = {
        create = true
      }
    })
  ]

  depends_on = [
    module.eks,
    helm_release.alb_controller, # avoid the webhook race we hit on cert-manager
    kubernetes_storage_class_v1.gp3,
  ]
}

output "grafana_admin_password_hint" {
  value       = "kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d"
  description = "Command to retrieve the Grafana admin password from the Secret"
}
