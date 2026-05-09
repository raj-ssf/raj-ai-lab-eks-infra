# =============================================================================
# Phase 4d of Cilium migration: Langfuse — LLM observability UI.
#
# Langfuse v3 ships a "three-backend" architecture:
#   - Postgres for control plane (users, projects, prompts, configs)
#   - ClickHouse for telemetry (traces, scores, observation events)
#   - Redis for the worker's job queue
#   - MinIO (S3-compatible) for blob storage of large traces
#
# All four are bundled subcharts (Bitnami) — same image-repo override
# pattern as keycloak-postgres for the Aug-2025 bitnamilegacy migration.
#
# Auth: LOCAL ONLY in this phase. Phase 4f will add Keycloak OIDC after
# we either (a) cut over keycloak.${var.domain} DNS so the keycloak/
# keycloak terraform provider can reach it from the TF runner, or
# (b) run a one-shot kubectl_manifest applying a CR-style Keycloak
# client via the admin REST API. Until then, Langfuse uses NextAuth
# local provider — first visit goes through email/password signup,
# subsequent visits log in normally.
# =============================================================================

resource "kubernetes_namespace" "langfuse" {
  metadata {
    name = "langfuse"
  }
}

# --- Bootstrap secrets -------------------------------------------------------
# CRITICAL: encryption_key must NOT change after first apply or Langfuse
# loses access to encrypted API keys it stored. random_id (not random_password)
# because it has the .hex output we need without re-randomizing on every apply.

resource "random_password" "langfuse_salt" {
  length  = 44
  special = false
}

resource "random_id" "langfuse_encryption_key" {
  byte_length = 32
}

resource "random_password" "langfuse_nextauth_secret" {
  length  = 44
  special = false
}

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
  version    = "1.0.0"

  # ClickHouse + Zookeeper are slow to first-boot, and the four PVCs
  # bind serially. wait=true would timeout. K8s controllers settle
  # post-apply.
  wait    = false
  timeout = 600

  values = [
    yamlencode({
      global = {
        security = { allowInsecureImages = true }
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

        web = {
          replicas = 1
          resources = {
            requests = { cpu = "200m", memory = "512Mi" }
            limits   = { cpu = "1000m", memory = "1Gi" }
          }
        }
        worker = {
          replicas = 1
          resources = {
            requests = { cpu = "200m", memory = "512Mi" }
            limits   = { cpu = "1000m", memory = "1Gi" }
          }
        }

        ingress = {
          enabled = false
        }
      }

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
        shards       = 1
        replicaCount = 1
        persistence = {
          enabled = true
          size    = "20Gi"
        }
        zookeeper = {
          image = {
            repository = "bitnamilegacy/zookeeper"
          }
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
        image = {
          # Bitnami renamed Redis to Valkey in their catalog; chart key
          # stays 'redis'.
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
    kubernetes_storage_class_v1.gp3,
  ]
}

output "langfuse_url" {
  value       = "https://langfuse.${var.domain}"
  description = "Langfuse UI — first visit creates an account via email/password signup."
}

# =============================================================================
# HTTPRoute for langfuse.${var.domain}.
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
          # langfuse-web Service — port 3000 (named "http").
          name = "langfuse-web"
          port = 3000
        }]
      }]
    }
  })

  depends_on = [
    helm_release.langfuse,
    kubectl_manifest.shared_gateway,
  ]
}
