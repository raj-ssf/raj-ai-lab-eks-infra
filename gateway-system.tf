# gateway-system namespace + the shared Istio Gateway.
#
# This is the north-south ingress equivalent of istio-zero-trust.tf:
# infrastructure that other workloads depend on but doesn't belong to
# any single app. The Gateway resource lives here; HTTPRoutes that
# attach to it (cross-ns parentRef) live in their respective app
# manifests in the apps repo.
#
# Why a dedicated namespace, not istio-system or default:
#   - Convention from Gateway API community + Istio docs.
#   - Lifecycle separation: Gateway resource churn shouldn't touch
#     istiod's namespace (where mistaken edits would be high-blast).
#   - When you eventually want per-tenant gateways (different cert
#     authorities, different listener policies), they each get their
#     own namespace cleanly.
#
# Why NO istio-injection label on gateway-system:
#   - The Istio Gateway controller deploys its own Envoy *as the
#     gateway pods* in this namespace. They aren't sidecared
#     workloads — they ARE the data plane. Adding the injection
#     label would re-inject istio-proxy onto Envoy itself, creating
#     a sidecar-on-Envoy mess.
#
# Phase 1 scope: ONE listener for rag.ekstest.com referencing the
# existing cert Secret in the rag namespace via ReferenceGrant.
# Subsequent phases add listeners for the other 9 hosts.

resource "kubernetes_namespace" "gateway_system" {
  metadata {
    name = "gateway-system"
    labels = {
      # Used by NetworkPolicies + AuthZ rules that need to identify
      # the gateway namespace specifically.
      "kubernetes.io/metadata.name" = "gateway-system"
    }
    # Explicitly do NOT set istio-injection here. See header comment.
  }
}

# Phase 1 Gateway: one listener for rag.ekstest.com. Subsequent
# phases append listeners for chat, keycloak, langfuse, langgraph,
# llm, grafana, vault, argocd, hello.
#
# Listener model: each (host, port, protocol) is its own listener.
# Istio's Gateway controller materializes ONE LoadBalancer Service
# fronting them all (single NLB) — listener objects share the LB,
# they don't each spawn one.
#
# allowedRoutes.namespaces.from = Selector + matchLabels constrains
# WHICH namespaces are allowed to attach HTTPRoutes via parentRef.
# We label app namespaces with `gateway-access=enabled` to opt in.
# Without the selector, default is "Same namespace" which would
# require all HTTPRoutes to live in gateway-system — wrong split.
resource "kubectl_manifest" "shared_gateway" {
  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = "shared-gateway"
      namespace = kubernetes_namespace.gateway_system.metadata[0].name
      annotations = {
        # Same NLB type the existing ingress-nginx uses. Istio's
        # gateway controller passes annotations through to the
        # Service it creates. Without this, the default is a CLB.
        "service.beta.kubernetes.io/aws-load-balancer-type"            = "nlb"
        "service.beta.kubernetes.io/aws-load-balancer-scheme"          = "internet-facing"
        "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
        # Lab's VPC subnets aren't tagged with kubernetes.io/role/elb,
        # so AWS LBC can't auto-discover them — Service stays in
        # 'pending' with the error "unable to resolve at least one
        # subnet (0 match VPC and tags: [kubernetes.io/role/elb])".
        # The existing ingress-nginx-controller works around this by
        # hardcoding the public subnets via this annotation. Same
        # data source (data.aws_subnets.public.ids in vpc.tf) so this
        # tracks any future subnet additions without code changes.
        "service.beta.kubernetes.io/aws-load-balancer-subnets"                           = join(",", data.aws_subnets.public.ids)
        "service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled" = "true"
      }
    }
    spec = {
      gatewayClassName = "istio"
      listeners = [
        {
          name     = "rag-https"
          hostname = "rag.ekstest.com"
          port     = 443
          protocol = "HTTPS"
          tls = {
            mode = "Terminate"
            certificateRefs = [
              {
                # Cross-ns ref — requires ReferenceGrant in rag ns
                # (see allow-gateway-cert-read.yaml in apps repo).
                kind      = "Secret"
                name      = "rag-tls"
                namespace = "rag"
              },
            ]
          }
          allowedRoutes = {
            namespaces = {
              from = "Selector"
              selector = {
                matchLabels = {
                  "gateway-access" = "enabled"
                }
              }
            }
          }
        },
        # Phase 4 of Gateway API migration: 2nd listener for
        # langgraph.ekstest.com. Same shape as rag-https; cert-Secret
        # in langgraph ns (langgraph-service-tls) referenced cross-ns
        # via langgraph_cert_reference_grant below.
        {
          name     = "langgraph-https"
          hostname = "langgraph.ekstest.com"
          port     = 443
          protocol = "HTTPS"
          tls = {
            mode = "Terminate"
            certificateRefs = [
              {
                kind      = "Secret"
                name      = "langgraph-service-tls"
                namespace = "langgraph"
              },
            ]
          }
          allowedRoutes = {
            namespaces = {
              from = "Selector"
              selector = {
                matchLabels = {
                  "gateway-access" = "enabled"
                }
              }
            }
          }
        },
      ]
    }
  })

  depends_on = [
    kubernetes_namespace.gateway_system,
    kubectl_manifest.gateway_api_crds,
  ]
}

