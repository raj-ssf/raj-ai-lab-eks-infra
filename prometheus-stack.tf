resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }
}

# OIDC client secret for Grafana → Keycloak. Kept in a k8s Secret (not in
# the helm values) so it doesn't land in tfstate-rendered manifests.
# Consumed by grafana.envValueFrom.GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET below.
resource "kubernetes_secret_v1" "grafana_oidc" {
  metadata {
    name      = "grafana-oidc"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = {
    client_secret = random_password.keycloak_grafana_client_secret.result
  }
  type = "Opaque"
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

        service = {
          type = "ClusterIP"
        }

        # Ingress → NGINX → Let's Encrypt cert for grafana.<domain>.
        ingress = {
          enabled          = true
          ingressClassName = "nginx"
          annotations = {
            "cert-manager.io/cluster-issuer" = "letsencrypt-prod"
          }
          hosts = ["grafana.${var.domain}"]
          tls = [{
            hosts      = ["grafana.${var.domain}"]
            secretName = "grafana-tls"
          }]
        }

        # Set Grafana's idea of its own URL so sign-in redirects, share links,
        # and SSO work correctly behind the ingress.
        "grafana.ini" = {
          server = {
            domain   = "grafana.${var.domain}"
            root_url = "https://grafana.${var.domain}"
          }
          # Keycloak OIDC. client_secret comes from the grafana-oidc k8s
          # Secret via envValueFrom below — not listed here so it doesn't
          # render into the helm release's value blob.
          "auth.generic_oauth" = {
            enabled                    = true
            name                       = "Keycloak"
            client_id                  = "grafana"
            scopes                     = "openid profile email roles"
            empty_scopes               = false
            auth_url                   = "https://keycloak.${var.domain}/realms/raj-ai-lab-eks/protocol/openid-connect/auth"
            token_url                  = "https://keycloak.${var.domain}/realms/raj-ai-lab-eks/protocol/openid-connect/token"
            api_url                    = "https://keycloak.${var.domain}/realms/raj-ai-lab-eks/protocol/openid-connect/userinfo"
            allow_sign_up              = true
            allow_assign_grafana_admin = true
            # Map the `roles` claim (Keycloak realm-role mapper) to Grafana
            # org roles. JMESPath expression: Admin if user has the `admin`
            # realm role, Editor for `editor`, else Viewer.
            role_attribute_path = "contains(roles[*], 'admin') && 'Admin' || contains(roles[*], 'editor') && 'Editor' || 'Viewer'"
            # After local sign-out, bounce through Keycloak's end-session
            # endpoint so the IdP session also ends.
            signout_redirect_url = "https://keycloak.${var.domain}/realms/raj-ai-lab-eks/protocol/openid-connect/logout?post_logout_redirect_uri=https%3A%2F%2Fgrafana.${var.domain}%2Flogin"
          }
        }

        # Inject the Keycloak client secret as an env var. Grafana's env-var
        # override for generic_oauth.client_secret is named this specific way.
        envValueFrom = {
          GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET = {
            secretKeyRef = {
              name = kubernetes_secret_v1.grafana_oidc.metadata[0].name
              key  = "client_secret"
            }
          }
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
    kubernetes_secret_v1.grafana_oidc,
  ]
}

output "grafana_admin_password_hint" {
  value       = "kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d"
  description = "Command to retrieve the Grafana admin password from the Secret"
}
