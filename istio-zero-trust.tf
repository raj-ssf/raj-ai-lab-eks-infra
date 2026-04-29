# Cluster-wide zero-trust enforcement layer for the Istio mesh.
#
# Three policy types stacked here:
#
#   1. Cluster-wide deny-all (istio-system root namespace) — blocks all
#      traffic between meshed workloads by default. AuthorizationPolicies
#      in the root namespace apply to every workload in the mesh; an
#      empty rules block means "no traffic allowed unless another
#      policy explicitly allows it."
#
#   2. Per-namespace allow-from-ingress-nginx — re-opens the north-south
#      path for the four ingress-nginx-fronted services (argocd-server,
#      keycloak, rag-service, langfuse-web). Now that ingress-nginx
#      runs with an Istio sidecar (see nginx-ingress.tf
#      controller.podAnnotations), it has a SPIFFE identity
#      `cluster.local/ns/ingress-nginx/sa/ingress-nginx` we can match on.
#
#   3. Per-namespace allow-intra-namespace — restores east-west traffic
#      between workloads in the same ns. Necessary because deny-all
#      blocks ALL traffic, including same-ns calls (e.g., langfuse-web
#      calling langfuse-postgres, argocd-server calling
#      argocd-application-controller). Constrained to the source's
#      namespace via `from.namespaces`.
#
#   4. Cross-namespace allows — explicit holes for known service-to-
#      service flows that cross namespace boundaries:
#        rag-service (rag ns) → langfuse-web (langfuse ns)
#                                — for trace ingestion via Langfuse SDK
#
# Things that still won't work after this layer (known limitations,
# tracked as follow-up milestones):
#
#   * Prometheus scraping → meshed workloads. monitoring ns is unmeshed,
#     so prometheus's HTTP scrape requests have no SPIFFE identity and
#     match no allow rule. Mitigations: mesh monitoring ns (best), or
#     add ipBlock-based allow rules (brittle), or expose /metrics on a
#     separate sidecar-bypassed port. Deferred.
#
#   * Workloads in unmeshed namespaces (kyverno, vault, mount-s3, etc.)
#     calling meshed workloads — same plaintext-no-identity problem.
#     Generally these flows go the OTHER direction (meshed pods call
#     out to vault/kyverno admission webhooks), which isn't blocked by
#     destination-side AuthorizationPolicy.
#
#   * Kubelet probes — handled by Istio's rewriteAppHTTPProbes feature
#     (default true) which routes probes through the sidecar with
#     metadata that bypasses mTLS.

# =============================================================================
# DestinationRule: force ISTIO_MUTUAL TLS on the four ingress-fronted
# Services.
#
# Why this exists: Istio's auto-mTLS inference is asymmetric for
# regular ClusterIP Services that use named targetPorts (e.g.,
# `targetPort: http`). The headless variant of each Service gets
# auto-mTLS configured cleanly (its EDS endpoints carry the in-mesh
# metadata directly), but the ClusterIP variant ends up with no
# `transport_socket` on its outbound cluster — meaning the source
# Envoy connects in plaintext, which arrives at the destination
# sidecar with no SPIFFE identity, which fails to match any
# principal-based ALLOW rule. Result: 403 RBAC: access denied.
#
# Diagnosed 2026-04-25 on this cluster:
#   outbound|80||keycloak.keycloak.svc.cluster.local           transport_socket: <none>
#   outbound|8080||keycloak-headless.keycloak.svc.cluster.local transport_socket: TLS (Istio mutual)
# Same asymmetry on the postgres pair, and on argocd-server,
# rag-service, langfuse-web (all ClusterIP variants).
#
# Forcing tls.mode=ISTIO_MUTUAL via DestinationRule overrides the
# auto-mTLS quirk and makes the source Envoy initiate mTLS
# regardless. Once mTLS engages, the source's SPIFFE principal
# arrives at the destination sidecar and the allow-ingress-nginx
# rules below match correctly.
#
# Scope: only the four Services that NGINX ingresses reference.
# Other in-cluster Services (intra-langfuse, intra-argocd) work
# fine because they go pod-to-pod via headless Services or ports
# that auto-mTLS handles correctly.
# =============================================================================

