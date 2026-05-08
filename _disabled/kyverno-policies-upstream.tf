# Upstream-publisher signature-verification policies.
#
# Companion to kyverno-policies.tf (which verifies images from our own GHA
# pipeline). Each publisher has its own ClusterPolicy because their signing
# identity subject is specific to the publisher's release workflow on their
# own GitHub repo.
#
# Rollout convention for every new publisher rule:
#   1. validationFailureAction = "Audit" to start; generates PolicyReport
#      entries on existing pods without blocking admission.
#   2. Inspect reports: `kubectl get policyreport -A`. Failure messages
#      include the actual signing subject the publisher used, so we can
#      tighten/loosen the subjectRegExp to match.
#   3. Flip to Enforce once reports show pass=N, fail=0.
#
# mutateDigest stays false for upstream policies — we don't want Kyverno
# rewriting third-party image references in case the publisher rotates
# tags on their registry side; our own images have pinned digests for
# stricter control.
#
# -----------------------------------------------------------------------------
# Pre-flight findings from `cosign verify` against our upstream images
# -----------------------------------------------------------------------------
# Before writing rules, we ran `cosign verify` locally against each publisher
# to confirm they actually ship keyless Sigstore signatures. Results:
#
#   Publisher       Registry + Tag                          Keyless signed?
#   --------------  --------------------------------------  ---------------
#   ArgoCD          quay.io/argoproj/argocd:v2.13.3         YES (rule below)
#   Istio           docker.io/istio/*:1.24.x                NO (no sig artifact)
#   Kyverno         reg.kyverno.io + ghcr.io v1.13.3        NO (no sig artifact)
#   Vault           hashicorp/vault:1.18.3                  NO keyless; HashiCorp
#                                                           uses keyed signing
#                                                           with their own pub key
#
# So we start with ArgoCD (the only publisher in the lab with working keyless
# signing on the images we actually run). For the rest, documenting the gap
# is itself the security story: "verified what we can, knowingly exempt the
# rest until their supply chain matures." Vault could be added later with a
# `keys` attestor pinning HashiCorp's public key.

# -----------------------------------------------------------------------------
# ArgoCD — keyless signed from argoproj/argo-cd image-reuse.yaml on version tags
# -----------------------------------------------------------------------------
# Verified signing subject from local cosign verify:
#   https://github.com/argoproj/argo-cd/.github/workflows/image-reuse.yaml@refs/tags/v2.13.3
#
# The regex below locks the rule down to that specific workflow on any
# version tag (vX.Y.Z). Two guardrails baked in:
#   - Workflow file name pinned (image-reuse.yaml) — prevents an attacker
#     who creates a new workflow in the repo from producing images that
#     pass verification.
#   - Tag-ref pattern (refs/tags/vX.Y.Z) — a build triggered from a
#     feature branch or PR would fail verification, even with the right
#     workflow file, because the ref wouldn't be a semver tag.

resource "kubectl_manifest" "kyverno_verify_argocd_images" {
  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "verify-argocd-image-signatures"
    }
    spec = {
      # Flipped from Audit → Enforce after PolicyReports showed 23/23 pass for
      # all argocd pods, controllers, and replicasets (messages:
      # "verified image signatures for quay.io/argoproj/argocd:v2.13.1" and
      # subsequent cache hits). From here on, any pod in any namespace
      # pulling quay.io/argoproj/argocd* must carry a keyless cosign
      # signature whose subject matches the image-reuse.yaml workflow on a
      # semver tag ref. Attempts to pull an unsigned ArgoCD image — e.g. a
      # fork, a malicious rebuild, or a stale unsigned pre-v2.8 version —
      # get rejected at admission.
      validationFailureAction = "Enforce"
      background              = true
      webhookTimeoutSeconds   = 30
      failurePolicy           = "Fail"

      rules = [
        {
          name = "verify-argocd-cosign"
          match = {
            any = [
              {
                resources = {
                  kinds      = ["Pod"]
                  operations = ["CREATE"]
                }
              },
            ]
          }
          verifyImages = [
            {
              imageReferences = [
                "quay.io/argoproj/argocd*",
                "quay.io/argoproj/argocd-applicationset*",
              ]
              mutateDigest = false
              attestors = [
                {
                  entries = [
                    {
                      keyless = {
                        subjectRegExp = "^https://github\\.com/argoproj/argo-cd/\\.github/workflows/image-reuse\\.yaml@refs/tags/v[0-9]+\\.[0-9]+\\.[0-9]+$"
                        issuer        = "https://token.actions.githubusercontent.com"
                        rekor = {
                          url = "https://rekor.sigstore.dev"
                        }
                      }
                    },
                  ]
                },
              ]
            },
          ]
        },
      ]
    }
  })

  depends_on = [
    helm_release.kyverno,
  ]
}
