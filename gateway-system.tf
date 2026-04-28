# gateway-system namespace + the shared Istio Gateway.
#
# This is the north-south ingress equivalent of istio-zero-trust.tf:
# infrastructure that other workloads depend on but doesn't belong to
# any single app. The Gateway resource lives here as a singleton with
# multiple listeners; HTTPRoutes that attach to it (cross-ns parentRef)
# live in their respective app manifests in the apps repo.
#
# === REFACTOR (post-Phase 4) ===
# Per-app resources (ReferenceGrant + AuthorizationPolicy) collapsed
# into the local ./modules/gateway-app module, invoked once per app
# via for_each. The Gateway itself stays here (one shared NLB, can't
# be per-app). The list of apps drives BOTH:
#   - the Gateway's listeners list (one per app)
#   - the Gateway's allowedRoutes selector (namespace allowlist)
#   - the module invocations (per-app RG + AuthZ)
#
# Adding a new app to the migration is now a 5-line change to the
# locals.gateway_apps map below — the rest follows automatically.
#
# === Why a dedicated namespace ===
# Convention from Gateway API community + Istio docs. Lifecycle
# separation: Gateway resource churn shouldn't touch istiod's
# namespace. Per-tenant gateways could each get their own ns later.
#
# === Why NO istio-injection label on gateway-system ===
# The Istio Gateway controller deploys its own Envoy *as the gateway
# pods* in this namespace. They aren't sidecared workloads — they
# ARE the data plane. Adding the injection label would re-inject
# istio-proxy onto Envoy itself, creating a sidecar-on-Envoy mess.

resource "kubernetes_namespace" "gateway_system" {
  metadata {
    name = "gateway-system"
    labels = {
      "kubernetes.io/metadata.name" = "gateway-system"
    }
  }
}

# =============================================================================
# Driver map: which apps have HTTPRoutes attached to shared-gateway.
#
# Each entry produces a listener on the Gateway, an entry in the
# Gateway's allowedRoutes namespace allowlist, and an invocation of
# the gateway-app module (RG + AuthZ in the target ns).
#
# Adding a new app: append one block here. No other TF edits needed
# in this file. The corresponding Ingress/HTTPRoute changes still go
# in the apps repo + the per-app ArgoCD Application's kustomize patch
# in argocd-apps.tf.
# =============================================================================

locals {
  gateway_apps = {
    rag = {
      namespace        = "rag"
      hostname         = "rag.ekstest.com"
      cert_secret_name = "rag-tls"
      listener_name    = "rag-https"
    }
    langgraph = {
      namespace        = "langgraph"
      hostname         = "langgraph.ekstest.com"
      cert_secret_name = "langgraph-service-tls"
      listener_name    = "langgraph-https"
    }
    chat = {
      namespace        = "chat"
      hostname         = "chat.ekstest.com"
      cert_secret_name = "chat-ui-tls"
      listener_name    = "chat-https"
    }
  }

  # Allowlist of namespaces that may attach HTTPRoutes via parentRef.
  # Computed from the same map so a new app entry is auto-allowed.
  gateway_allowed_namespaces = [
    for app_key, app in local.gateway_apps : app.namespace
  ]
}

# =============================================================================
# Shared Gateway: one NLB, N listeners (one per app).
#
# Listener model: each (host, port, protocol) is its own listener.
# Istio's Gateway controller materializes ONE LoadBalancer Service
# fronting them all (single NLB).
#
# allowedRoutes selector matches by kubernetes.io/metadata.name (auto-
# applied + ArgoCD-immune) rather than a user-managed label. Each
# app's HTTPRoute uses parentRefs.sectionName to bind to a specific
# listener — so cross-listener attachment (e.g. langgraph traffic
# accidentally landing on rag-https) is prevented by the route, not
# the gateway.
# =============================================================================

resource "kubectl_manifest" "shared_gateway" {
  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = "shared-gateway"
      namespace = kubernetes_namespace.gateway_system.metadata[0].name
      annotations = {
        # Istio's gateway controller propagates these annotations
        # through to the underlying LoadBalancer Service.
        "service.beta.kubernetes.io/aws-load-balancer-type"            = "nlb"
        "service.beta.kubernetes.io/aws-load-balancer-scheme"          = "internet-facing"
        "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
        # Lab VPC subnets aren't ELB-tagged; explicit allowlist via
        # data.aws_subnets.public.ids (defined in vpc.tf).
        "service.beta.kubernetes.io/aws-load-balancer-subnets"                           = join(",", data.aws_subnets.public.ids)
        "service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled" = "true"
      }
    }
    spec = {
      gatewayClassName = "istio"
      # Build listeners list dynamically from the local.gateway_apps
      # map. Each app gets one HTTPS listener with TLS termination
      # via a cross-ns Secret reference (authorized by the per-app
      # ReferenceGrant in the gateway-app module).
      listeners = [
        for app_key, app in local.gateway_apps : {
          name     = app.listener_name
          hostname = app.hostname
          port     = 443
          protocol = "HTTPS"
          tls = {
            mode = "Terminate"
            certificateRefs = [{
              kind      = "Secret"
              name      = app.cert_secret_name
              namespace = app.namespace
            }]
          }
          allowedRoutes = {
            namespaces = {
              from = "Selector"
              selector = {
                matchExpressions = [{
                  key      = "kubernetes.io/metadata.name"
                  operator = "In"
                  values   = local.gateway_allowed_namespaces
                }]
              }
            }
          }
        }
      ]
    }
  })

  depends_on = [
    kubernetes_namespace.gateway_system,
    kubectl_manifest.gateway_api_crds,
  ]
}

