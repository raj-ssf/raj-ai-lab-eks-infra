# =============================================================================
# Phase #73: Microsoft Presidio — PII detection + anonymization layer.
#
# Sits between user input and LLM, and between LLM output and user. Detects
# ~30 entity types (PERSON, EMAIL, PHONE, SSN, CREDIT_CARD, IP_ADDRESS,
# DATE_TIME, IBAN, US_PASSPORT, etc.) using NER models (spaCy en_core_web_lg
# by default). The Anonymizer service then replaces detected entities
# with placeholders — typed (e.g., "<PERSON_1>") for reversible redaction
# or hashed/redacted for irreversible.
#
# Two-service architecture (Microsoft's official deployment shape):
#   presidio-analyzer    REST API on :5001
#                        Input:  text + entity types to detect
#                        Output: list of (entity_type, start, end, score)
#   presidio-anonymizer  REST API on :5002
#                        Input:  text + analyzer results + operator config
#                        Output: anonymized text + entity_mappings
#
# Why two services and not one:
#   - Independent scaling: detection is CPU-heavy (NER inference),
#     anonymization is CPU-light (string substitution). HPAs can target
#     different load curves.
#   - Stateless: both services hold no state, so multi-replica + pod-
#     failure resilience is straightforward.
#
# Call pattern (langgraph-service integration in Phase #73b — follow-up
# gitops commit):
#   1. User message arrives at chat-ui → langgraph-service
#   2. langgraph calls analyzer with the user message + entity types of
#      interest (PERSON, EMAIL, PHONE_NUMBER, etc.)
#   3. langgraph calls anonymizer with the analyzer's results — gets
#      back redacted text + mapping of "<PERSON_1>" → "Alice Smith"
#   4. langgraph forwards REDACTED text to LLM
#   5. LLM returns response (which may reference "<PERSON_1>")
#   6. langgraph re-applies the mapping in reverse to substitute
#      "<PERSON_1>" → "Alice Smith" in the output before returning to
#      chat-ui (option), OR keeps the redaction for audit logs (option).
#
# Cost: ~500MB memory baseline per Presidio pod. CPU-only — no GPU
# needed. Lands on the Karpenter general-purpose NodePool (Phase #66)
# or the existing m5.xlarge static nodes. Scaling 2 → 4 replicas under
# load fits comfortably.
#
# Cluster integration:
#   - presidio namespace, mesh-injected (presidio is meshed because the
#     callers — langgraph, chat-ui — are meshed and we want STRICT
#     mTLS-authenticated principal-based access)
#   - Istio AuthZ: allow langgraph-service + chat-ui + ingestion-service
#     SAs only (presidio is internal — never exposed externally)
#   - NetworkPolicy: meshed-app pattern from Phase #70f
#   - HPAs targeting CPU 70% (presidio scales linearly with text volume)
# =============================================================================

resource "kubernetes_namespace" "presidio" {
  metadata {
    name = "presidio"
    labels = {
      # Phase #73: meshed for STRICT mTLS. Both analyzer + anonymizer
      # are called by other meshed apps; mesh enforcement gives
      # SPIFFE-authenticated access without app-level auth.
      "istio-injection" = "enabled"
    }
  }
}

# ServiceAccounts — used by the Istio AuthZ rule below to identify
# the analyzer + anonymizer pods as principals (not strictly needed
# since callers identify by SOURCE SA, not destination, but present
# for completeness and audit).
resource "kubernetes_service_account_v1" "presidio_analyzer" {
  metadata {
    name      = "presidio-analyzer"
    namespace = kubernetes_namespace.presidio.metadata[0].name
  }
}

resource "kubernetes_service_account_v1" "presidio_anonymizer" {
  metadata {
    name      = "presidio-anonymizer"
    namespace = kubernetes_namespace.presidio.metadata[0].name
  }
}

# --- presidio-analyzer Deployment + Service ---------------------------------

