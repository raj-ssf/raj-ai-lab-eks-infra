# =============================================================================
# Pre-create app namespaces so other TF resources (Pod Identity associations,
# ServiceAccounts, helm releases) can land cleanly even when the actual app
# workload is deferred.
#
# Pod Identity associations DON'T require namespaces to exist (they're an
# AWS-side binding), but k8s ServiceAccount and helm chart deploys do.
# =============================================================================

resource "kubernetes_namespace" "langgraph" {
  metadata {
    name = "langgraph"
  }
}

resource "kubernetes_namespace" "rag" {
  metadata {
    name = "rag"
  }
}

resource "kubernetes_namespace" "chat" {
  metadata {
    name = "chat"
  }
}

resource "kubernetes_namespace" "ingestion" {
  metadata {
    name = "ingestion"
  }
}
