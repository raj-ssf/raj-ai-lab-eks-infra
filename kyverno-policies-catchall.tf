# Catch-all: in the four critical namespaces (rag, qdrant, keycloak, argocd),
# every container image must either be covered by a signature-verification
# policy (see kyverno-policies.tf + kyverno-policies-upstream.tf) OR be on the
# trusted-unsigned allowlist below. Anything else is denied at admission.
#
# Why this exists as a separate policy:
#   The verifyImages policies answer "is this specific signed image valid?"
#   They implicitly allow anything that doesn't match their imageReferences
#   glob — so a pod pulling docker.io/library/nginx into the rag namespace
#   would pass them all. This catch-all closes that hole by enforcing a
#   positive allowlist: if an image isn't on this list, it can't run here.
#
# Rollout discipline (same as other Kyverno policies in this repo):
#   1. Audit mode first. Check PolicyReports in the four namespaces.
#      kubectl get policyreport -n rag -n qdrant -n keycloak -n argocd
#   2. Widen the allowlist until pass=N, fail=0 across all pods.
#   3. Flip validationFailureAction to Enforce.
#
# Allowlist derivation: ran `kubectl get pods -o jsonpath=...` across all four
# namespaces to enumerate distinct image refs actually in use, then grouped
# them by publisher. Findings worth calling out:
#   - Bitnami images are now tagged `docker.io/bitnamilegacy/*`, not
#     `docker.io/bitnami/*` — a post-Broadcom rename. Both patterns included
#     for forward compatibility.
#   - ArgoCD bundles `ghcr.io/dexidp/dex` as an embedded IdP pod even when
#     upstream SSO (Keycloak) handles actual auth — so dex has to be on the
#     allowlist despite not being an argoproj publisher.
#   - `public.ecr.aws/*` is broad by design — AWS hosts many sub-namespaces
#     there (docker/library mirrors, eks-distro, bitnami mirrors). Trust is
#     at the registry level, not per-subpath.
#   - `hashicorp/vault*` is the Docker Hub short form; Kyverno globs don't
#     canonicalize registry names, so we list exactly the form pulled.

locals {
  kyverno_trusted_image_allowlist = [
    # Signed by our own GHA workflow (verify-rag-service-image-signature)
    "${aws_ecr_repository.rag_service.repository_url}*",

    # Signed by argoproj/argo-cd releases (verify-argocd-image-signatures)
    "quay.io/argoproj/argocd*",
    "quay.io/argoproj/argocd-applicationset*",

    # Trusted unsigned publishers
    "docker.io/istio/*",           # Istio mesh sidecars + control plane
    "docker.io/bitnami/*",         # Bitnami charts (post-rename: see bitnamilegacy)
    "docker.io/bitnamilegacy/*",   # Bitnami charts on current version (Broadcom rename)
    "hashicorp/vault*",            # Vault agent injector sidecar + server
    "qdrant/qdrant*",              # Qdrant vector DB
    "ghcr.io/dexidp/dex*",         # ArgoCD's bundled Dex IdP
    "public.ecr.aws/*",            # AWS public ECR (mirrors + EKS + official images)
  ]
}

resource "kubectl_manifest" "kyverno_deny_unverified_images" {
  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "deny-unverified-images-critical-namespaces"
    }
    spec = {
      # Flipped from Audit → Enforce after PolicyReports showed 0 fails across
      # all four critical namespaces. rag (rag-service+Istio+Vault), qdrant
      # (Qdrant+Istio), keycloak (Bitnami keycloak+postgres+Istio+Vault), and
      # argocd (argoproj images + dex + AWS-public redis + Istio) all pass the
      # allowlist in Audit. From here on, admission into these four namespaces
      # requires the image to be either signature-verified OR on the trusted-
      # unsigned allowlist below — anything else (e.g. `nginx:latest`, a
      # public busybox, a typo'd tag) gets rejected at the admission webhook.
      validationFailureAction = "Enforce"
      background              = true
      webhookTimeoutSeconds   = 30
      failurePolicy           = "Fail"

      rules = [
        {
          name = "require-image-on-allowlist"
          match = {
            any = [
              {
                resources = {
                  kinds      = ["Pod"]
                  namespaces = ["rag", "qdrant", "keycloak", "argocd"]
                  # CREATE only — same rationale as verify-rag-service-image-signature:
                  # UPDATE operations on existing Deployments for unrelated fields
                  # (e.g. replica count patches) shouldn't be blocked by container-spec
                  # admission checks. New Pods always go through CREATE.
                  operations = ["CREATE"]
                }
              },
            ]
          }
          validate = {
            # Top-level message can't reference `element` — that variable only
            # exists inside a foreach scope. Per-foreach messages below do the
            # work, so this one is a generic fallback.
            message = "Container image in namespace '{{ request.object.metadata.namespace }}' is not from a verified publisher and is not on the trusted-unsigned allowlist. See kyverno-policies-catchall.tf."
            foreach = [
              {
                list = "request.object.spec.containers"
                deny = {
                  conditions = {
                    all = [
                      {
                        message  = "Container image '{{ element.image }}' is not on the allowlist."
                        key      = "{{ element.image }}"
                        operator = "NotIn"
                        value    = local.kyverno_trusted_image_allowlist
                      },
                    ]
                  }
                }
              },
              {
                # Istio native sidecars + Vault agent injector both land here
                list = "request.object.spec.initContainers || `[]`"
                deny = {
                  conditions = {
                    all = [
                      {
                        message  = "InitContainer image '{{ element.image }}' is not on the allowlist."
                        key      = "{{ element.image }}"
                        operator = "NotIn"
                        value    = local.kyverno_trusted_image_allowlist
                      },
                    ]
                  }
                }
              },
              {
                # Ephemeral debug containers (kubectl debug) — rare, but if someone
                # attaches a debug container to a rag pod we want to gate it too.
                list = "request.object.spec.ephemeralContainers || `[]`"
                deny = {
                  conditions = {
                    all = [
                      {
                        message  = "EphemeralContainer image '{{ element.image }}' is not on the allowlist."
                        key      = "{{ element.image }}"
                        operator = "NotIn"
                        value    = local.kyverno_trusted_image_allowlist
                      },
                    ]
                  }
                }
              },
            ]
          }
        },
      ]
    }
  })

  depends_on = [
    helm_release.kyverno,
  ]
}
