resource "kubernetes_secret" "argocd_app_repo" {
  metadata {
    name      = "argocd-repo-app"
    namespace = kubernetes_namespace.argocd.metadata[0].name
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  type = "Opaque"

  data = {
    type          = "git"
    url           = var.argocd_app_repo_url
    sshPrivateKey = var.argocd_app_repo_ssh_key
  }

  depends_on = [helm_release.argocd]
}