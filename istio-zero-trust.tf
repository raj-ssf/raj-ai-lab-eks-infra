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
#   * Workloads in unmeshed namespaces (kyverno, vault, mount-s3, etc.)
#     calling meshed workloads — plaintext-no-identity problem under
#     STRICT mTLS. Generally these flows go the OTHER direction
#     (meshed pods call out to vault/kyverno admission webhooks),
#     which isn't blocked by destination-side AuthorizationPolicy.
#     If a future workload in those namespaces needs to call into the
#     mesh, the choices are: (a) mesh that namespace too, OR (b) keep
#     it unmeshed and use a per-port PERMISSIVE PeerAuthentication
#     override on the destination workload's specific port (carved
#     exemption — narrows the trust boundary instead of widening it).
#
#   * Kubelet probes — handled by Istio's rewriteAppHTTPProbes feature
#     (default true) which routes probes through the sidecar with
#     metadata that bypasses mTLS.
#
# Resolved by Phase #55:
#   * Prometheus scraping → meshed workloads — monitoring ns is now
#     meshed, prometheus has a SPIFFE cert, allow_prometheus_scrape_
#     meshwide grants /metrics + /stats/prometheus across the mesh.
#   * argo-rollouts → prometheus — argo-rollouts ns is now meshed,
#     allow_argo_rollouts_to_prometheus grants /api/v1/query +
#     /api/v1/query_range to argo-rollouts SA.
#   * App trace ingestion to tempo — allow_apps_to_tempo grants the
#     four app SAs into tempo's pod in monitoring ns.

# =============================================================================
# Removed 2026-04-28 (post-Gateway-API cleanup):
#   * kubectl_manifest.ingress_nginx_no_mtls (Phase 12b) — DestinationRule
#     that disabled mTLS for in-cluster pods → ingress-nginx Service.
#     Obsolete once ingress-nginx was uninstalled and the CoreDNS rewrite
#     to its ClusterIP was removed.
#   * kubectl_manifest.force_mtls (F4 cleanup) — DestinationRules forcing
#     ISTIO_MUTUAL on argocd-server, rag-service, chat-ui Services.
#     Originally workarounds for Istio's auto-mTLS asymmetry on regular
#     ClusterIP Services with named targetPorts (the named-port form
#     emitted no transport_socket on the outbound cluster, so source
#     Envoys connected in plaintext and matched no principal-based ALLOW).
#     They unblocked north-south traffic from ingress-nginx → meshed
#     backends. With ingress-nginx replaced by gateway-system's Istio
#     Gateway, the gateway's Envoy is meshed natively and connects with
#     proper SPIFFE identity to backends without any DR override.
# =============================================================================

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

  # Ordering rationale (post-Gateway-API): istiod must be installed
  # so the AuthorizationPolicy CRD exists. Pre-Gateway-API there was
  # also a force_mtls dependency (DestinationRules had to land before
  # deny-all activated to keep ingress-nginx → backend traffic alive
  # during the bring-up); that dependency is gone now that ingress-
  # nginx is decommissioned and the gateway-system Envoy connects to
  # backends with proper auto-mTLS.
  depends_on = [
    helm_release.istiod,
  ]
}

# =============================================================================
# Removed 2026-04-28 (post-Gateway-API cleanup):
#   * kubectl_manifest.allow_ingress_nginx — six per-namespace
#     AuthorizationPolicies admitting `cluster.local/ns/ingress-nginx/
#     sa/ingress-nginx` into argocd / keycloak / rag / langfuse /
#     langgraph / chat. Scoped to that one principal so only the
#     ingress controller could fan out. Obsolete now that ingress-
#     nginx is uninstalled and `gateway-system`'s Istio Gateway is
#     the only north-south entry point. The gateway-system principal
#     is admitted via the existing allow-public-ingress
#     AuthorizationPolicy (gateway-system.tf module) per-app.
# =============================================================================

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
    # Phase #55: monitoring and argo-rollouts now meshed (see
    # their namespace labels in prometheus-stack.tf and
    # argo-rollouts.tf). Add intra-ns allow so within-namespace
    # flows (grafana → prometheus, alertmanager → prometheus,
    # argo-rollouts-controller → argo-rollouts-dashboard) keep
    # working under STRICT mTLS.
    "monitoring",
    "argo-rollouts",
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

# Phase #3 RAGAS regression workflow: the ragas-eval Job (also runs
# under the eval-pod SA in the llm namespace, sharing the SA since
# both use the same Pod Identity binding for S3 writes) calls
# ingestion-service to seed the eval session with golden documents,
# then calls langgraph-service /invoke to run each question through
# the full RAG pipeline. Mesh-wide deny-all blocks both cross-ns
# calls without these ALLOW rules.
#
# Caught empirically 2026-04-29: first RAGAS workflow run after IAM/
# EKS-access/Kyverno prereqs landed got 403 RBAC denied at
# ingestion-service /upload. That's Istio's standard denial format
# for AuthorizationPolicy-rejected calls.
#
# Same SA principal as F4's eval Job — adding these here rather than
# splitting the eval-pod SA into two (one per workstream) because
# F4 lm-eval and #3 RAGAS share the same trust posture (read S3
# evals, write S3 results) and the IAM role they share already
# scopes their AWS access. The Istio principal is just an identity
# tag; one SA serving both eval flavors is fine.

