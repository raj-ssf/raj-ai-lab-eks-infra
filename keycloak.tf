# =============================================================================
# Phase 4b of Cilium migration: Keycloak (OIDC IdP for ArgoCD + Grafana).
#
# Differences from the old (Istio + Vault era) keycloak.tf in _disabled:
#   - No istio-injection on the namespace.
#   - Vault Agent Injector annotations stripped — Vault deferred to Phase 4c.
#   - keycloak-admin-auth + keycloak-db-auth k8s Secrets are managed
#     directly by terraform (sourced from var.keycloak_admin_password and
#     var.keycloak_db_password). When Vault lands, these can be replaced
#     by VSO-synced Secrets without touching the helm release.
#   - KC_DB_PASSWORD reads from a regular envFrom (the Bitnami chart's
#     externalDatabase.existingSecret wiring), not from a Vault Agent file.
#   - HTTPRoute attaches to shared-gateway:keycloak-https listener
#     (added to gateway-system.tf in this phase).
# =============================================================================

resource "kubernetes_namespace" "keycloak" {
  metadata {
    name = "keycloak"
  }
}

# --- Secrets: admin password + DB password ----------------------------------
# Bitnami chart's existingSecret pattern reads `admin-password` for the
# Keycloak admin user, and `password` + `postgres-password` for the
# postgres dependency (postgres-password is for the privileged postgres
# superuser; password is for the keycloak app user).

resource "kubernetes_secret_v1" "keycloak_admin_auth" {
  metadata {
    name      = "keycloak-admin-auth"
    namespace = kubernetes_namespace.keycloak.metadata[0].name
  }
  data = {
    "admin-password" = var.keycloak_admin_password
  }
  type = "Opaque"
}

resource "kubernetes_secret_v1" "keycloak_db_auth" {
  metadata {
    name      = "keycloak-db-auth"
    namespace = kubernetes_namespace.keycloak.metadata[0].name
  }
  data = {
    # Bitnami postgresql chart reads BOTH keys when existingSecret is set.
    # Setting both to the same value keeps things simple — the postgres
    # superuser isn't used by the lab; only the keycloak user matters.
    "password"          = var.keycloak_db_password
    "postgres-password" = var.keycloak_db_password
  }
  type = "Opaque"
}

# --- Postgres backing store ---------------------------------------------------
# Dedicated Postgres so Keycloak realm + user state survives pod restarts +
# upgrades. Single replica — good enough for a lab. Phase X would swap to
# RDS Aurora for the real-corpus phase.
resource "helm_release" "keycloak_postgres" {
  name       = "keycloak-postgres"
  namespace  = kubernetes_namespace.keycloak.metadata[0].name
  repository = "oci://registry-1.docker.io/bitnamicharts"
  chart      = "postgresql"
  version    = "18.6.1"

  values = [
    yamlencode({
      # Bitnami's 2025 image-hosting shakeup: newer tags of bitnami/* require
      # the paid tier. Free copies live at bitnamilegacy/*. Tag pinned because
      # bitnamilegacy tops out at PG 17.6 (no 18.x), so the chart's default
      # tag wouldn't resolve.
      image = {
        registry   = "docker.io"
        repository = "bitnamilegacy/postgresql"
        tag        = "17.6.0-debian-12-r4"
      }
      global = {
        # Bitnami 2025: chart now refuses to render with non-Bitnami official
        # images unless this flag is set (see feedback_bitnami_broadcom_traps).
        security = { allowInsecureImages = true }
      }
      auth = {
        username       = "keycloak"
        database       = "keycloak"
        existingSecret = kubernetes_secret_v1.keycloak_db_auth.metadata[0].name
      }
      primary = {
        persistence = {
          enabled      = true
          storageClass = "gp3"
          size         = "10Gi"
          accessModes  = ["ReadWriteOnce"]
        }
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
      }
    })
  ]

  depends_on = [
    module.eks,
    kubernetes_storage_class_v1.gp3,
    kubernetes_secret_v1.keycloak_db_auth,
  ]
}