locals {
  # Map of ingress-fronted Services that need explicit ISTIO_MUTUAL
  # TLS forcing. Format: key = display name, value = (namespace, service-name).
  # The DestinationRule's `host` is constructed as
  # `<service>.<namespace>.svc.cluster.local` (Istio's canonical FQDN).
  #
  # Inclusion criterion: the destination Service's pods MUST be meshed
  # (have an istio-proxy sidecar). Forcing ISTIO_MUTUAL to an unmeshed
  # destination produces "TLS_error: WRONG_VERSION_NUMBER" because the
  # destination has no sidecar to terminate mTLS — Envoy returns 503 to
  # both internal callers AND the ingress-nginx hop.
  #
  # langfuse-web is intentionally absent: the langfuse Helm chart's pods
  # are unmeshed (the langfuse namespace has no istio-injection label,
  # because mTLS-wrapping its Postgres/ClickHouse/Redis traffic would
  # break those non-HTTP protocols). Add langfuse-web back here only if
  # the langfuse namespace is later mesh-injected.
  force_mtls_targets = {
    argocd-server = { namespace = "argocd",   service = "argocd-server" }
    # keycloak removed 2026-04-28 — same rationale as langfuse-web's
    # earlier removal: keycloak's pod has no istio-proxy sidecar (the
    # istio-injection label on keycloak ns is unstable due to ArgoCD
    # stripping it; new pods rolled by helm upgrades land without a
    # sidecar). force-mtls on an unmeshed destination causes
    # TLS_error: WRONG_VERSION_NUMBER → 503 from the gateway. After
    # Phase 12b removes ingress-nginx, ALL the remaining force-mtls
    # entries here become obsolete (they were workarounds for NGINX's
    # auto-mTLS detection asymmetry, not needed for the meshed
    # gateway-system Envoy). Cleanup deferred to a follow-up.
    rag-service   = { namespace = "rag",      service = "rag-service" }
    chat-ui       = { namespace = "chat",     service = "chat-ui" }
  }
}

resource "kubectl_manifest" "force_mtls" {
  for_each = local.force_mtls_targets

  yaml_body = yamlencode({
    apiVersion = "networking.istio.io/v1"
    kind       = "DestinationRule"
    metadata = {
      name      = "force-mtls-${each.key}"
      namespace = each.value.namespace
    }
    spec = {
      host = "${each.value.service}.${each.value.namespace}.svc.cluster.local"
      trafficPolicy = {
        tls = {
          # ISTIO_MUTUAL: source Envoy initiates mTLS using the
          # workload's SPIFFE cert. Destination Envoy validates and
          # extracts the source principal for AuthorizationPolicy.
          mode = "ISTIO_MUTUAL"
        }
      }
    }
  })

  depends_on = [
    helm_release.istiod,
  ]
}

# (Removed 2026-04-28, Phase 12b cleanup: kubectl_manifest.ingress_nginx_no_mtls
#  DestinationRule. It disabled mTLS for in-cluster source pods → ingress-nginx
#  Service traffic, working around an Istio auto-mTLS conflict with the
#  CoreDNS rewrite that mapped keycloak.ekstest.com → ingress-nginx ClusterIP.
#  Now that ingress-nginx is uninstalled, the CoreDNS rewrite is gone too,
#  and there's no in-cluster path to ingress-nginx to mTLS-disable.)

# =============================================================================
# Cluster-wide deny-all in the mesh root namespace.
#
# Empty `rules` field with default ALLOW action means "no rules match,
# so nothing is allowed by this policy." Combined with Istio's
# evaluation logic ("if any DENY matches, deny; else if any ALLOW
# matches, allow; else deny by default when there's at least one ALLOW
# policy in scope"), this acts as the implicit deny floor.
#
# To promote later from "audit-only" to "enforced", this is already the
# enforced version. To temporarily soften (for debugging), set
# action=AUDIT — Envoy will log would-be-denies to its access log
# without actually rejecting traffic. That mode requires the
# Telemetry CR + an access-log backend to be useful, neither of which
# is wired up in this lab yet, so we go straight to enforced.
# =============================================================================

resource "kubectl_manifest" "deny_all_mesh_wide" {
  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"
    metadata = {
      name      = "deny-all"
      namespace = "istio-system"
    }
    spec = {
      # No selector + root namespace = applies to ALL workloads in the
      # mesh (across every namespace).
      # No rules + default ALLOW action = nothing matches = traffic
      # denied unless another ALLOW policy elsewhere matches.
    }
  })

  # Ordering rationale: ingress-nginx Helm release picks up the new
  # podLabels (sidecar.istio.io/inject=true), rolls its pods
  # (deploys sidecared replacements), DestinationRules force mTLS
  # on the ingress-fronted backends, THEN deny-all activates. If we
  # applied deny-all first, the still-unmeshed ingress-nginx pods
  # (or the still-plaintext outbound clusters) would have no SPIFFE
  # identity reaching the backend sidecars, and the allow-ingress-nginx
  # rules below wouldn't match — briefly breaking north-south traffic.
  depends_on = [
    helm_release.istiod,
    kubectl_manifest.force_mtls,
  ]
}

