resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      # Phase #55: meshed for STRICT mTLS. Without the sidecar,
      # Prometheus's HTTP scrape requests to meshed targets carry
      # no SPIFFE identity → would fail at the destination Envoy
      # under STRICT mode. Sidecar gives prometheus a SPIFFE cert
      # so it can scrape any meshed /metrics over mTLS.
      #
      # Same logic for tempo, alertmanager, grafana — all in this
      # namespace. After this label, Istio's mutating webhook
      # injects istio-proxy on next pod create. Existing pods
      # need a manual rollout (kubectl -n monitoring rollout
      # restart deployment,statefulset) to pick up the sidecar.
      "istio-injection" = "enabled"
    }
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

  # Phase #57: bumped from default 300s. Phase #55 added istio-
  # injection to monitoring ns, so every recreated pod now pays
  # ~30s for istio-validation + sidecar init in addition to the
  # base startup. The chart's StatefulSet upgrades (alertmanager
  # + prometheus) recreate pods serially with `wait: true`
  # semantics; full upgrade ≈ 8-10 min wall-clock now. 900s gives
  # generous margin without blocking the apply forever on a
  # genuinely stuck upgrade.
  timeout = 900

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

          # Hand-rolled scrape for Envoy sidecars. Can't use a PodMonitor —
          # the operator auto-generates a `keep container_port_number==15090`
          # relabel, and Prometheus 2.x pod-SD doesn't enumerate initContainer
          # ports. Our istio-proxy runs as an init container with
          # restartPolicy=Always (native sidecar), so that filter drops every
          # target. This config overrides __address__ directly, no port-
          # enumeration dependency.
          additionalScrapeConfigs = [{
            job_name     = "istio-envoy-stats"
            metrics_path = "/stats/prometheus"
            kubernetes_sd_configs = [{
              role = "pod"
              namespaces = {
                names = ["rag", "qdrant", "keycloak", "argocd"]
              }
            }]
            relabel_configs = [
              {
                action        = "drop"
                source_labels = ["__meta_kubernetes_pod_phase"]
                regex         = "(Failed|Succeeded|Pending)"
              },
              # Rewrite target address to pod_ip:15020. Port 15020 is
              # istio-agent's merged Prometheus endpoint — emits istio_*
              # telemetry (istio_requests_total etc.). Port 15090 is raw
              # Envoy stats (envoy_* only) and wouldn't populate the Istio
              # dashboards. Prometheus dedupes multiple targets with the
              # same __address__, so we collapse to one per pod.
              {
                source_labels = ["__meta_kubernetes_pod_ip"]
                target_label  = "__address__"
                replacement   = "$${1}:15020"
              },
              {
                source_labels = ["__meta_kubernetes_namespace"]
                target_label  = "namespace"
              },
              {
                source_labels = ["__meta_kubernetes_pod_name"]
                target_label  = "pod"
              },
            ]
          }]

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

        # Phase 12 of Gateway API migration: chart's Ingress disabled.
        # Traffic now flows through shared-gateway in gateway-system ns.
        ingress = {
          enabled = false
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
            auth_url                   = "https://keycloak.${var.domain}/realms/${var.cluster_name}/protocol/openid-connect/auth"
            token_url                  = "https://keycloak.${var.domain}/realms/${var.cluster_name}/protocol/openid-connect/token"
            api_url                    = "https://keycloak.${var.domain}/realms/${var.cluster_name}/protocol/openid-connect/userinfo"
            allow_sign_up              = true
            allow_assign_grafana_admin = true
            # Map the `roles` claim (Keycloak realm-role mapper) to Grafana
            # org roles. JMESPath expression: Admin if user has the `admin`
            # realm role, Editor for `editor`, else Viewer.
            role_attribute_path = "contains(roles[*], 'admin') && 'Admin' || contains(roles[*], 'editor') && 'Editor' || 'Viewer'"
            # After local sign-out, bounce through Keycloak's end-session
            # endpoint so the IdP session also ends.
            signout_redirect_url = "https://keycloak.${var.domain}/realms/${var.cluster_name}/protocol/openid-connect/logout?post_logout_redirect_uri=https%3A%2F%2Fgrafana.${var.domain}%2Flogin"
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
            enabled         = true
            label           = "grafana_datasource"
            labelValue      = "1"
            searchNamespace = "ALL"
          }
          dashboards = {
            enabled         = true
            label           = "grafana_dashboard"
            labelValue      = "1"
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

      # Phase #48: Alertmanager enabled. Routing tree splits alerts
      # by severity + burn_speed labels so a future receiver wiring
      # is just "add real webhook URL"s, not a routing-config rewrite.
      #
      # Default receiver is "null" (a webhook to a non-existent
      # URL with send_resolved=false) — alerts route, group, and
      # dedupe through the pipeline but the final hop is a no-op.
      # That keeps the lab pageless while exercising the full
      # Alertmanager codepath end-to-end. To wire real notifications:
      # add receivers via slack_webhook_url / pagerduty_routing_key
      # tfvars and the routing tree below already routes
      # severity=critical → page-receivers, severity=warning →
      # ticket-receivers.
      #
      # Inhibition rules suppress noisy duplicates: when a critical
      # alert fires for a service, related warnings on the same
      # service are silenced (e.g., RagServiceDown critical
      # inhibits RagRetrieveLatencyHigh warning).
      alertmanager = {
        enabled = true
        alertmanagerSpec = {
          # Phase #57 attempted replicas=2 for HA (peer-mesh-via-
          # generated --cluster.peer flags). Helm upgrade hung
          # indefinitely twice (15+ min) — likely PVC + sidecar +
          # operator-webhook reconcile deadlock specific to the
          # kube-prometheus-stack StatefulSet upgrade path under
          # Phase #55's istio-injection. Reverted 2026-04-30 night
          # to unblock other infra changes; pick up properly
          # tomorrow when investigating the deadlock with rested
          # eyes (likely: temporarily disable mutating webhook
          # during chart upgrade, OR pre-create alertmanager-1
          # PVC manually).
          replicas = 1
          resources = {
            requests = {
              cpu    = "20m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "128Mi"
            }
          }
          # No persistent storage — alert silences are ephemeral in
          # the lab. Production would want a PVC here so silences
          # survive pod restarts.
          storage = {}
        }
        config = {
          global = {
            resolve_timeout = "5m"
          }
          route = {
            # Group alerts by alertname + service so a flapping
            # alert on the same service folds into one notification
            # rather than spamming N times.
            group_by        = ["alertname", "service"]
            group_wait      = "30s" # buffer so closely-firing alerts batch
            group_interval  = "5m"  # send next batch for this group after 5m
            repeat_interval = "12h" # re-page if still firing after 12h
            receiver        = "null"
            routes = [
              # Critical OR fast-burn → page-receivers. Today both map
              # to "null"; flip page-receivers' webhook_configs to a
              # real Slack/PagerDuty URL when ready.
              {
                matchers = ["severity=\"critical\""]
                receiver = "page-receivers"
                # Faster cadence for criticals — re-page every hour.
                repeat_interval = "1h"
              },
              {
                matchers        = ["burn_speed=\"fast\""]
                receiver        = "page-receivers"
                repeat_interval = "1h"
              },
              # Warnings → ticket-receivers (slower cadence).
              {
                matchers = ["severity=\"warning\""]
                receiver = "ticket-receivers"
              },
            ]
          }
          inhibit_rules = [
            # When a critical fires for a service, suppress all
            # warnings tagged with the same service. Reduces noise
            # during outages — operator only sees the root cause,
            # not the cascading P95 / chunk-rate / etc. warnings.
            {
              source_matchers = ["severity=\"critical\""]
              target_matchers = ["severity=\"warning\""]
              equal           = ["service"]
            },
          ]
          receivers = [
            {
              # Default sink. send_resolved=false so we don't even
              # try to POST resolution events on a fake URL.
              name = "null"
            },
            {
              # Page-tier receiver. Wire a real Slack incoming-
              # webhook URL via slack_api_url, or a PagerDuty
              # routing_key via a pagerduty_configs entry. Today
              # both lists are empty → behaves identically to
              # "null".
              name = "page-receivers"
            },
            {
              # Ticket-tier receiver. Same shape — empty today.
              # Wire a Slack webhook to a #alerts-tickets channel
              # or an email_configs SMTP block when ready.
              name = "ticket-receivers"
            },
          ]
        }
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

# =============================================================================
# Phase 8 of Gateway API migration: HTTPRoute for grafana.ekstest.com.
# Sibling to the helm_release; see langfuse.tf for the pattern's rationale.
# =============================================================================

resource "kubectl_manifest" "grafana_httproute" {
  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "grafana"
      namespace = "monitoring"
      labels    = { app = "grafana" }
    }
    spec = {
      parentRefs = [{
        name        = "shared-gateway"
        namespace   = "gateway-system"
        sectionName = "grafana-https"
      }]
      hostnames = ["grafana.${var.domain}"]
      rules = [{
        matches = [{
          path = { type = "PathPrefix", value = "/" }
        }]
        backendRefs = [{
          # kube-prometheus-stack-grafana Service exposes port 80
          # (named "http-web", targetPort 3000).
          name = "kube-prometheus-stack-grafana"
          port = 80
        }]
      }]
    }
  })

  depends_on = [
    helm_release.kube_prometheus_stack,
  ]
}
