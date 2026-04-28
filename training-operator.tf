# Kubeflow Training Operator (v1) — installs PyTorchJob/TFJob/MPIJob/...
# CRDs + the controller-manager that reconciles them into Pods.
#
# Why v1 and not v2 (Kubeflow Trainer): v1's PyTorchJob CRD is the de facto
# standard for the K8s ML-training abstraction; mature docs, large
# ecosystem, used in production at most ML platforms. v2 (TrainJob +
# TrainingRuntime) is a rearchitecture that's still gaining adoption — once
# v1 is working we can revisit migrating to v2 as a follow-up.
#
# Why a dedicated `kubeflow` namespace: convention. The chart's controller-
# manager pod runs here; the cluster-scoped CRDs (PyTorchJob etc.) it
# reconciles can have their CRs (the actual training jobs) live in any
# namespace — for this lab, that's `training`.

resource "kubernetes_namespace" "kubeflow" {
  metadata {
    name = "kubeflow"
    labels = {
      "kubernetes.io/metadata.name" = "kubeflow"
      # No istio-injection on the controller-manager. The operator only
      # talks to the K8s API server; no inbound traffic, no benefit from
      # a sidecar. (Same pattern as cert-manager, external-dns, etc.)
    }
  }
}

resource "helm_release" "training_operator" {
  name       = "training-operator"
  namespace  = kubernetes_namespace.kubeflow.metadata[0].name
  repository = "https://kubeflow.github.io/training-operator"
  chart      = "training-operator"
  # 1.8.0 is the latest GA from the Kubeflow project as of writing
  # (early 2026). Bump in a follow-up after lab validation.
  version = "1.8.0"

  values = [
    yamlencode({
      # Resource limits for the controller-manager. It's a thin reconciler
      # — doesn't run training itself — so this fits the lab's m5 control
      # plane comfortably.
      resources = {
        requests = { cpu = "100m", memory = "128Mi" }
        limits   = { cpu = "500m", memory = "256Mi" }
      }
    })
  ]

  depends_on = [
    module.eks,
    kubernetes_namespace.kubeflow,
  ]
}

output "training_operator_chart_version" {
  value       = "1.8.0"
  description = "Kubeflow Training Operator chart version installed."
}
