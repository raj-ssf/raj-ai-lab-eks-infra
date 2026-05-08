# Langfuse — LLM observability UI (prompts, traces, costs, evals).
# Complements Tempo (which holds the low-level distributed traces) by
# providing an LLM-specific view: prompt text, response text, token usage,
# latency per step, score annotations, prompt-vs-response diffs.
#
# Deployment shape (first pass — v3 with bundled backends):
#   - One Helm release installs the Langfuse chart + 4 stateful subcharts
#     (Bitnami postgres, ClickHouse, Redis, MinIO). Self-contained for the
#     lab; migrate to external-managed later if durability is a concern.
#   - Local auth only for now. OIDC via Keycloak is a follow-up milestone
#     (needs a Keycloak realm client + two env vars on the web pod).
#   - Ingress langfuse.ekstest.com with cert-manager letsencrypt-prod, same
#     pattern as rag + llm.
#
# Secrets: three required bootstrap values (salt, encryption key, nextauth
# secret). Generated once by Terraform via random_* resources — stored in
# state (which is S3+encrypted). Not rotating these on apply is critical:
# if encryption_key changes, Langfuse loses access to any already-stored
# encrypted API keys.

resource "kubernetes_namespace" "langfuse" {
  metadata {
    name = "langfuse"
  }
}

# --- Bootstrap secrets -------------------------------------------------------

# Salt used for hashing API keys. 32 bytes, base64-encoded.
resource "random_password" "langfuse_salt" {
  length  = 44
  special = false
}

# Data encryption key. Langfuse expects a 64-char hex string (32 raw bytes).
resource "random_id" "langfuse_encryption_key" {
  byte_length = 32
}

# NextAuth session JWT secret. 32+ chars, any charset.
resource "random_password" "langfuse_nextauth_secret" {
  length  = 44
  special = false
}

# Passwords for the bundled subcharts — keep them as random Terraform-managed
# values so they survive Helm upgrades without the chart rotating them.
resource "random_password" "langfuse_pg_password" {
  length  = 32
  special = false
}

resource "random_password" "langfuse_clickhouse_password" {
  length  = 32
  special = false
}

resource "random_password" "langfuse_redis_password" {
  length  = 32
  special = false
}

resource "random_password" "langfuse_minio_password" {
  length  = 32
  special = false
}

# --- Helm release ------------------------------------------------------------

