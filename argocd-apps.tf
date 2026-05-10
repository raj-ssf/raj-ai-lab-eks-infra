# =============================================================================
# ArgoCD Application objects.
#
# Cherry-picked subset of the original raj-ai-lab-eks-infra/argocd-apps.tf:
# only `hello` is enabled today as a smoke test of the ArgoCD ↔ apps-gitops
# repo wiring (webhook + repo SSH key + sync policy). The other 6 Applications
# (rag-service, vllm, langgraph-service, chat-ui, qdrant, ingestion-service)
# remain in _disabled/argocd-apps.tf — they each carry assumptions that need
# rework for the Cilium-era cluster:
#
#   - rag-service / langgraph-service / chat-ui / ingestion-service: the
#     overlays reference Istio VirtualService for argo-rollouts canary
#     traffic-shifting. Without sidecars in this cluster, those CRs are
#     created but unenforced. Migrate to Gateway API HTTPRoute weighted
#     backendRefs before re-enabling.
#   - vllm: triggers Karpenter to provision a g5/g6 GPU node — billable.
#     Pending the cost decision.
#   - qdrant / chat-ui / ingestion-service / langgraph-service: ECR repos
#     exist (chat-ui.tf etc.) but are empty until the GHA pipelines push
#     fresh images.
# =============================================================================

resource "kubectl_manifest" "hello_app" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "hello"
      namespace = kubernetes_namespace.argocd.metadata[0].name
      finalizers = [
        "resources-finalizer.argocd.argoproj.io",
      ]
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.argocd_app_repo_url
        targetRevision = "HEAD"
        path           = "hello"
        # Phase 2 portability refactor: hello's HTTPRoute uses placeholder
        # hostnames (hello.example.local / hello2.example.local) in the apps
        # repo. Patches inject the real var.domain hostnames at sync time.
        kustomize = {
          patches = [
            {
              target = {
                kind = "HTTPRoute"
                name = "hello"
              }
              patch = <<-EOT
                - op: replace
                  path: /spec/hostnames/0
                  value: hello.${var.domain}
                - op: replace
                  path: /spec/hostnames/1
                  value: hello2.${var.domain}
              EOT
            },
          ]
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "default"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true",
          "PrunePropagationPolicy=foreground",
        ]
      }
    }
  })

  depends_on = [
    helm_release.argocd,
    kubernetes_secret.argocd_app_repo,
  ]
}
