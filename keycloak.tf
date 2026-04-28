resource "kubernetes_namespace" "keycloak" {
  metadata {
    name = "keycloak"
    labels = {
      # Mesh-injection label declared HERE so the kubernetes_namespace
      # resource doesn't strip it on every TF run. (Previously
      # kubernetes_labels.istio_injection["keycloak"] in istio.tf was
      # adding it; kubernetes_namespace was removing it. The cycle
      # caused keycloak pods to occasionally be admitted without an
      # istio-proxy sidecar, which broke the gateway → keycloak path
      # via force-mtls-keycloak DR — see Phase 12a debug log.)
      "istio-injection" = "enabled"
    }
  }
}

# --- Postgres backing store for Keycloak --------------------------------------
# Dedicated Postgres instead of Keycloak's embedded H2 so realm + user state
# survives pod restarts and Keycloak upgrades. Single replica is fine for a
# lab; swap to RDS Aurora when we do the real-corpus phase.
resource "helm_release" "keycloak_postgres" {
  name       = "keycloak-postgres"
  namespace  = kubernetes_namespace.keycloak.metadata[0].name
  # Bitnami charts are HTTPS-hosted but their `common` library dependency is
  # OCI-only; the helm terraform provider fails to resolve that OCI dep when
  # the parent chart is fetched via HTTPS. Pulling the parent from OCI too
  # avoids the mismatch.
  repository = "oci://registry-1.docker.io/bitnamicharts"
  chart      = "postgresql"
  version    = "18.6.1"

  values = [
    yamlencode({
      # See keycloak.tf image override rationale: point at bitnamilegacy/*
      # to keep pulls free after Bitnami's 2025 pricing change. Pinned tag
      # because bitnamilegacy tops out at Postgres 17.6 (no 18.x), so the
      # chart's default tag wouldn't resolve.
      image = {
        registry   = "docker.io"
        repository = "bitnamilegacy/postgresql"
        tag        = "17.6.0-debian-12-r4"
      }
      auth = {
        username       = "keycloak"
        database       = "keycloak"
        # Password source of truth is Vault (secret/keycloak/db). VSO syncs
        # that into the keycloak-db-auth k8s Secret in the keycloak ns; the
        # chart's existingSecret pointer reads `password` + `postgres-password`
        # from it. No plaintext passwords in helm values or tfstate.
        existingSecret = "keycloak-db-auth"
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
    # VSO-managed Secret must exist before Postgres init — chart reads
    # password from it for the initial DB bootstrap.
    kubectl_manifest.keycloak_db_vault_secret,
  ]
}

# --- Keycloak -----------------------------------------------------------------
resource "helm_release" "keycloak" {
  name       = "keycloak"
  namespace  = kubernetes_namespace.keycloak.metadata[0].name
  repository = "oci://registry-1.docker.io/bitnamicharts" # see keycloak_postgres for rationale
  chart      = "keycloak"
  version    = "25.2.0"

  values = [
    yamlencode({
      auth = {
        adminUser = "admin"
        # Admin password source of truth is Vault (secret/keycloak/admin).
        # VSO syncs it into the keycloak-admin-auth Secret; chart reads the
        # `admin-password` key (Bitnami default). As with Grafana, the
        # password is persisted in Keycloak's DB on first boot, so rotating
        # in Vault needs a matching UI/API change — delivery migration, not
        # live rotation.
        existingSecret = "keycloak-admin-auth"
      }

      # Bitnami's 2025 image-hosting shakeup: newer tags of docker.io/bitnami/keycloak
      # require the paid tier. Freely pullable copies are parked at bitnamilegacy/*.
      # Overriding the per-component image registry/repository keeps the chart
      # itself untouched but points pulls at the legacy-public mirror.
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

      # Use the postgres we deployed above, not the chart's bundled one.
      postgresql = { enabled = false }
      externalDatabase = {
        host     = "keycloak-postgres-postgresql.${kubernetes_namespace.keycloak.metadata[0].name}.svc.cluster.local"
        port     = 5432
        user     = "keycloak"
        database = "keycloak"
        # existingSecret satisfies Bitnami's upgrade safety check (chart
        # refuses to render without a password source). Chart will set
        # KC_DB_PASSWORD env from this Secret — but our extraEnvVars below
        # re-declares KC_DB_PASSWORD with the `file:` prefix, and the
        # later entry in the pod env list wins, so Keycloak actually reads
        # from the Vault Agent–injected file. Net effect: same credential
        # flows two ways through Helm to satisfy two constraints; runtime
        # value is always the Vault Agent file.
        existingSecret            = "keycloak-db-auth"
        existingSecretPasswordKey = "password"
      }

      # Production mode: strict checks, HTTP disabled unless explicitly enabled.
      # We terminate TLS at NGINX and forward plain HTTP inside the cluster,
      # so tell Keycloak to trust X-Forwarded-* headers.
      production   = true
      proxyHeaders = "xforwarded"

      # Heap tuning + KC_HOSTNAME + health endpoint on management port 9000.
      # KC_HOSTNAME_STRICT=false lets us hit the pod via ClusterIP/port-forward
      # for debugging without tripping Keycloak's hostname check.
      #
      # KC_DB_PASSWORD uses Keycloak's `file:` config-source prefix, which
      # reads the value at startup from the injected Vault Agent sidecar
      # file. Applies to any KC_* option; this is Keycloak's equivalent of
      # Grafana's GF_*__FILE convention.
      extraEnvVars = [
        { name = "KC_HOSTNAME",       value = "keycloak.${var.domain}" },
        { name = "KC_HOSTNAME_STRICT", value = "false" },
        { name = "KC_HTTP_ENABLED",   value = "true" },
        { name = "KC_HEALTH_ENABLED", value = "true" },
        { name = "JAVA_OPTS_KC_HEAP", value = "-Xms256m -Xmx512m" },
        { name = "KC_DB_PASSWORD",    value = "file:/vault/secrets/db-password" },
      ]

      # Vault Agent Injector: writes /vault/secrets/db-password from
      # secret/data/keycloak/db `password` key. Role `keycloak` is bound
      # to keycloak/keycloak SA in vault-config.tf.
      #
      # Bitnami common chart runs tpl on every podAnnotations value, so raw
      # Vault Agent template syntax trips Helm with `function "secret" not
      # defined`. Wrap the template in {{` … `}} — Helm's raw-string escape
      # — so tpl outputs the literal Vault Agent template string unchanged.
      podAnnotations = {
        "vault.hashicorp.com/agent-inject" = "true"
        "vault.hashicorp.com/role"         = "keycloak"

        "vault.hashicorp.com/agent-inject-secret-db-password"   = "secret/data/keycloak/db"
        "vault.hashicorp.com/agent-inject-template-db-password" = <<-EOT
          {{`{{- with secret "secret/data/keycloak/db" -}}
          {{ .Data.data.password }}
          {{- end -}}`}}
        EOT
      }

      # Realm import: mount the ConfigMap rendered by keycloak-realm.tf at the
      # dir Keycloak scans, and tell the startup script to import on boot.
      # First boot imports the raj-ai-lab realm; subsequent boots skip the
      # import (default strategy), so UI-edited state is not clobbered.
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

      # Probes: trust chart defaults. Bitnami/keycloak 25.x already targets
      # the management port 9000 with /health/* when KC_HEALTH_ENABLED=true.

      resources = {
        requests = { cpu = "200m", memory = "512Mi" }
        limits   = { cpu = "1000m", memory = "1Gi" }
      }

      service = { type = "ClusterIP" }

      # Ingress → NGINX → cert-manager issues LE prod cert.
      # proxy-buffer-size bump: JWT-carrying auth responses overflow the 4k
      # default and return 502 otherwise.
      # Phase 12 of Gateway API migration: chart's Ingress disabled.
      # Traffic now flows through shared-gateway in gateway-system ns.
      ingress = {
        enabled = false
      }
    })
  ]

  depends_on = [
    module.eks,
    helm_release.alb_controller,
    helm_release.keycloak_postgres,
    helm_release.cert_manager,
    kubernetes_storage_class_v1.gp3,
    kubernetes_config_map_v1.keycloak_realm_import,
    # Admin password Secret must exist (VSO): bootstraps the master realm.
    kubectl_manifest.keycloak_admin_vault_secret,
    # DB password role must exist (Agent Injector): pod can't auth Vault
    # without it.
    vault_kubernetes_auth_backend_role.keycloak_pod,
    # DB password value must be in Vault KV so the agent can fetch it on
    # pod boot (failing otherwise keeps pod in init forever).
    vault_kv_secret_v2.keycloak_db,
  ]
}

output "keycloak_admin_url_hint" {
  value       = "https://keycloak.${var.domain}/admin"
  description = "Keycloak admin console URL (login as admin with keycloak_admin_password)"
}

# =============================================================================
# Phase 11 (FINAL) of Gateway API migration: HTTPRoute for keycloak.ekstest.com.
#
# This is the auth boundary — every other migrated app's OAuth/OIDC login
# flow redirects through this hostname. Migration mechanics are identical
# to the other Helm-managed apps (langfuse, grafana, vault, argocd):
# Ingress + HTTPRoute coexist during cutover; ExternalDNS auto-migrates
# the A record once the Ingress is annotated to opt-out.
#
# Critical behavior to verify post-cutover (browser test):
#   1. Existing logged-in sessions to chat-ui / langfuse / etc. keep
#      working (cookie-based, doesn't re-auth)
#   2. Fresh login from any of those apps: redirect to
#      keycloak.ekstest.com → user authenticates → callback returns
#      to the originating app
#   3. /admin console accessible
#   4. JWT-bearing responses don't 502 (proxy-buffer-size 16k tuning
#      was for NGINX; Envoy's 60KB default header buffer covers it)
#
# Backend: keycloak Service in keycloak ns, port 80 (named "http",
# targetPort "http" — internally pod port 8080).
#
# Note on mesh: keycloak ns currently has no istio-injection label
# (ArgoCD strips it; TF re-applies; race continues). The keycloak
# pod has NO istio-proxy sidecar — the gateway → keycloak hop will
# be plain HTTP (not mTLS), and the allow-gateway-system AuthZ in
# keycloak ns will be a dormant rule (no enforcer). This is fine
# for the migration; security posture is unchanged from the legacy
# NGINX path which was also plain HTTP to the keycloak pod.
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
  ]
}
