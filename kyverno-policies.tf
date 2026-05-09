# =============================================================================
# Phase 6b: Kyverno baseline policies in AUDIT mode.
#
# Strategy: deploy in Audit (not Enforce) first. Audit policies emit
# PolicyReport CRs noting violations but DO NOT block admission. We
# observe what WOULD be blocked across the running workloads, then
# flip to Enforce in a follow-up phase once we've fixed the violations
# (or added exemptions for legitimate ones).
#
# Policies follow the K8s Pod Security Standards — Baseline tier
# (the "minimum bar" beneath Restricted). Each is implemented as a
# separate ClusterPolicy so we can flip them to Enforce independently.
#
# References:
#   https://kubernetes.io/docs/concepts/security/pod-security-standards/
#   https://kyverno.io/policies/  (community library)
# =============================================================================

# --- Disallow privileged containers -------------------------------------------
# A privileged container has near-host capabilities. Almost never legit.
# Common offenders: cilium-agent, cilium-envoy, ebs-csi-node, tetragon,
# eks-pod-identity-agent — all of which are SYSTEM workloads with
# legitimate need. The policy auto-exempts kube-system + tetragon
# namespaces; everything else gets audited.

resource "kubectl_manifest" "kyverno_disallow_privileged" {
  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "disallow-privileged-containers"
      annotations = {
        "policies.kyverno.io/title"       = "Disallow Privileged Containers"
        "policies.kyverno.io/category"    = "Pod Security Standards (Baseline)"
        "policies.kyverno.io/severity"    = "high"
        "policies.kyverno.io/description" = "Privileged containers can access host resources. Audit-only — flip to Enforce in 6c after fixing violations."
      }
    }
    spec = {
      validationFailureAction = "Audit"
      background              = true
      rules = [{
        name = "privileged-containers"
        match = {
          any = [{
            resources = {
              kinds = ["Pod"]
            }
          }]
        }
        # Skip system namespaces that legitimately need privileged
        # containers (Cilium agent, EBS CSI node driver, Tetragon).
        exclude = {
          any = [
            { resources = { namespaces = ["kube-system", "tetragon"] } },
          ]
        }
        validate = {
          message = "Privileged containers are forbidden by Pod Security Standards Baseline."
          pattern = {
            spec = {
              "=(initContainers)" = [{
                "=(securityContext)" = {
                  "=(privileged)" = "false"
                }
              }]
              containers = [{
                "=(securityContext)" = {
                  "=(privileged)" = "false"
                }
              }]
            }
          }
        }
      }]
    }
  })

  depends_on = [helm_release.kyverno]
}

# --- Require resource limits --------------------------------------------------
# Pods without limits can starve neighbors on the same node — Karpenter
# right-sizes nodes off requests, so missing limits = unbounded
# memory/CPU spike from one pod can cascade. Audit-only: a few system
# pods (chart defaults) ship without limits.

resource "kubectl_manifest" "kyverno_require_limits" {
  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "require-resource-limits"
      annotations = {
        "policies.kyverno.io/title"       = "Require Resource Limits"
        "policies.kyverno.io/category"    = "Pod Security Standards (Baseline)"
        "policies.kyverno.io/severity"    = "medium"
        "policies.kyverno.io/description" = "Containers must declare CPU and memory limits."
      }
    }
    spec = {
      validationFailureAction = "Audit"
      background              = true
      rules = [{
        name = "require-limits"
        match = {
          any = [{
            resources = {
              kinds = ["Pod"]
            }
          }]
        }
        exclude = {
          any = [
            { resources = { namespaces = ["kube-system"] } },
          ]
        }
        validate = {
          message = "All containers must declare CPU and memory limits."
          pattern = {
            spec = {
              containers = [{
                resources = {
                  limits = {
                    memory = "?*"
                    cpu    = "?*"
                  }
                }
              }]
            }
          }
        }
      }]
    }
  })

  depends_on = [helm_release.kyverno]
}

# --- Disallow latest tag ------------------------------------------------------
# `:latest` is irreproducible — what was deployed yesterday and what
# you'd deploy from the same manifest today are different bytes. Forces
# explicit pinning so rollbacks via image SHA are deterministic.

resource "kubectl_manifest" "kyverno_disallow_latest" {
  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "disallow-latest-tag"
      annotations = {
        "policies.kyverno.io/title"       = "Disallow Latest Tag"
        "policies.kyverno.io/category"    = "Best Practices"
        "policies.kyverno.io/severity"    = "medium"
        "policies.kyverno.io/description" = "Container images must be pinned to a specific tag (not :latest, not untagged)."
      }
    }
    spec = {
      validationFailureAction = "Audit"
      background              = true
      rules = [{
        name = "no-latest"
        match = {
          any = [{
            resources = {
              kinds = ["Pod"]
            }
          }]
        }
        validate = {
          message = "Image tag :latest is forbidden — pin to a specific tag or digest."
          pattern = {
            spec = {
              containers = [{
                "image" = "!*:latest"
              }]
            }
          }
        }
      }]
    }
  })

  depends_on = [helm_release.kyverno]
}

# --- Disallow hostPath volumes (with system-namespace exemptions) -------------
# hostPath mounts the node filesystem into a container — a privilege-
# escalation vector if the pod is compromised. Cilium / Tetragon /
# EBS CSI / kubelet-collector legitimately need it; everything else
# should declare PVCs / configMap / emptyDir instead.

resource "kubectl_manifest" "kyverno_disallow_hostpath" {
  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "disallow-host-path"
      annotations = {
        "policies.kyverno.io/title"       = "Disallow hostPath Volumes"
        "policies.kyverno.io/category"    = "Pod Security Standards (Baseline)"
        "policies.kyverno.io/severity"    = "high"
        "policies.kyverno.io/description" = "hostPath volumes mount the node filesystem; reserve for system-level workloads only."
      }
    }
    spec = {
      validationFailureAction = "Audit"
      background              = true
      rules = [{
        name = "no-hostpath"
        match = {
          any = [{
            resources = {
              kinds = ["Pod"]
            }
          }]
        }
        exclude = {
          any = [
            { resources = { namespaces = ["kube-system", "tetragon", "trivy-system", "velero"] } },
          ]
        }
        validate = {
          message = "hostPath volumes are forbidden outside system namespaces."
          pattern = {
            spec = {
              "=(volumes)" = [{
                "X(hostPath)" = "null"
              }]
            }
          }
        }
      }]
    }
  })

  depends_on = [helm_release.kyverno]
}

# =============================================================================
# Verify with:
#   kubectl get clusterpolicy
#   kubectl get policyreport -A         # per-pod policy results
#   kubectl get clusterpolicyreport     # cluster-scoped resource results
#
# Look for `result: fail` entries — those are the violations Audit-mode
# is collecting. Phase 6c will analyze those + flip the cleanest ones
# to validationFailureAction: Enforce.
# =============================================================================