resource "kubernetes_deployment_v1" "presidio_analyzer" {
  metadata {
    name      = "presidio-analyzer"
    namespace = kubernetes_namespace.presidio.metadata[0].name
    labels = {
      app = "presidio-analyzer"
    }
  }

  spec {
    # 2 replicas baseline — pod-failure HA + parallel detection. HPA
    # scales 2→5 on CPU.
    replicas = 2

    selector {
      match_labels = { app = "presidio-analyzer" }
    }

    template {
      metadata {
        labels = { app = "presidio-analyzer" }
      }

      spec {
        service_account_name = kubernetes_service_account_v1.presidio_analyzer.metadata[0].name

        # Anti-affinity: prefer different nodes (same Phase #59/60
        # lesson — preferred allows colocation on capacity-pinched
        # cluster).
        affinity {
          pod_anti_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 100
              pod_affinity_term {
                label_selector {
                  match_labels = { app = "presidio-analyzer" }
                }
                topology_key = "kubernetes.io/hostname"
              }
            }
          }
        }

        container {
          name = "presidio-analyzer"
          # Microsoft's official image. Pinned by tag (not digest) for
          # readability — Phase #73c follow-up could pin to digest +
          # add cosign sig verification through Kyverno catchall like
          # the rag-service / langgraph-service apps already do.
          image             = "mcr.microsoft.com/presidio-analyzer:2.2.355"
          image_pull_policy = "IfNotPresent"

          port {
            container_port = 5001
            name           = "http"
            protocol       = "TCP"
          }

          # CPU-bound: spaCy NER inference. Baseline ~200m, spike to
          # 500m on burst. Memory holds the en_core_web_lg model
          # (~500MB).
          resources {
            requests = {
              cpu    = "200m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "1Gi"
            }
          }

          # /health is the chart's default — returns 200 when spaCy
          # model is loaded. ~30s warmup on first start.
          startup_probe {
            http_get {
              path = "/health"
              port = "http"
            }
            initial_delay_seconds = 10
            period_seconds        = 5
            failure_threshold     = 12 # 60s max
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = "http"
            }
            period_seconds    = 10
            failure_threshold = 3
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = "http"
            }
            period_seconds    = 30
            failure_threshold = 3
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "presidio_analyzer" {
  metadata {
    name      = "presidio-analyzer"
    namespace = kubernetes_namespace.presidio.metadata[0].name
    labels    = { app = "presidio-analyzer" }
  }
  spec {
    type     = "ClusterIP"
    selector = { app = "presidio-analyzer" }
    port {
      name        = "http"
      port        = 5001
      target_port = "http"
      protocol    = "TCP"
    }
  }
}

# --- presidio-anonymizer Deployment + Service ------------------------------

resource "kubernetes_deployment_v1" "presidio_anonymizer" {
  metadata {
    name      = "presidio-anonymizer"
    namespace = kubernetes_namespace.presidio.metadata[0].name
    labels    = { app = "presidio-anonymizer" }
  }

  spec {
    # 2 replicas same as analyzer. Anonymizer is lighter than analyzer
    # (no NER model), so 2 is comfortable.
    replicas = 2

    selector {
      match_labels = { app = "presidio-anonymizer" }
    }

    template {
      metadata {
        labels = { app = "presidio-anonymizer" }
      }

      spec {
        service_account_name = kubernetes_service_account_v1.presidio_anonymizer.metadata[0].name

        affinity {
          pod_anti_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 100
              pod_affinity_term {
                label_selector {
                  match_labels = { app = "presidio-anonymizer" }
                }
                topology_key = "kubernetes.io/hostname"
              }
            }
          }
        }

        container {
          name              = "presidio-anonymizer"
          image             = "mcr.microsoft.com/presidio-anonymizer:2.2.355"
          image_pull_policy = "IfNotPresent"

          port {
            container_port = 5001 # default port; exposed as Service :5002
            name           = "http"
            protocol       = "TCP"
          }

          # Anonymizer is much lighter than analyzer — string
          # substitution + crypto operations only. 100m CPU / 256Mi
          # memory baseline.
          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }

          startup_probe {
            http_get {
              path = "/health"
              port = "http"
            }
            initial_delay_seconds = 5
            period_seconds        = 5
            failure_threshold     = 6
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = "http"
            }
            period_seconds    = 10
            failure_threshold = 3
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = "http"
            }
            period_seconds    = 30
            failure_threshold = 3
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "presidio_anonymizer" {
  metadata {
    name      = "presidio-anonymizer"
    namespace = kubernetes_namespace.presidio.metadata[0].name
    labels    = { app = "presidio-anonymizer" }
  }
  spec {
    type     = "ClusterIP"
    selector = { app = "presidio-anonymizer" }
    port {
      # Service exposes 5002 to be distinct from analyzer's 5001
      # cluster-side; the container itself listens on 5001 (image
      # default). targetPort points at the named container port.
      name        = "http"
      port        = 5002
      target_port = "http"
      protocol    = "TCP"
    }
  }
}

# --- HPAs ---------------------------------------------------------------------

resource "kubernetes_horizontal_pod_autoscaler_v2" "presidio_analyzer" {
  metadata {
    name      = "presidio-analyzer"
    namespace = kubernetes_namespace.presidio.metadata[0].name
  }
  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment_v1.presidio_analyzer.metadata[0].name
    }
    min_replicas = 2
    max_replicas = 5
    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = 70
        }
      }
    }
    behavior {
      scale_up {
        stabilization_window_seconds = 60
        policy {
          type           = "Percent"
          value          = 100
          period_seconds = 30
        }
      }
      scale_down {
        stabilization_window_seconds = 300
        policy {
          type           = "Percent"
          value          = 50
          period_seconds = 60
        }
      }
    }
  }
}

