# ClusterPolicy: every Pod landing in the `rag` namespace whose image
# reference matches our ECR repo must carry a valid cosign signature
# whose subject matches the GHA OIDC identity of our build workflow.
#
# Rollout intent: start scoped to `rag` only. Once the GHA sign step
# has run once and rag-service is on a signed image, we can widen to
# other namespaces (qdrant, keycloak, etc.) by adding them to
# match.any.resources.namespaces.
#
# Why keyless: the GHA OIDC token → Sigstore Fulcio → short-lived
# signing cert. No private key to manage or rotate. The "subject"
# below is literally the workflow file path on the GitHub ref,
# making forgery require control of the GitHub repo + branch.

resource "kubectl_manifest" "kyverno_verify_rag_service_image" {
  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "verify-rag-service-image-signature"
    }
    spec = {
      # Enforce: Kyverno rejects pods at admission when the verifyImages
      # rule fails. The legitimate rag-service image is signed by our GHA
      # workflow and passes (verified via Audit-mode policy reports
      # before this flip). Any image without a matching signature —
      # whether unsigned, signed by a different identity, or pushed
      # outside our pipeline — gets rejected with a clear Kyverno error.
      validationFailureAction = "Enforce"
      # background scans re-evaluate existing pods on Kyverno's internal
      # timer (default hourly) so we see reports for pods that were running
      # before the policy existed — not just newly-admitted ones.
      background              = true
      webhookTimeoutSeconds   = 30
      failurePolicy           = "Fail"

      rules = [
        {
          name = "verify-cosign-signature"
          match = {
            any = [
              {
                resources = {
                  kinds      = ["Pod"]
                  namespaces = ["rag"]
                  # CREATE only — avoids mutateDigest's rough edge where
                  # UPDATE operations on existing Deployments (e.g. patching
                  # replicas/revisionHistoryLimit) fail validation because
                  # the Deployment's image is still in tag form and the
                  # mutating phase doesn't rewrite it unless the image
                  # itself is being modified. New Pods always go through
                  # admission CREATE, so the signature gate stays intact.
                  operations = ["CREATE"]
                }
              },
            ]
          }
          verifyImages = [
            {
              # Glob match against our ECR registry/repo. Signatures for
              # any tag pushed by the GHA workflow are covered because
              # cosign keys them on digest, not tag.
              imageReferences = [
                "${aws_ecr_repository.rag_service.repository_url}*",
              ]
              # imageRegistryCredentials: Kyverno auths to ECR via the
              # IAM role on its Pod Identity association; no explicit
              # secret configuration needed.
              #
              # mutateDigest: true now that we're in Enforce mode. Kyverno
              # rewrites each pod's image reference from tag-form to
              # pinned-digest-form at admission. Net effect: the pod runs
              # the exact bits that were signed, not whatever a mutable
              # tag could later drift to. Together with the signature
              # check, this closes the "push a new image with the old
              # tag" TOCTOU hole.
              mutateDigest = true
              attestors = [
                {
                  entries = [
                    {
                      keyless = {
                        # GHA OIDC identity for this specific workflow
                        # file on the main branch. Changing the workflow
                        # path or branch requires a policy update.
                        subject = "https://github.com/${var.gha_repo_owner}/${var.gha_repo_name}/.github/workflows/build-push-rag-service.yml@refs/heads/main"
                        issuer  = "https://token.actions.githubusercontent.com"
                        rekor = {
                          url = "https://rekor.sigstore.dev"
                        }
                      }
                    },
                  ]
                },
              ]
              # mutateDigest defaults to true — Kyverno rewrites the image
              # tag reference to its pinned digest at admission time. Good
              # hardening: ensures the admitted pod runs exactly the
              # signed bits, not whatever a mutable tag could rotate to.
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
