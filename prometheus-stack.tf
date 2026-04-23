resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }
}

# grafana-oidc k8s Secret was retired — Grafana now receives the OIDC
# client secret from Vault via the Agent Injector sidecar (see the
# podAnnotations block in the grafana values below, and vault-config.tf
# for the policy/role/KV entry).

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
        adminUser = "admin"
        # adminPassword is still set so the chart creates its admin Secret
        # (Grafana needs *something* to bootstrap on first boot), but the
        # effective runtime password comes from GF_SECURITY_ADMIN_PASSWORD__FILE
        # below, which reads the Vault-injected file and wins over the
        # plain env var. Rotating the Vault value then rolling the pod
        # updates the password — except Grafana persists admin creds in
        # SQLite on first boot, so subsequent rotations need a UI/API
        # change too. Known Grafana wart; acceptable for a lab.
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

        # Vault Agent Injector: admin password and OIDC client secret come
        # from Vault, written to /vault/secrets/* by the sidecar. Grafana's
        # GF_*__FILE convention reads the values at startup.
        podAnnotations = {
          "vault.hashicorp.com/agent-inject" = "true"
          "vault.hashicorp.com/role"         = "grafana"

          "vault.hashicorp.com/agent-inject-secret-admin-password"   = "secret/data/grafana/admin"
          "vault.hashicorp.com/agent-inject-template-admin-password" = <<-EOT
            {{- with secret "secret/data/grafana/admin" -}}
            {{ .Data.data.password }}
            {{- end -}}
          EOT

          "vault.hashicorp.com/agent-inject-secret-oauth-client-secret"   = "secret/data/grafana/oidc"
          "vault.hashicorp.com/agent-inject-template-oauth-client-secret" = <<-EOT
            {{- with secret "secret/data/grafana/oidc" -}}
            {{ .Data.data.client_secret }}
            {{- end -}}
          EOT
        }

        # GF_*__FILE (double underscore + FILE) reads the value from a path —
        # overrides the plain GF_SECURITY_ADMIN_PASSWORD / GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET
        # the chart injects from its own Secret.
        env = {
          GF_SECURITY_ADMIN_PASSWORD__FILE          = "/vault/secrets/admin-password"
          GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET__FILE = "/vault/secrets/oauth-client-secret"
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
    # Vault secrets must exist before the grafana pod rolls — agent-init
    # fails the pod otherwise.
    vault_kv_secret_v2.grafana_admin,
    vault_kv_secret_v2.grafana_oidc,
    vault_kubernetes_auth_backend_role.grafana,
  ]
}

output "grafana_admin_password_hint" {
  value       = "kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d"
  description = "Command to retrieve the Grafana admin password from the Secret"
}