# =============================================================================
# AuthorizationPolicy: allow public/unauthenticated traffic INTO the
# shared-gateway listener. Counterpart to the cluster-wide deny-all
# in istio-system.
#
# The deny-all (istio-zero-trust.tf:kubectl_manifest.deny_all_mesh_wide)
# is a mesh-wide kill switch with empty spec. The gateway-system
# namespace IS meshed (the gateway pod IS Envoy reading istiod's xDS),
# so the deny-all applies. Without this allow rule, every external
# request hits the gateway with 'RBAC: access denied' 403.
#
# 'rules: [{}]' is the empty-rule idiom from Istio docs — matches any
# source/method/path. Selector scopes the rule to the gateway pod via
# the canonical Gateway-API label. As more Gateways are added, each
# gets its own allow rule via this same pattern with a different
# selector.
#
# Authentication still happens at the APPLICATION layer (Keycloak
# OIDC for chat-ui, JWT for langgraph-service). Mesh AuthZ continues
# to enforce gateway → backend identity (via per-app allow-gateway-
# system policies in the gateway-app module). This rule only opens
# "external clients can reach the gateway pod itself."
# =============================================================================

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
      rules  = [{}]
    }
  })

  depends_on = [
    kubectl_manifest.shared_gateway,
  ]
}

# =============================================================================
# Patch the Istio-created gateway Deployment to land its pod in
# us-west-2a, the AZ where the NLB has a subnet.
#
# The lab VPC has only ONE Public-tagged subnet (us-west-2a). NLBs
# only forward traffic to targets in their own AZs — pods in 2b/2c
# are reported as Target.NotInUse. The default Istio gateway
# controller creates a single-replica Deployment with no AZ
# constraint, so the pod can land anywhere.
#
# Istio 1.24's Gateway API support doesn't expose nodeAffinity via
# the Gateway resource. The escape valve is to patch the underlying
# Deployment after Istio creates it. Istio's controller doesn't
# continuously reconcile the Deployment spec, so this patch
# persists across normal cluster operations. If Istio is upgraded
# in a way that recreates the Deployment, taint this null_resource
# to re-apply.
# =============================================================================

resource "null_resource" "gateway_nodeaffinity_patch" {
  triggers = {
    target_zone = "us-west-2a"
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

# =============================================================================
# Per-app resources: invoke the gateway-app module once per entry in
# local.gateway_apps. Each invocation creates a ReferenceGrant + an
# AuthorizationPolicy in the target namespace.
# =============================================================================

module "gateway_apps" {
  source   = "./modules/gateway-app"
  for_each = local.gateway_apps

  app_name         = each.key
  namespace        = each.value.namespace
  cert_secret_name = each.value.cert_secret_name
  # gateway_namespace + gateway_sa_name use defaults (gateway-system,
  # shared-gateway-istio).

  depends_on = [
    kubectl_manifest.shared_gateway,
    kubectl_manifest.gateway_api_crds,
  ]
}

# =============================================================================
# `moved` blocks: tell Terraform that the per-app resources have been
# renamed to module-relative addresses. WITHOUT these, terraform will
# plan to destroy the old top-level resources and recreate them inside
# the module — which would briefly delete the live K8s ReferenceGrant
# and AuthZ, breaking traffic mid-reconcile.
#
# With these blocks, terraform reads "this state is the same K8s
# resource, just under a new TF address" and reorganizes state with
# zero K8s-side activity.
#
# Once `terraform plan` confirms everything moves cleanly + applies
# successfully, these blocks can be deleted in a follow-up commit
# (state has converged; the moved blocks become no-ops).
# =============================================================================

moved {
  from = kubectl_manifest.rag_cert_reference_grant
  to   = module.gateway_apps["rag"].kubectl_manifest.cert_reference_grant
}

moved {
  from = kubectl_manifest.rag_authz_allow_gateway
  to   = module.gateway_apps["rag"].kubectl_manifest.authz_allow_gateway
}

moved {
  from = kubectl_manifest.langgraph_cert_reference_grant
  to   = module.gateway_apps["langgraph"].kubectl_manifest.cert_reference_grant
}

moved {
  from = kubectl_manifest.langgraph_authz_allow_gateway
  to   = module.gateway_apps["langgraph"].kubectl_manifest.authz_allow_gateway
}
