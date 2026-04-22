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

resource "kubectl_manifest" "rag_service_app" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "rag-service"
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
        path           = "rag-service/overlays/dev"

        # Env-specific Ingress host injected here (NOT in the public app repo).
        # SA role binding is handled by aws_eks_pod_identity_association.rag_service
        # in bedrock-irsa.tf — no annotation needed on the SA.
        kustomize = {
          patches = [
            {
              target = {
                kind = "Ingress"
                name = "rag-service"
              }
              patch = <<-EOT
                - op: replace
                  path: /spec/tls/0/hosts/0
                  value: rag.${var.domain}
                - op: replace
                  path: /spec/rules/0/host
                  value: rag.${var.domain}
              EOT
            },
          ]
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "rag"
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

resource "kubectl_manifest" "qdrant_app" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "qdrant"
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
        path           = "qdrant/overlays/dev"
        # No env-specific injection — Qdrant has no account/domain-specific values.
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "qdrant"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true",
          "PrunePropagationPolicy=foreground",
          # StatefulSets sometimes take several reconcile cycles to settle
          # (PVC provisioning, pod startup). Give ArgoCD a bit more patience.
          "RespectIgnoreDifferences=true",
        ]
      }
    }
  })

  depends_on = [
    helm_release.argocd,
    kubernetes_secret.argocd_app_repo,
  ]
}
