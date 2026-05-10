# ArgoCD GitHub-webhook persistence.
#
# Set up 2026-05-02 to drop git-push → ArgoCD-sync latency from ~3 min
# (default polling) to ~5–8 sec (event-driven). Three pieces:
#
#   1. random_id.argocd_webhook_github
#        Generates a 32-byte hex shared secret. Lives in terraform state;
#        recoverable via `terraform output -raw argocd_webhook_secret`.
#        Rotates on `taint random_id.argocd_webhook_github` + apply.
#
#   2. kubernetes_secret_v1_data.argocd_webhook_secret
#        Merges `webhook.github.secret` into the chart-managed
#        `argocd-secret` Secret WITHOUT replacing the chart's other keys
#        (admin.password, server.secretkey). Uses kubernetes_secret_v1_data
#        which is purpose-built for this — patches a subset of an existing
#        Secret's data.
#
#   3. github_repository_webhook.argocd[for_each]
#        Creates the actual webhooks on each gitops repo with the same
#        secret. Events: push + pull_request. URL points at the existing
#        argocd-server HTTPRoute (argocd.${var.domain}/api/webhook).
#
# Auth note: the github provider needs admin:repo_hook scope. Use:
#   export GITHUB_TOKEN=$(gh auth token)
# before `terraform apply`. If your gh token doesn't have that scope:
#   gh auth refresh --scopes admin:repo_hook
#
# Pre-apply step: this lab had manually-created webhooks via `gh api` on
# 2026-05-02. Before the first terraform apply, delete those manual ones
# so the github provider can adopt the URL slot:
#   gh api -X DELETE repos/raj-ssf/raj-ai-lab-eks/hooks/<id>
#   gh api -X DELETE repos/raj-ssf/raj-ai-lab-eks-infra/hooks/<id>
# Find IDs via: gh api repos/raj-ssf/<repo>/hooks --jq '.[].id'
#
# After this lands, scale events that previously took ~3 min (waiting for
# ArgoCD to poll) land in ~5–8 sec.

resource "random_id" "argocd_webhook_github" {
  byte_length = 32
}

resource "kubernetes_secret_v1_data" "argocd_webhook_secret" {
  metadata {
    name      = "argocd-secret"
    namespace = "argocd"
  }
  data = {
    # ArgoCD reads this exact key from argocd-secret to validate the
    # X-Hub-Signature-256 header on incoming GitHub webhook deliveries.
    # Doc reference: https://argo-cd.readthedocs.io/en/stable/operator-manual/webhook/
    "webhook.github.secret" = random_id.argocd_webhook_github.hex
  }
  field_manager = "terraform-argocd-webhook"
  force         = true

  # The argocd-secret is created by the helm chart on first install.
  # If we ever rebuild the cluster from scratch, terraform shouldn't try
  # to merge into a Secret that doesn't exist yet — the chart's secret
  # creation needs to come first. helm_release.argocd is the dependency.
  depends_on = [helm_release.argocd]
}

# Two gitops repos to wire up. Add more here if the lab ever expands.
locals {
  argocd_webhook_repos = {
    "raj-ai-lab-eks"       = "raj-ai-lab-eks"       # apps gitops repo
    "raj-ai-lab-eks-infra" = "raj-ai-lab-eks-infra" # infra repo (still named -infra on GitHub; local dir was renamed -cilium-infra)
  }
}

resource "github_repository_webhook" "argocd" {
  for_each = local.argocd_webhook_repos

  repository = each.value
  active     = true

  # push triggers reconcile on commits to the watched branch
  # pull_request triggers reconcile on PR open/sync/close (useful if any
  # ArgoCD app targets a non-default branch via PR-preview workflow; harmless
  # noise otherwise).
  events = ["push", "pull_request"]

  configuration {
    url          = "https://argocd.${var.domain}/api/webhook"
    content_type = "json"
    insecure_ssl = false
    secret       = random_id.argocd_webhook_github.hex
  }
}

# Sensitive output so `terraform output -raw argocd_webhook_secret` can
# recover the value if needed (e.g. to manually re-add the GitHub side
# of the webhook from a different machine without regenerating).
output "argocd_webhook_secret" {
  value       = random_id.argocd_webhook_github.hex
  sensitive   = true
  description = "GitHub webhook shared secret used to validate signatures on argocd-server's /api/webhook endpoint. 32-byte hex."
}