resource "helm_release" "langfuse" {
  name       = "langfuse"
  namespace  = kubernetes_namespace.langfuse.metadata[0].name
  repository = "https://langfuse.github.io/langfuse-k8s"
  chart      = "langfuse"
  # Pin — bump deliberately. Chart version ≠ app version; v1.x of the chart
  # installs Langfuse v3.x (the "three-backend" architecture: pg + clickhouse
  # + redis). Older v0.x chart versions installed Langfuse v2 (pg-only).
  version = "1.0.0"

  timeout = 600  # ClickHouse init is slow on first install; give it room.

  values = [
    yamlencode({
      # Bitnami's post-Aug-2025 subcharts refuse to deploy with overridden
      # image repos (including their own bitnamilegacy/* paths) unless you
      # set this flag. Not an actual security concern for a lab — it's a
      # nag guard steering users toward the paid "Bitnami Secure" catalog.
      # See https://github.com/bitnami/charts/issues/30850.
      global = {
        security = {
          allowInsecureImages = true
        }
      }

      langfuse = {
        salt = {
          value = random_password.langfuse_salt.result
        }
        encryptionKey = {
          value = random_id.langfuse_encryption_key.hex
        }
        nextauth = {
          secret = {
            value = random_password.langfuse_nextauth_secret.result
          }
          url = "https://langfuse.${var.domain}"
        }

        # Keycloak OIDC (client managed by keycloak-langfuse-client.tf).
        # Users hit https://langfuse.ekstest.com, get redirected to Keycloak
        # for login, and land back on Langfuse authenticated.
        #
        # NOTE: chart v1.0.0 accepts `auth.providers.keycloak.*` in its
        # values schema but doesn't actually render those into env vars on
        # the rendered Deployment — the chart docs claim support, the
        # template doesn't implement it. Using the documented escape hatch
        # `additionalEnv` to inject the standard AUTH_KEYCLOAK_* env vars
        # that Langfuse's NextAuth.js provider reads directly. Revisit if
        # the chart fixes the auth.providers.* path in a future version.
        additionalEnv = [
          {
            name  = "AUTH_KEYCLOAK_CLIENT_ID"
            value = keycloak_openid_client.langfuse.client_id
          },
          {
            name  = "AUTH_KEYCLOAK_CLIENT_SECRET"
            value = random_password.keycloak_langfuse_client_secret.result
          },
          {
            name  = "AUTH_KEYCLOAK_ISSUER"
            value = "https://keycloak.${var.domain}/realms/${var.cluster_name}"
          },
          {
            name  = "AUTH_KEYCLOAK_ALLOW_ACCOUNT_LINKING"
            value = "true"
          },
          {
            # Required to make NextAuth's keycloak provider include
            # `state` and `code_challenge` (PKCE) in the OAuth
            # authorization URL. Langfuse's compiled provider
            # construction passes `checks: process.env.AUTH_KEYCLOAK_CHECKS`
            # directly to NextAuth — when this env var is unset, the
            # value is `undefined` which OVERRIDES NextAuth's default
            # `["pkce", "state"]` to nothing. The resulting bare auth
            # URL (no state, no code_challenge) is rejected by keycloak
            # with "Parameter 'client_id' not present or present multiple
            # times" — misleading message; the real issue is the URL is
            # missing required OIDC OAuth params. Setting this restores
            # the standard checks.
            name  = "AUTH_KEYCLOAK_CHECKS"
            value = "pkce,state"
          },
        ]

        # Web tier (Next.js frontend + API).
        web = {
          replicas = 1
          resources = {
            requests = { cpu = "200m", memory = "512Mi" }
            limits   = { cpu = "1000m", memory = "1Gi" }
          }
        }

        # Worker tier (async event ingestion → ClickHouse).
        worker = {
          replicas = 1
          resources = {
            requests = { cpu = "200m", memory = "512Mi" }
            limits   = { cpu = "1000m", memory = "1Gi" }
          }
        }

        # Phase 12 of Gateway API migration: chart's Ingress disabled.
        # Traffic now flows exclusively through shared-gateway in
        # gateway-system ns. cert-manager Certificate langfuse-tls
        # in this namespace is now an orphan-but-renewing standalone
        # resource (ingress-shim no longer manages it; cert-manager
        # renews based on the Certificate spec).
        ingress = {
          enabled = false
        }
      }

      # --- Bundled subcharts --------------------------------------------------

      # NOTE on image repos: Bitnami's August-2025 catalog shake-up moved all
      # existing non-"secure" tags from docker.io/bitnami/* to docker.io/
      # bitnamilegacy/*. The Langfuse chart's subchart values still reference
      # bitnami/* by default — pulls 404 / ImagePullBackOff with the chart's
      # default image paths. Overriding each subchart's image.repository to
      # the bitnamilegacy/* path is the standard fix; tags stay the same.
      # (Same fix we applied earlier for the keycloak-postgres-postgresql
      # pod, documented in project_eks_lab_progress.md.)

      postgresql = {
        deploy = true
        image = {
          repository = "bitnamilegacy/postgresql"
        }
        auth = {
          password         = random_password.langfuse_pg_password.result
          postgresPassword = random_password.langfuse_pg_password.result
        }
        primary = {
          persistence = {
            enabled = true
            size    = "8Gi"
          }
          resources = {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }
        }
      }

      clickhouse = {
        deploy = true
        image = {
          repository = "bitnamilegacy/clickhouse"
        }
        auth = {
          password = random_password.langfuse_clickhouse_password.result
        }
        # Single-shard single-replica for lab footprint. Production-scale
        # Langfuse wants 2+ replicas per shard for durability.
        shards   = 1
        replicaCount = 1
        persistence = {
          enabled = true
          size    = "20Gi"  # Traces compound fast; 20 GiB covers months of lab use.
        }
        zookeeper = {
          image = {
            repository = "bitnamilegacy/zookeeper"
          }
          # ClickHouse Keeper replaces ZooKeeper in newer images, but the
          # Bitnami chart still ships ZK as default. Single replica for lab.
          replicaCount = 1
          persistence = {
            enabled = true
            size    = "4Gi"
          }
        }
        resources = {
          requests = { cpu = "200m", memory = "512Mi" }
          limits   = { cpu = "1000m", memory = "2Gi" }
        }
      }

      redis = {
        deploy = true
        # Bitnami renamed Redis to Valkey in their catalog; chart still calls
        # it 'redis' as the subchart key but pulls the valkey image.
        image = {
          repository = "bitnamilegacy/valkey"
        }
        auth = {
          password = random_password.langfuse_redis_password.result
        }
        master = {
          persistence = {
            enabled = true
            size    = "2Gi"
          }
          resources = {
            requests = { cpu = "50m", memory = "128Mi" }
            limits   = { cpu = "200m", memory = "256Mi" }
          }
        }
      }

      s3 = {
        deploy = true
        image = {
          repository = "bitnamilegacy/minio"
        }
        auth = {
          rootPassword = random_password.langfuse_minio_password.result
        }
        persistence = {
          enabled = true
          size    = "10Gi"
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
    helm_release.cert_manager,
    # Keycloak OIDC client must exist before langfuse-web starts, so the
    # first NextAuth signin attempt doesn't 500 on "unknown_client".
    keycloak_openid_client.langfuse,
  ]
}

output "langfuse_url" {
  value       = "https://langfuse.${var.domain}"
  description = "Langfuse UI — initial account is created via sign-up on first visit"
}

# =============================================================================
# Phase 7 of Gateway API migration: HTTPRoute for langfuse.ekstest.com.
#
# Helm-managed apps (langfuse, grafana, vault, argocd, keycloak) have no
# apps-repo dir, so the HTTPRoute lives here in TF as a kubectl_manifest
# alongside the helm_release. Per-app shape (RG + AuthZ in target ns) is
# emitted by the gateway-app module via the local.gateway_apps map in
# gateway-system.tf.
#
# Why HTTPRoute is in the same TF file as the helm_release: keeps the app's
# routing definition next to its other infra wiring (namespace, secrets,
# Keycloak client). Mirroring the apps-repo pattern of "HTTPRoute lives
# with the app's other manifests."
# =============================================================================

resource "kubectl_manifest" "langfuse_httproute" {
  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "langfuse"
      namespace = "langfuse"
      labels    = { app = "langfuse" }
    }
    spec = {
      parentRefs = [{
        name        = "shared-gateway"
        namespace   = "gateway-system"
        sectionName = "langfuse-https"
      }]
      hostnames = ["langfuse.${var.domain}"]
      rules = [{
        matches = [{
          path = { type = "PathPrefix", value = "/" }
        }]
        backendRefs = [{
          # langfuse-web Service exposes port 3000 (named "http").
          name = "langfuse-web"
          port = 3000
        }]
      }]
    }
  })

  depends_on = [
    helm_release.langfuse,
  ]
}