# =============================================================================
# Per-namespace ALLOW: ingress-nginx → anything in this namespace.
#
# Now that ingress-nginx runs with an Istio sidecar
# (nginx-ingress.tf controller.podAnnotations enables injection), all
# its outbound calls to backend pods initiate mTLS using its SPIFFE ID
# `cluster.local/ns/ingress-nginx/sa/ingress-nginx`. These four
# policies allow that ID into the four namespaces fronted by
# Ingress resources (rag.ekstest.com → rag, keycloak.ekstest.com →
# keycloak, argocd.ekstest.com → argocd, langfuse.ekstest.com →
# langfuse).
#
# Scope is intentionally ns-wide (no `selector`): there's only one
# ingress target per ns today (rag-service, keycloak, argocd-server,
# langfuse-web), so the broader scope is harmless and survives the
# future addition of secondary ingress targets without a policy edit.
# =============================================================================

locals {
  # Namespaces where ingress-nginx terminates ingress traffic and
  # forwards to a meshed backend. argocd / keycloak / rag / langfuse
  # are all istio-injection=enabled per locals in istio.tf.
  ingress_nginx_fronted_namespaces = toset([
    "argocd",
    "keycloak",
    "rag",
    "langfuse",
    "langgraph",
    "chat",
  ])
}

resource "kubectl_manifest" "allow_ingress_nginx" {
  for_each = local.ingress_nginx_fronted_namespaces

  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"
    metadata = {
      name      = "allow-ingress-nginx"
      namespace = each.value
    }
    spec = {
      action = "ALLOW"
      rules = [
        {
          from = [{
            source = {
              principals = [
                "cluster.local/ns/ingress-nginx/sa/ingress-nginx",
              ]
            }
          }]
        },
      ]
    }
  })

  depends_on = [
    helm_release.istiod,
    kubectl_manifest.deny_all_mesh_wide,
  ]
}

# =============================================================================
# Per-namespace ALLOW: intra-namespace east-west traffic.
#
# Without these, deny-all blocks every same-ns call (e.g., langfuse-web
# → langfuse-postgres, argocd-server → argocd-application-controller).
# `from.namespaces` matches the source workload's namespace as carried
# in its mTLS SPIFFE ID, so this only opens traffic between meshed
# pods within the same ns — unmeshed traffic is still denied.
#
# argocd, keycloak, rag, langfuse are the four namespaces where mesh
# is enabled and where multi-pod east-west traffic exists. qdrant is
# also meshed but has only one workload (qdrant statefulset itself),
# so intra-ns allow is unnecessary — its tighter allow-rag-service-only
# in istio.tf covers the only inbound flow.
# =============================================================================

locals {
  intra_namespace_allow_namespaces = toset([
    "argocd",
    "keycloak",
    "rag",
    "langfuse",
    "langgraph",
  ])
}

resource "kubectl_manifest" "allow_intra_namespace" {
  for_each = local.intra_namespace_allow_namespaces

  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"
    metadata = {
      name      = "allow-intra-namespace"
      namespace = each.value
    }
    spec = {
      action = "ALLOW"
      rules = [
        {
          from = [{
            source = {
              namespaces = [each.value]
            }
          }]
        },
      ]
    }
  })

  depends_on = [
    helm_release.istiod,
    kubectl_manifest.deny_all_mesh_wide,
  ]
}

# =============================================================================
# Cross-namespace ALLOW: rag-service → langfuse-web.
#
# Langfuse SDK in rag-service POSTs traces to the langfuse-web ingestion
# endpoint. After mesh-wide deny-all, this would be denied since the
# rag namespace's allow-intra-namespace policy doesn't cover destinations
# in another ns.
#
# Scoped to the rag-service SA specifically (not the whole rag ns) so
# only the intended workload can use the cross-namespace path.
# =============================================================================

resource "kubectl_manifest" "allow_rag_to_langfuse" {
  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"
    metadata = {
      name      = "allow-rag-service"
      namespace = "langfuse"
    }
    spec = {
      action = "ALLOW"
      rules = [
        {
          from = [{
            source = {
              principals = [
                "cluster.local/ns/rag/sa/rag-service",
              ]
            }
          }]
        },
      ]
    }
  })

  depends_on = [
    helm_release.istiod,
    kubectl_manifest.deny_all_mesh_wide,
  ]
}

# =============================================================================
# Cross-namespace ALLOW: langgraph-service → langfuse-web.
#
# Same shape as allow_rag_to_langfuse above. langgraph-service's Langfuse
# v3 callback handler emits trace events to langfuse-web on every graph
# run; without this rule, mesh-wide deny-all blocks the connection at
# Envoy and the SDK silently drops spans. Scoped to the SA so only the
# intended workload uses the cross-namespace path.
# =============================================================================

