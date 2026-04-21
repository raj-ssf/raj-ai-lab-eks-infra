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

        # Env-specific values injected here (NOT in the public app repo).
        # These come from Terraform state and variables — tfvars is gitignored.
        kustomize = {
          images = [
            "rag-service=${aws_ecr_repository.rag_service.repository_url}:dev",
          ]
          patches = [
            {
              target = {
                kind = "ServiceAccount"
                name = "rag-service"
              }
              patch = <<-EOT
                apiVersion: v1
                kind: ServiceAccount
                metadata:
                  name: rag-service
                  annotations:
                    eks.amazonaws.com/role-arn: ${module.rag_service_irsa.iam_role_arn}
              EOT
            },
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