resource "kubernetes_horizontal_pod_autoscaler_v2" "presidio_anonymizer" {
  metadata {
    name      = "presidio-anonymizer"
    namespace = kubernetes_namespace.presidio.metadata[0].name
  }
  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment_v1.presidio_anonymizer.metadata[0].name
    }
    min_replicas = 2
    max_replicas = 4
    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = 70
        }
      }
    }
    behavior {
      scale_up {
        stabilization_window_seconds = 60
        policy {
          type           = "Percent"
          value          = 100
          period_seconds = 30
        }
      }
      scale_down {
        stabilization_window_seconds = 300
        policy {
          type           = "Percent"
          value          = 50
          period_seconds = 60
        }
      }
    }
  }
}

# --- Istio AuthorizationPolicy ------------------------------------------------
# Only meshed app SAs that need PII redaction can call presidio. Today that's
# langgraph-service (input redaction before LLM, output un-redaction after)
# and chat-ui (could redact for display in audit logs). ingestion-service
# included for future document-ingest PII redaction (PDFs that may contain
# sensitive data before chunking/embedding).
resource "kubectl_manifest" "presidio_authz_apps" {
  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"
    metadata = {
      name      = "allow-apps-to-presidio"
      namespace = kubernetes_namespace.presidio.metadata[0].name
    }
    spec = {
      action = "ALLOW"
      rules = [{
        from = [{
          source = {
            principals = [
              "cluster.local/ns/langgraph/sa/langgraph-service",
              "cluster.local/ns/chat/sa/chat-ui",
              "cluster.local/ns/ingestion/sa/ingestion-service",
            ]
          }
        }]
      }]
    }
  })

  depends_on = [
    helm_release.istiod,
    kubernetes_namespace.presidio,
  ]
}

# --- NetworkPolicy ------------------------------------------------------------
# Same meshed-app pattern as Phase #70f — namespace-wide selector, ingress
# from meshed namespaces (Istio AuthZ filters L7), egress to common
# destinations (DNS, istiod, K8s API).
resource "kubectl_manifest" "presidio_netpol" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "presidio"
      namespace = kubernetes_namespace.presidio.metadata[0].name
    }
    spec = {
      podSelector = {} # all pods in presidio ns
      policyTypes = ["Ingress", "Egress"]
      ingress     = local.app_common_ingress
      egress      = local.app_common_egress
    }
  })

  depends_on = [
    helm_release.istiod,
    kubernetes_namespace.presidio,
  ]
}

# --- Helpful output -----------------------------------------------------------
output "presidio_endpoints" {
  value = {
    analyzer   = "http://presidio-analyzer.presidio.svc.cluster.local:5001"
    anonymizer = "http://presidio-anonymizer.presidio.svc.cluster.local:5002"
  }
  description = "In-cluster endpoints for the Presidio services. langgraph-service and chat-ui callers will reference these via env vars."
}