resource "kubectl_manifest" "allow_langgraph_to_langfuse" {
  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"
    metadata = {
      name      = "allow-langgraph-service"
      namespace = "langfuse"
    }
    spec = {
      action = "ALLOW"
      rules = [
        {
          from = [{
            source = {
              principals = [
                "cluster.local/ns/langgraph/sa/langgraph-service",
              ]
            }
          }]
        },
      ]
    }
  })

  depends_on = [
    helm_release.istiod,
    kubectl_manifest.deny_all_mesh_wide,
  ]
}

# Phase 4: rag-service's new /retrieve endpoint embeds queries via
# vllm-bge-m3 in the llm namespace. The mesh-wide deny-all blocks
# rag's SA from reaching llm's pods; this allow rule unblocks it.
#
# Sits alongside the existing allow-ingestion-service policy in the
# llm ns (see ingestion-service.tf). Istio combines multiple ALLOW
# rules with OR semantics — naming this policy distinctly
# (allow-rag-service vs. allow-ingestion-service) keeps the two
# producers' permissions independent and easy to revoke individually.
#
# This is the symmetric counterpart of allow-rag-service-only on the
# qdrant side: rag-service was always allowed into qdrant; today's
# add gives it the embedder it needs to BUILD the query vector first.
resource "kubectl_manifest" "allow_rag_to_llm" {
  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"
    metadata = {
      name      = "allow-rag-service"
      namespace = "llm"
    }
    spec = {
      action = "ALLOW"
      rules = [
        {
          from = [{
            source = {
              principals = [
                "cluster.local/ns/rag/sa/rag-service",
              ]
            }
          }]
        },
      ]
    }
  })

  depends_on = [
    helm_release.istiod,
    kubectl_manifest.deny_all_mesh_wide,
  ]
}

# Phase 4: langgraph-service's retrieve node calls rag-service /retrieve
# for per-session RAG. The mesh-wide deny-all blocks this east-west hop
# by default; this policy allows the langgraph SA into the rag namespace.
# Scoped to the rag-service workload via app=rag-service selector so the
# rule survives if other (less-trusted) workloads ever land in rag ns.
resource "kubectl_manifest" "allow_langgraph_to_rag" {
  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"
    metadata = {
      name      = "allow-langgraph-service"
      namespace = "rag"
    }
    spec = {
      selector = {
        matchLabels = {
          app = "rag-service"
        }
      }
      action = "ALLOW"
      rules = [
        {
          from = [{
            source = {
              principals = [
                "cluster.local/ns/langgraph/sa/langgraph-service",
              ]
            }
          }]
          to = [{
            operation = {
              methods = ["POST"]
              paths   = ["/retrieve"]
            }
          }]
        },
      ]
    }
  })

  depends_on = [
    helm_release.istiod,
    kubectl_manifest.deny_all_mesh_wide,
  ]
}

# Fine-tuning F4: eval-pod (in the llm namespace) needs to call the
# vllm-llama-8b Service to compare base vs LoRA-merged inference. The
# mesh-wide deny-all blocks even same-namespace traffic unless an ALLOW
# policy admits the source principal — without this, the eval Job's
# requests get 403 'RBAC: access denied' from Istio at the vLLM
# sidecar's RBAC filter (verified the failure mode in run 4).
#
# Same shape as allow-rag-service / allow-langgraph-service / etc.
# Scoped to a single SA principal so that future llm-namespace
# workloads have to be allowlisted explicitly.
resource "kubectl_manifest" "allow_eval_to_llm" {
  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"
    metadata = {
      name      = "allow-eval-pod"
      namespace = "llm"
    }
    spec = {
      action = "ALLOW"
      rules = [
        {
          from = [{
            source = {
              principals = [
                "cluster.local/ns/llm/sa/eval-pod",
              ]
            }
          }]
        },
      ]
    }
  })

  depends_on = [
    helm_release.istiod,
    kubectl_manifest.deny_all_mesh_wide,
  ]
}

# Eval (optional) emits a Langfuse trace summarizing each run. Same
# cross-namespace pattern as allow_langgraph_to_langfuse — the
# langfuse namespace's mesh-wide deny-all blocks the eval pod's
# trace POST without this rule. Scoped to the eval-pod SA only.
# The eval Job no-ops Langfuse if LANGFUSE_PUBLIC_KEY env is unset,
# so this rule is harmless even before the user creates the Secret.
resource "kubectl_manifest" "allow_eval_to_langfuse" {
  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"
    metadata = {
      name      = "allow-eval-pod"
      namespace = "langfuse"
    }
    spec = {
      action = "ALLOW"
      rules = [
        {
          from = [{
            source = {
              principals = [
                "cluster.local/ns/llm/sa/eval-pod",
              ]
            }
          }]
        },
      ]
    }
  })

  depends_on = [
    helm_release.istiod,
    kubectl_manifest.deny_all_mesh_wide,
  ]
}