resource "kubectl_manifest" "allow_eval_to_ingestion" {
  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"
    metadata = {
      name      = "allow-eval-pod"
      namespace = "ingestion"
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

resource "kubectl_manifest" "allow_eval_to_langgraph" {
  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"
    metadata = {
      name      = "allow-eval-pod"
      namespace = "langgraph"
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

# =============================================================================
# Phase #55: mesh-level STRICT mTLS + the AuthZ allow rules required
# to keep cross-namespace flows working after the flip.
#
# Before this phase, mesh PeerAuthentication was at default (PERMISSIVE
# auto-mTLS). PERMISSIVE means meshed-to-meshed gets mTLS automatically,
# but meshed workloads also accept plaintext from unmeshed sources. That
# left a real gap: an attacker landing in any unmeshed ns (kyverno,
# vault, mountpoint-s3, monitoring, argo-rollouts) could call meshed
# apps in plaintext and slip past authz that expected SPIFFE principals
# (the "no principal matches no allow rule" path means deny-by-default,
# but for non-AuthZ-protected workloads it means open-plaintext).
#
# STRICT closes that gap by REJECTING non-mTLS connections at the
# transport layer, before AuthZ even evaluates. Pre-flip, the lab had
# to mesh the two unmeshed namespaces that legitimately call meshed
# workloads: monitoring (prometheus → meshed apps for /metrics scrape)
# and argo-rollouts (controller → prometheus for AnalysisRun queries).
# Both are now meshed (see their kubernetes_namespace resources).
#
# Rules added below:
#   allow_prometheus_scrape_meshwide   cluster-scoped allow letting
#                                      monitoring/kube-prometheus-stack-
#                                      prometheus SA hit /metrics or
#                                      /stats/prometheus on any meshed
#                                      workload, regardless of namespace
#   allow_argo_rollouts_to_prometheus  argo-rollouts SA → prometheus
#                                      query API in monitoring ns
#   allow_apps_to_tempo                meshed apps (langgraph, rag,
#                                      ingestion, chat-ui) → tempo
#                                      OTLP gRPC for trace ingestion
#   mesh_strict_mtls                   the actual flip — PeerAuthentication
#                                      mode: STRICT in istio-system
#
# Order matters: PeerAuthentication.depends_on includes ALL the new
# allow rules so terraform applies them first. If terraform-apply is
# interrupted mid-phase, having allows-without-strict is safe (no
# behavior change); having strict-without-allows would break scraping
# and trace ingestion until the next apply.
# =============================================================================

# Cluster-scoped allow: prometheus can scrape /metrics on every meshed
# pod. Living in istio-system makes it apply mesh-wide; the empty
# selector (no spec.selector field) means "all workloads".
#
# Path-scoped to /metrics + /stats/prometheus so the rule grants ONLY
# the scrape capability — not arbitrary HTTP access. If prometheus's
# SA were ever compromised, the attacker can read metrics from every
# meshed app (which they could already do via kubectl port-forward
# anyway, given they hold prometheus's cluster-level kubectl creds);
# they CANNOT call /invoke or /retrieve or /upload.
resource "kubectl_manifest" "allow_prometheus_scrape_meshwide" {
  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"
    metadata = {
      name      = "allow-prometheus-scrape"
      namespace = "istio-system"
    }
    spec = {
      action = "ALLOW"
      rules = [
        {
          from = [{
            source = {
              principals = [
                "cluster.local/ns/monitoring/sa/kube-prometheus-stack-prometheus",
              ]
            }
          }]
          to = [{
            operation = {
              paths = ["/metrics", "/stats/prometheus"]
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

# argo-rollouts AnalysisRun queries → kube-prometheus-stack-prometheus
# /api/v1/query and /api/v1/query_range. Scoped to the controller SA
# (not the dashboard) since the dashboard reads via K8s API, not direct
# prometheus calls.
resource "kubectl_manifest" "allow_argo_rollouts_to_prometheus" {
  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"
    metadata = {
      name      = "allow-argo-rollouts"
      namespace = "monitoring"
    }
    spec = {
      selector = {
        matchLabels = {
          "app.kubernetes.io/name" = "prometheus"
        }
      }
      action = "ALLOW"
      rules = [
        {
          from = [{
            source = {
              principals = [
                "cluster.local/ns/argo-rollouts/sa/argo-rollouts",
              ]
            }
          }]
          to = [{
            operation = {
              paths = ["/api/v1/query", "/api/v1/query_range"]
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

# Meshed apps push OTLP traces to tempo on port 4317 (gRPC) and 4318
# (HTTP). Without this rule, all four service SAs would fail to
# deliver traces under STRICT mTLS — the cross-ns deny-all would
# block them.
#
# Selector matches the tempo pod label (set by the helm chart). Five
# source principals listed because each app SA needs its own auth
# context — Istio doesn't have a "wildcard principals in these
# namespaces" shortcut.
resource "kubectl_manifest" "allow_apps_to_tempo" {
  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"
    metadata = {
      name      = "allow-apps-to-tempo"
      namespace = "monitoring"
    }
    spec = {
      selector = {
        matchLabels = {
          "app.kubernetes.io/name" = "tempo"
        }
      }
      action = "ALLOW"
      rules = [
        {
          from = [{
            source = {
              principals = [
                "cluster.local/ns/langgraph/sa/langgraph-service",
                "cluster.local/ns/rag/sa/rag-service",
                "cluster.local/ns/ingestion/sa/ingestion-service",
                "cluster.local/ns/chat/sa/chat-ui",
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

# THE FLIP: PeerAuthentication mode for the mesh.
#
# STARTED at STRICT. REVERTED to PERMISSIVE 2026-04-30 after live
# testing surfaced the well-known Istio-vs-Prometheus-operator
# mismatch: ServiceMonitor-driven scrapes go directly to pod IPs
# (discovered via EndpointSlice), not to Service VIPs. Istio's
# auto-mTLS engages on Service-VIP routes but NOT on raw pod-IP
# connections (those fall through to PassthroughCluster, plaintext).
# Destination pods under STRICT then reject the plaintext at the
# inbound listener with 503.
#
# Symptoms observed under STRICT:
#   - All langgraph-service / rag-service / ingestion-service /
#     chat-ui scrape targets in Prometheus marked DOWN
#   - 1261 RBAC denies on langgraph's port 8000 inbound listener
#     within minutes
#   - Per-port stats counters showed inbound rbac.denied climbing
#     while rbac.allowed stayed at 6 (only the few legitimate non-
#     pod-IP calls succeeded)
#   - Direct test: prometheus → langgraph SERVICE VIP returned
#     metrics; prometheus → langgraph POD IP returned 503
#
# Why we don't fix-forward to STRICT:
#   The canonical Istio answer is to scrape istio-agent's merged
#   metrics endpoint at :15020 (which serves istio_* + merged
#   app-side metrics over a sidecar-managed listener that bypasses
#   the mTLS requirement). That requires:
#     (a) Reconfiguring every ServiceMonitor to scrape :15020 not
#         the app's metrics port
#     (b) Adding the prometheus.io/scrape + path annotations to
#         every meshed pod template
#     (c) Updating the Phase #14a custom scrape config in
#         prometheus-stack.tf to widen the namespace allow-list
#         (currently rag/qdrant/keycloak/argocd; would need
#         langgraph, chat, ingestion, monitoring too)
#     (d) Verifying the chat-ui side-port :8001 metrics still
#         work since they're outside the istio-agent merge path
#   That's significant refactor for a lab with ~2 months left.
#
# What this commit STILL gives us:
#   - Auto-mTLS for every meshed-to-meshed call: encryption-in-
#     transit between sidecar pairs is automatic. PERMISSIVE
#     accepts BOTH mTLS and plaintext; the plaintext fallback is
#     the gap.
#   - The deny-by-default AuthZ floor (Phase #20) still enforces
#     who-can-talk-to-who. An attacker landing in unmeshed ns can
#     send plaintext, but AuthZ rejects unless a matching ALLOW
#     exists for their (empty) principal.
#   - Defense isn't STRICT-grade but is much better than no-mesh.
#
# What this commit DELIBERATELY KEEPS:
#   - monitoring + argo-rollouts namespaces are still meshed
#     (sidecars now injected). Even under PERMISSIVE, those pods
#     get encrypted communication when calling other meshed apps.
#   - All four new AuthZ allow rules above stay applied. Under
#     PERMISSIVE they're not strictly required (no STRICT to
#     enforce), but they document the intent and become
#     load-bearing the moment STRICT is re-enabled.
#
# How to flip to STRICT in the future:
#   1. Refactor ServiceMonitors to scrape istio-agent :15020 OR
#      add per-port PERMISSIVE PeerAuthentication on each app's
#      metrics port (carved exemption — narrower trust boundary
#      than mesh-wide PERMISSIVE).
#   2. Validate scrape targets all UP under PERMISSIVE first.
#   3. Edit mode below back to STRICT, terraform apply.
#   4. Watch http.inbound_*.rbac.denied counters; should stay flat.
resource "kubectl_manifest" "mesh_strict_mtls" {
  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1"
    kind       = "PeerAuthentication"
    metadata = {
      name      = "default"
      namespace = "istio-system"
    }
    spec = {
      mtls = {
        # STRICT was attempted and reverted; see header comment.
        mode = "PERMISSIVE"
      }
    }
  })

  depends_on = [
    helm_release.istiod,
    kubectl_manifest.deny_all_mesh_wide,
    kubectl_manifest.allow_prometheus_scrape_meshwide,
    kubectl_manifest.allow_argo_rollouts_to_prometheus,
    kubectl_manifest.allow_apps_to_tempo,
    kubectl_manifest.allow_intra_namespace,
  ]
}