# ReferenceGrant: authorize the Gateway in gateway-system to read
# the rag-tls Secret in rag.
#
# Gateway API's cross-namespace reference model: a Gateway listener
# in NS-A pointing at a Secret in NS-B is REJECTED unless NS-B
# has a ReferenceGrant explicitly authorizing it. This is the
# moral equivalent of "the resource owner has to opt in to the
# reader" — much stricter than the old Ingress model where ingress
# controllers could read Secrets across namespaces with broad RBAC.
#
# The ReferenceGrant lives in the TARGET namespace (rag), specifies
# WHO can read (Gateways from gateway-system) and WHAT they can read
# (this specific Secret kind). Wildcard "all Secrets" is allowed
# but we scope tighter — explicit names per granted resource.
resource "kubectl_manifest" "rag_cert_reference_grant" {
  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1beta1"
    kind       = "ReferenceGrant"
    metadata = {
      name      = "allow-gateway-system-cert-read"
      namespace = "rag"
    }
    spec = {
      from = [{
        group     = "gateway.networking.k8s.io"
        kind      = "Gateway"
        namespace = "gateway-system"
      }]
      to = [{
        group = ""        # core API group
        kind  = "Secret"
        name  = "rag-tls"
      }]
    }
  })

  depends_on = [
    kubectl_manifest.gateway_api_crds,
  ]
}

# Istio AuthorizationPolicy: allow the gateway pod's SA into the
# rag namespace.
#
# When traffic flows external → NLB → gateway-system/Envoy → rag-service,
# rag-service's istio-proxy sidecar enforces AuthorizationPolicies for
# *inbound* traffic. The cluster-wide deny-all means an explicit
# ALLOW per source principal is required. This is the moral equivalent
# of allow-ingress-nginx (which lets the NGINX SA into rag): now we
# need the same for the Istio Gateway's SA.
#
# Principal format: cluster.local/ns/<source-ns>/sa/<source-sa>
# The Istio gateway controller auto-creates a ServiceAccount named
# the same as the Gateway resource (shared-gateway-istio) in the
# gateway namespace. That's the SPIFFE identity the gateway pod
# presents on outbound mTLS to rag-service.
#
# Scoped to the rag namespace only — same per-app granularity as
# the existing allow-ingress-nginx + allow-langgraph-service policies.
# When other apps migrate to HTTPRoute, each will need a parallel
# allow-gateway policy in its own namespace.
# AuthorizationPolicy: allow public/unauthenticated traffic INTO
# the shared-gateway listener. Counterpart to the cluster-wide
# deny-all in istio-system.
#
# The deny-all (raj-ai-lab-eks-infra/istio-zero-trust.tf:
# kubectl_manifest.deny_all_mesh_wide) is a mesh-wide kill switch
# with empty spec — nothing flows without explicit allow. The
# gateway-system namespace IS meshed (the gateway pod IS Envoy,
# reading istiod's xDS), so the deny-all applies. Without this
# allow rule, every external request hits the gateway with 'RBAC:
# access denied' 403.
#
# Pattern: 'rules: [{}]' is the empty-rule idiom from Istio docs —
# matches any source, any method, any path. The selector scopes
# the rule to the gateway pod via the canonical Gateway-API label
# `gateway.networking.k8s.io/gateway-name=shared-gateway`. As more
# Gateway resources are added (currently only one), each gets its
# own allow rule via this same pattern with a different selector.
#
# Why this isn't a security hole:
#   - Authentication still happens at the APPLICATION layer
#     (Keycloak OIDC for chat-ui, JWT for langgraph-service, etc.)
#   - The L7 mesh AuthZ continues to enforce gateway → backend
#     identity (allow-gateway-system in each target namespace)
#   - Listener TLS still requires a valid client TLS handshake
#   - This rule only opens "external clients can reach the gateway
#     pod itself" — what comes through is still subject to every
#     downstream policy.
resource "kubectl_manifest" "shared_gateway_allow_public" {
  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"
    metadata = {
      name      = "allow-public-ingress"
      namespace = kubernetes_namespace.gateway_system.metadata[0].name
    }
    spec = {
      selector = {
        matchLabels = {
          "gateway.networking.k8s.io/gateway-name" = "shared-gateway"
        }
      }
      action = "ALLOW"
      rules = [
        {},
      ]
    }
  })

  depends_on = [
    kubectl_manifest.shared_gateway,
  ]
}

