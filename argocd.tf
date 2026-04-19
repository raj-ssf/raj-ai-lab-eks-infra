resource "kubernetes_namespace" "argocd" {
    metadata {
      name = "argocd"
    }
  }

  resource "helm_release" "argocd" {
    name       = "argocd"
    namespace  = kubernetes_namespace.argocd.metadata[0].name
    repository = "https://argoproj.github.io/argo-helm"
    chart      = "argo-cd"
    version    = "7.7.7"

    values = [
      yamlencode({
        configs = {
          params = {
            "server.insecure" = true
          }
        }
        server = {
          service = {
            type = "ClusterIP"
          }
        }
      })
    ]

    depends_on = [module.eks]
  }