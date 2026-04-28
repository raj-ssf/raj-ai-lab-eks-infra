# Kubeflow Training Operator (v1) — installs PyTorchJob/TFJob/MPIJob/...
# CRDs + the controller-manager that reconciles them into Pods.
#
# Why v1 and not v2 (Kubeflow Trainer): v1's PyTorchJob CRD is the de
# facto standard for the K8s ML-training abstraction; mature docs, large
# ecosystem. v2 (TrainJob + TrainingRuntime) is a rearchitecture still
# gaining adoption — revisit migrating to v2 once F2 is working.
#
# Why kustomize, not Helm: the Kubeflow project doesn't publish an
# official Helm chart for training-operator v1 at
# `https://kubeflow.github.io/training-operator` (returns 404 — that
# gh-pages URL doesn't exist). Their canonical install path is
# kustomize overlays from the source repo. We wrap `kubectl apply -k`
# in a null_resource so the TF lifecycle manages create + destroy.
#
# Why a dedicated `kubeflow` namespace: convention + clean platform/
# workload separation. The chart's controller-manager pod runs here;
# the cluster-scoped CRDs (PyTorchJob etc.) it reconciles can have CRs
# (the actual training jobs) live in any namespace — for this lab,
# that's `training`.
#
# WARNING — Kubeflow's standalone overlay creates resources directly
# in the `kubeflow` namespace. We pre-create the namespace via TF so
# Pod Identity associations (etc.) can reference it, but the chart's
# manifests assume it exists.

locals {
  training_operator_version       = "v1.8.0"
  training_operator_kustomize_url = "github.com/kubeflow/training-operator/manifests/overlays/standalone?ref=${local.training_operator_version}"
}

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

# kubectl apply -k <github-url>?ref=<tag> — Kubeflow's documented
# install path. --server-side + --force-conflicts handles the case
# where Kyverno (or any other admission controller) added managed
# fields to resources during their initial creation.
resource "null_resource" "training_operator_install" {
  triggers = {
    # Bumping these re-runs the apply provisioner.
    version        = local.training_operator_version
    kustomize_path = local.training_operator_kustomize_url
    # Re-run if the kubeflow ns was recreated (uid changes).
    namespace_uid = kubernetes_namespace.kubeflow.metadata[0].uid
  }

  provisioner "local-exec" {
    command = "kubectl apply --server-side -k '${self.triggers.kustomize_path}' --force-conflicts"
  }

  # Best-effort cleanup on destroy. on_failure=continue so a teardown
  # of the cluster doesn't get blocked if the operator's CRDs have
  # already been removed via some other path.
  provisioner "local-exec" {
    when       = destroy
    command    = "kubectl delete -k '${self.triggers.kustomize_path}' --ignore-not-found"
    on_failure = continue
  }

  depends_on = [
    module.eks,
    kubernetes_namespace.kubeflow,
  ]
}

output "training_operator_version" {
  value       = local.training_operator_version
  description = "Kubeflow Training Operator version installed via kustomize."
}