# Patch the Istio-created gateway Deployment to land its pod in
# us-west-2a, the AZ where the NLB has a subnet.
#
# Why this is needed:
#   The NLB is internet-facing and has only ONE subnet attached
#   (subnet-0b1efd3204b132ab6 in us-west-2a, the lab's only Public-
#   tagged subnet). NLBs only forward traffic to targets in their
#   own AZs — pods in us-west-2b/2c are reported as Target.NotInUse.
#   The default Istio gateway controller creates a single-replica
#   Deployment with no AZ constraint, so the pod can land anywhere.
#
# Why a null_resource patch instead of declarative:
#   Istio 1.24's Gateway API support doesn't expose nodeAffinity via
#   the Gateway resource (spec.infrastructure only handles labels +
#   annotations). The escape valve is to patch the underlying
#   Deployment after Istio creates it. Istio's controller doesn't
#   continuously reconcile the Deployment spec, so this patch
#   persists across normal cluster operations. If Istio is upgraded
#   in a way that recreates the Deployment, taint this null_resource
#   to re-apply.
#
# Alternative considered: 3 replicas with topologySpreadConstraints.
# Wasteful (3× pods for a low-traffic lab) and odds-based — no
# guarantee of an us-west-2a placement on every reschedule.
#
# Production fix would be: add subnets in 2b + 2c to the NLB so it
# spans all AZs, then drop this patch. Lab VPC has only one
# Public-tagged subnet though, so this lab-specific workaround
# stays until the VPC topology changes.
resource "null_resource" "gateway_nodeaffinity_patch" {
  triggers = {
    # Re-run the patch when the AZ constraint changes
    target_zone = "us-west-2a"
    # Track the gateway's identity so re-creation of the Gateway
    # also re-triggers the patch
    gateway_uid = kubectl_manifest.shared_gateway.uid
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl -n gateway-system patch deployment shared-gateway-istio --type=strategic --patch '{
        "spec": {
          "template": {
            "spec": {
              "affinity": {
                "nodeAffinity": {
                  "requiredDuringSchedulingIgnoredDuringExecution": {
                    "nodeSelectorTerms": [{
                      "matchExpressions": [{
                        "key": "topology.kubernetes.io/zone",
                        "operator": "In",
                        "values": ["${self.triggers.target_zone}"]
                      }]
                    }]
                  }
                }
              }
            }
          }
        }
      }'
    EOT
  }

  depends_on = [
    kubectl_manifest.shared_gateway,
  ]
}

resource "kubectl_manifest" "rag_authz_allow_gateway" {
  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"
    metadata = {
      name      = "allow-gateway-system"
      namespace = "rag"
    }
    spec = {
      action = "ALLOW"
      rules = [{
        from = [{
          source = {
            principals = [
              "cluster.local/ns/gateway-system/sa/shared-gateway-istio",
            ]
          }
        }]
      }]
    }
  })

  depends_on = [
    kubectl_manifest.shared_gateway,
  ]
}

# Label the rag namespace so HTTPRoutes there can attach to
# shared-gateway via parentRef. This is the opt-in mechanism for
# cross-namespace route attachment under Gateway API. Without this
# label, the Gateway's allowedRoutes.namespaces.selector won't
# match rag, and any HTTPRoute attempting to attach will be
# rejected with status condition Accepted=False, reason=NotAllowedByListeners.
resource "kubernetes_labels" "rag_gateway_access" {
  api_version = "v1"
  kind        = "Namespace"
  metadata {
    name = "rag"
  }
  labels = {
    "gateway-access" = "enabled"
  }
  force         = true
  field_manager = "terraform-raj-ai-lab"

  depends_on = [
    kubectl_manifest.shared_gateway,
  ]
}

# =============================================================================
# Phase 4: langgraph-service per-app resources.
#
# Same triplet (cert ReferenceGrant + gateway-source AuthZ + ns label)
# the rag-service migration introduced. Replicating per-app explicitly
# rather than templating with for_each so each app's wiring is legible
# and individually revertable. When N gets to 8-10, refactor to a
# Terraform module taking (app_name, namespace, cert_secret_name).
# =============================================================================

resource "kubectl_manifest" "langgraph_cert_reference_grant" {
  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1beta1"
    kind       = "ReferenceGrant"
    metadata = {
      name      = "allow-gateway-system-cert-read"
      namespace = "langgraph"
    }
    spec = {
      from = [{
        group     = "gateway.networking.k8s.io"
        kind      = "Gateway"
        namespace = "gateway-system"
      }]
      to = [{
        group = ""
        kind  = "Secret"
        name  = "langgraph-service-tls"
      }]
    }
  })

  depends_on = [
    kubectl_manifest.gateway_api_crds,
  ]
}

resource "kubectl_manifest" "langgraph_authz_allow_gateway" {
  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"
    metadata = {
      name      = "allow-gateway-system"
      namespace = "langgraph"
    }
    spec = {
      action = "ALLOW"
      rules = [{
        from = [{
          source = {
            principals = [
              "cluster.local/ns/gateway-system/sa/shared-gateway-istio",
            ]
          }
        }]
      }]
    }
  })

  depends_on = [
    kubectl_manifest.shared_gateway,
  ]
}

resource "kubernetes_labels" "langgraph_gateway_access" {
  api_version = "v1"
  kind        = "Namespace"
  metadata {
    name = "langgraph"
  }
  labels = {
    "gateway-access" = "enabled"
  }
  force         = true
  field_manager = "terraform-raj-ai-lab"

  depends_on = [
    kubectl_manifest.shared_gateway,
  ]
}
