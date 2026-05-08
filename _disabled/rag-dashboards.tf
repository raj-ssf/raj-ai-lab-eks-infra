# Phase #25: Grafana dashboard for rag-service.
#
# Mirrors langgraph-dashboards.tf — wraps the dashboard JSON as a
# ConfigMap with the grafana_dashboard=1 label that kube-prometheus-
# stack's Grafana sidecar polls (see prometheus-stack.tf, the
# sidecar.dashboards.label config).
#
# The panels target the rag_* series exposed by rag-service after
# Phase #24's prometheus_client instrumentation: rag_retrieve_total,
# rag_retrieve_duration_seconds, rag_embed_duration_seconds,
# rag_qdrant_duration_seconds, rag_rerank_duration_seconds,
# rag_chunks_returned, rag_reranker_used_total{used=...},
# rag_ingest_total, rag_ingest_chunks.
#
# Iteration workflow is identical to langgraph dashboards:
#   1. Edit dashboards/rag-service-overview.json (Grafana's
#      "share dashboard → JSON model" output is the canonical source).
#   2. tofu apply (re-uploads the ConfigMap).
#   3. Grafana sidecar picks up the change in <60s.
#
# After this lands + tofu apply, the dashboard auto-appears in Grafana
# under the "rag-service" tag within ~60s. Auth via Keycloak OIDC at
# grafana.${var.domain}.

locals {
  rag_dashboards = {
    "rag-service-overview.json" = file(
      "${path.module}/dashboards/rag-service-overview.json"
    )
  }
}

resource "kubernetes_config_map_v1" "rag_dashboards" {
  metadata {
    name      = "rag-grafana-dashboards"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    # Matches the grafana sub-chart's sidecar.dashboards.label /
    # labelValue config (see prometheus-stack.tf).
    labels = {
      "grafana_dashboard" = "1"
    }
  }

  data = local.rag_dashboards

  depends_on = [helm_release.kube_prometheus_stack]
}
