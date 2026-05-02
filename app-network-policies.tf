# =============================================================================
# Phase #70f: NetworkPolicies for the 4 meshed application workloads
# (rag-service, langgraph-service, ingestion-service, chat-ui).
#
# Different reasoning from the controller-shape policies in #70-#70e
# because these apps live in MESHED namespaces. Istio AuthZ in
# istio-zero-trust.tf already enforces L7 (mTLS-authenticated SPIFFE
# principal-based ALLOW with deny-all default). NetworkPolicy here
# is L3/L4 defense-in-depth: if Istio is misconfigured or bypassed
# (e.g., through a CVE or a future operational mistake), the cluster
# still has SOME perimeter on these apps.
#
# Pattern for meshed apps (different from the controller policies):
#
#   Ingress  ALLOW from any meshed namespace.
#            Rationale: enumerating callers exhaustively is brittle
#            (every new app that calls into these surfaces another
#            edit), and Istio AuthZ already enforces precise L7
#            principal-based allows. NetworkPolicy here is the wider
#            net; Istio is the fine mesh.
#
#   Egress   Restricted but broad enough for meshed east-west:
#            - DNS (53) → CoreDNS
#            - istiod xDS (15012) → istio-system
#            - All ports → meshed namespaces (label
#              istio-injection=enabled). Istio AuthZ on the
#              destination-side restricts L7.
#            - Vault HTTP API (8200) → vault namespace (NOT meshed
#              per istio.tf — apps' Vault Agent sidecars need
#              direct L3 reach).
#            - K8s API (443) → 0.0.0.0/0 except IMDS. Apps using
#              the kubernetes_client library (most do for
#              ConfigMap watchers) need this.
#
# Apply path: NetworkPolicy applies to NEW connections only. The
# existing east-west TCP connections (rag→qdrant, langgraph→rag,
# etc.) keep flowing during apply. Failure surfaces on the next
# fresh connection — which can take seconds (chat→langgraph) or
# minutes (informer reconnect) depending on the call pattern.
#
# Smoke test pattern post-apply (pick one app, verify call graph):
#   kubectl exec -n langgraph deploy/langgraph-service -c langgraph-service -- \
#     curl -sf -m 5 http://rag-service.rag.svc.cluster.local:8080/healthz
#   # Should return HTTP 200. If "context deadline exceeded", the
#   # rag-service NetworkPolicy is wrong (or Istio AuthZ is wrong,
#   # but Istio rules haven't changed). If "no route to host", the
#   # langgraph egress rule is wrong.
#
# Phase #70 progression update:
#   #70   external-dns                  done
#   #70b  cert-manager controller       done
#   #70c  cert-manager webhook          done
#   #70d  cert-manager cainjector       done
#   #70e  vault server + injector       done
#   #70f  apps (this commit)            in-flight — adds 4 NPs
#   #70g  argocd + monitoring           next
# =============================================================================

locals {
  # Common egress rules shared by all 4 apps. Each NetworkPolicy
  # spec.egress list concats this with any app-specific rules.
  app_common_egress = [
    # DNS via CoreDNS (kube-system unmeshed)
    {
      to = [{
        namespaceSelector = {
          matchLabels = {
            "kubernetes.io/metadata.name" = "kube-system"
          }
        }
        podSelector = {
          matchLabels = {
            "k8s-app" = "kube-dns"
          }
        }
      }]
      ports = [
        { protocol = "UDP", port = 53 },
        { protocol = "TCP", port = 53 },
      ]
    },
    # istiod xDS — every meshed pod sidecar pulls config from istiod
    # over 15012. Without this, sidecars start with stale config
    # and become outdated.
    {
      to = [{
        namespaceSelector = {
          matchLabels = {
            "kubernetes.io/metadata.name" = "istio-system"
          }
        }
        podSelector = {
          matchLabels = {
            "istio" = "pilot"
          }
        }
      }]
      ports = [{ protocol = "TCP", port = 15012 }]
    },
    # All ports to any meshed namespace. The mesh's own AuthZ
    # rules in istio-zero-trust.tf provide the L7 enforcement;
    # this NetworkPolicy is the L3 envelope.
    {
      to = [{
        namespaceSelector = {
          matchLabels = {
            "istio-injection" = "enabled"
          }
        }
      }]
    },
    # Vault HTTP API — vault is NOT meshed (raft 8201 has its own
    # TLS, double-encryption with Istio mTLS would break). Apps'
    # Vault Agent sidecars need direct L3 reach to pull tokens.
    {
      to = [{
        namespaceSelector = {
          matchLabels = {
            "kubernetes.io/metadata.name" = "vault"
          }
        }
        podSelector = {
          matchLabels = {
            "app.kubernetes.io/name" = "vault"
            "component"              = "server"
          }
        }
      }]
      ports = [{ protocol = "TCP", port = 8200 }]
    },
    # K8s API server (443) — most apps' kubernetes_client uses
    # this for ConfigMap watchers, leader-election leases, etc.
    # 0.0.0.0/0 except IMDS, same defense-in-depth as the
    # controller-shape policies.
    {
      to = [{
        ipBlock = {
          cidr = "0.0.0.0/0"
          except = [
            "169.254.169.254/32", # IMDS
          ]
        }
      }]
      ports = [{ protocol = "TCP", port = 443 }]
    },
  ]

  # Common ingress rule shared by all 4 apps. Allow from any
  # meshed namespace (Istio AuthZ filters precise L7 access on
  # the destination side). This is L3 defense-in-depth — wider
  # than Istio's precise allows, but tight enough to block
  # unmeshed-namespace pods (kyverno, mount-s3, vault-secrets-
  # operator, kube-system non-DNS) from reaching app pods directly.
  app_common_ingress = [{
    from = [{
      namespaceSelector = {
        matchLabels = {
          "istio-injection" = "enabled"
        }
      }
    }]
  }]
}