# --- Keycloak -----------------------------------------------------------------
resource "helm_release" "keycloak" {
  name       = "keycloak"
  namespace  = kubernetes_namespace.keycloak.metadata[0].name
  repository = "oci://registry-1.docker.io/bitnamicharts"
  chart      = "keycloak"
  version    = "25.2.0"

  values = [
    yamlencode({
      auth = {
        adminUser      = "admin"
        existingSecret = kubernetes_secret_v1.keycloak_admin_auth.metadata[0].name
      }

      image = {
        registry   = "docker.io"
        repository = "bitnamilegacy/keycloak"
        tag        = "26.3.3-debian-12-r0"
      }
      dbchecker = {
        image = {
          registry   = "docker.io"
          repository = "bitnamilegacy/os-shell"
        }
      }
      global = {
        security = { allowInsecureImages = true }
      }

      # Use our keycloak-postgres (above), not the chart's bundled one.
      postgresql = { enabled = false }
      externalDatabase = {
        host                      = "keycloak-postgres-postgresql.${kubernetes_namespace.keycloak.metadata[0].name}.svc.cluster.local"
        port                      = 5432
        user                      = "keycloak"
        database                  = "keycloak"
        existingSecret            = kubernetes_secret_v1.keycloak_db_auth.metadata[0].name
        existingSecretPasswordKey = "password"
      }

      # Production mode: strict checks, HTTP allowed only because the gateway
      # terminates TLS and forwards plain HTTP. proxyHeaders=xforwarded tells
      # Keycloak to trust X-Forwarded-* (set by Cilium's Envoy data plane).
      production   = true
      proxyHeaders = "xforwarded"

      # KC_HOSTNAME as a FULL URL (https://) makes Keycloak emit https URLs
      # in OIDC discovery + JWT issuer claims regardless of the request's
      # protocol. Without this, cluster-internal token-exchange callers
      # arriving over plain HTTP would get http:// in /.well-known and the
      # `iss` claim — breaking OIDC consumers (argocd, grafana) that expect
      # a https issuer matching the canonical URL.
      extraEnvVars = [
        { name = "KC_HOSTNAME", value = "https://keycloak.${var.domain}" },
        { name = "KC_HOSTNAME_STRICT", value = "false" },
        { name = "KC_HTTP_ENABLED", value = "true" },
        { name = "KC_HEALTH_ENABLED", value = "true" },
        { name = "JAVA_OPTS_KC_HEAP", value = "-Xms256m -Xmx512m" },
      ]

      # --import-realm + mount the ConfigMap that keycloak-realm.tf renders.
      # First boot imports raj-ai-lab-eks-cilium realm with grafana + argocd
      # OIDC clients pre-configured. Subsequent boots skip the import (chart
      # default), so UI-edited state is preserved.
      extraStartupArgs = "--import-realm"
      extraVolumes = [
        {
          name = "realm-import"
          configMap = {
            name = kubernetes_config_map_v1.keycloak_realm_import.metadata[0].name
          }
        },
      ]
      extraVolumeMounts = [
        {
          name      = "realm-import"
          mountPath = "/opt/bitnami/keycloak/data/import"
          readOnly  = true
        },
      ]

      resources = {
        requests = { cpu = "200m", memory = "512Mi" }
        limits   = { cpu = "1000m", memory = "1Gi" }
      }

      # First boot does --import-realm which takes ~30-60s on top of
      # Keycloak's normal startup (~60-90s cold, JVM + realm DB setup).
      # Chart defaults (initialDelay=60, period=10, failureThreshold=3 →
      # tolerates ~30s post-initialDelay) kill the pod before import
      # completes. Bump initialDelay + failureThreshold so the first
      # boot has ~5min budget to finish.
      startupProbe = {
        enabled             = true
        initialDelaySeconds = 30
        periodSeconds       = 10
        timeoutSeconds      = 5
        failureThreshold    = 30 # 30 × 10s = 5 min
      }
      livenessProbe = {
        enabled             = true
        initialDelaySeconds = 300
        periodSeconds       = 30
        timeoutSeconds      = 5
        failureThreshold    = 3
      }
      readinessProbe = {
        enabled             = true
        initialDelaySeconds = 30
        periodSeconds       = 10
        timeoutSeconds      = 5
        failureThreshold    = 30
      }

      service = { type = "ClusterIP" }

      ingress = {
        enabled = false
      }
    })
  ]

  depends_on = [
    module.eks,
    helm_release.keycloak_postgres,
    helm_release.cert_manager,
    kubernetes_storage_class_v1.gp3,
    kubernetes_config_map_v1.keycloak_realm_import,
    kubernetes_secret_v1.keycloak_admin_auth,
  ]
}

output "keycloak_admin_url_hint" {
  value       = "https://keycloak.${var.domain}/admin"
  description = "Keycloak admin console URL (login as admin with var.keycloak_admin_password)"
}

# =============================================================================
# HTTPRoute for keycloak.${var.domain}.
# =============================================================================

resource "kubectl_manifest" "keycloak_httproute" {
  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "keycloak"
      namespace = "keycloak"
      labels    = { app = "keycloak" }
    }
    spec = {
      parentRefs = [{
        name        = "shared-gateway"
        namespace   = "gateway-system"
        sectionName = "keycloak-https"
      }]
      hostnames = ["keycloak.${var.domain}"]
      rules = [{
        matches = [{
          path = { type = "PathPrefix", value = "/" }
        }]
        backendRefs = [{
          name = "keycloak"
          port = 80
        }]
      }]
    }
  })

  depends_on = [
    helm_release.keycloak,
    kubectl_manifest.shared_gateway,
  ]
}