resource "kubectl_manifest" "rag_service_netpol" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "rag-service"
      namespace = "rag"
    }
    spec = {
      podSelector = {
        matchLabels = { app = "rag-service" }
      }
      policyTypes = ["Ingress", "Egress"]
      ingress     = local.app_common_ingress
      egress      = local.app_common_egress
    }
  })

  depends_on = [helm_release.istiod]
}

resource "kubectl_manifest" "langgraph_service_netpol" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "langgraph-service"
      namespace = "langgraph"
    }
    spec = {
      podSelector = {
        matchLabels = { app = "langgraph-service" }
      }
      policyTypes = ["Ingress", "Egress"]
      ingress     = local.app_common_ingress
      egress      = local.app_common_egress
    }
  })

  depends_on = [helm_release.istiod]
}

resource "kubectl_manifest" "ingestion_service_netpol" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "ingestion-service"
      namespace = "ingestion"
    }
    spec = {
      podSelector = {
        matchLabels = { app = "ingestion-service" }
      }
      policyTypes = ["Ingress", "Egress"]
      ingress     = local.app_common_ingress
      egress      = local.app_common_egress
    }
  })

  depends_on = [helm_release.istiod]
}

resource "kubectl_manifest" "chat_ui_netpol" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "chat-ui"
      namespace = "chat"
    }
    spec = {
      podSelector = {
        matchLabels = { app = "chat-ui" }
      }
      policyTypes = ["Ingress", "Egress"]
      # Same common ingress as the others — allow from meshed namespaces.
      # chat-ui is special in one way: it ALSO receives north-south
      # traffic from gateway-system (shared-gateway-istio). gateway-system
      # IS NOT meshed (gateway is its own meshed thing — kind of mesh-
      # adjacent), so the common ingress wouldn't admit it. Add an
      # explicit allow.
      ingress = concat(local.app_common_ingress, [{
        from = [{
          namespaceSelector = {
            matchLabels = {
              "kubernetes.io/metadata.name" = "gateway-system"
            }
          }
        }]
      }])
      egress = local.app_common_egress
    }
  })

  depends_on = [helm_release.istiod]
}

# =============================================================================
# Phase #65 expansion: qdrant + llm NetworkPolicies (meshed-app pattern).
#
# Both namespaces are meshed (istio-injection=enabled). They reuse the
# app_common_ingress / app_common_egress locals defined at the top of
# this file. Each is the canonical "high-value workload in a meshed
# namespace" shape: ingress from any meshed namespace (Istio AuthZ
# filters L7 access on the destination side via the existing per-pod
# AuthorizationPolicy resources in istio-zero-trust.tf and
# istio.tf:qdrant_authz_policy), egress to common destinations
# (DNS, istiod, all meshed namespaces, vault, K8s API).
#
# qdrant:
#   The vector DB that rag-service queries on every retrieve. Phase
#   #76 made it a 3-pod Raft cluster with replication_factor=2.
#   Existing Istio AuthZ allows rag-service + ingestion-service +
#   intra-cluster qdrant→qdrant; this NetworkPolicy is the L3/L4
#   defense-in-depth on top.
#
# llm:
#   The vllm-* Deployments (Phase #80c HPA target, Phase #81d student).
#   eval Jobs (ragas, lm-eval) also run here. Many distinct pods with
#   different traffic shapes — using namespace-wide selector to cover
#   them all uniformly. langgraph-service / chat-ui / ingestion-service
#   call vllm Services from their respective meshed namespaces;
#   app_common_ingress's `istio-injection=enabled` selector admits all
#   of them. eval Jobs run IN this namespace so they're admitted by
#   the intra-namespace allow already in istio-zero-trust.tf.
# =============================================================================

resource "kubectl_manifest" "qdrant_netpol" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "qdrant"
      namespace = "qdrant"
    }
    spec = {
      podSelector = {} # all pods (qdrant + any future helper pods)
      policyTypes = ["Ingress", "Egress"]
      ingress     = local.app_common_ingress
      egress      = local.app_common_egress
    }
  })

  depends_on = [helm_release.istiod]
}

resource "kubectl_manifest" "llm_netpol" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "llm"
      namespace = "llm"
    }
    spec = {
      podSelector = {} # all pods (vllm-*, eval-pod Jobs)
      policyTypes = ["Ingress", "Egress"]
      ingress     = local.app_common_ingress
      egress      = local.app_common_egress
    }
  })

  depends_on = [helm_release.istiod]
}
