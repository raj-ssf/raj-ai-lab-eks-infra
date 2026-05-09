# =============================================================================
# gateway-system namespace + shared-gateway (Cilium-flavored).
#
# Phase 3 of Cilium migration. Replaces the old Istio shared-gateway from
# the OpenShift/Istio era of this lab. Differences from the predecessor:
#
#   - gatewayClassName: "cilium" (not "istio"). Cilium auto-registers
#     this GatewayClass once the upstream Gateway API CRDs are present
#     (see gateway-api.tf). Confirm with `kubectl get gatewayclass`.
#
#   - No AuthorizationPolicy (Istio CRD; doesn't exist in Cilium).
#     L7 access control will come back in Phase 5 via CiliumNetworkPolicy.
#
#   - No replicas / nodeAffinity null_resource patches (Istio created a
#     separate Deployment per Gateway; Cilium uses the cilium-envoy
#     DaemonSet that's already running on every EC2 worker, so HA +
#     placement are inherited from the cilium-envoy DaemonSet config).
#
#   - No gateway-app module yet (per-app ReferenceGrants + AuthZ).
#     Phase 3 only routes the two services that exist in Phase 2:
#     grafana + hubble-ui. Phase 4 will add per-app modules as workloads
#     are re-deployed.
#
# Listener model: each (host, port, protocol) is its own listener. Cilium
# materializes a single LoadBalancer Service named
# `cilium-gateway-shared-gateway` fronting all listeners. The NLB then
# routes by SNI to the right listener.
# =============================================================================

resource "kubernetes_namespace" "gateway_system" {
  metadata {
    name = "gateway-system"
    labels = {
      "kubernetes.io/metadata.name" = "gateway-system"
    }
  }
}

# Driver map — keep small for Phase 3. Each app entry produces:
#   - one Gateway listener (HTTPS, port 443, SNI-matched on hostname)
#   - one entry in the Gateway's allowedRoutes namespace allowlist
# Adding an app: append a block here AND ensure a Cert + HTTPRoute are
# wired in the app's own .tf.
locals {
  gateway_apps = {
    grafana = {
      namespace        = "monitoring"
      hostnames        = ["grafana.${var.domain}"]
      cert_secret_name = "grafana-tls"
    }
    hubble = {
      namespace        = "kube-system"
      hostnames        = ["hubble.${var.domain}"]
      cert_secret_name = "hubble-ui-tls"
    }
    argocd = {
      namespace        = "argocd"
      hostnames        = ["argocd.${var.domain}"]
      cert_secret_name = "argocd-tls"
    }
    keycloak = {
      namespace        = "keycloak"
      hostnames        = ["keycloak.${var.domain}"]
      cert_secret_name = "keycloak-tls"
    }
    langfuse = {
      namespace        = "langfuse"
      hostnames        = ["langfuse.${var.domain}"]
      cert_secret_name = "langfuse-tls"
    }
    rollouts = {
      namespace        = "argo-rollouts"
      hostnames        = ["rollouts.${var.domain}"]
      cert_secret_name = "rollouts-tls"
    }
  }

  gateway_listener_specs = flatten([
    for app_key, app in local.gateway_apps : [
      for h in app.hostnames : {
        app_key   = app_key
        hostname  = h
        name      = "${split(".", h)[0]}-https"
        namespace = app.namespace
        cert      = app.cert_secret_name
      }
    ]
  ])

  gateway_allowed_namespaces = distinct([
    for app_key, app in local.gateway_apps : app.namespace
  ])
}

# =============================================================================
# Shared Gateway: one NLB, N listeners. Cilium creates the LB Service.
#
# Annotations: AWS Load Balancer Controller reads them off the LB Service
# Cilium auto-creates. The aws-load-balancer-* annotations get passed
# through unchanged from the Gateway resource via Cilium's gatewayAPI
# implementation.
# =============================================================================

resource "kubectl_manifest" "shared_gateway" {
  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = "shared-gateway"
      namespace = kubernetes_namespace.gateway_system.metadata[0].name
    }
    spec = {
      gatewayClassName = "cilium"
      # Gateway API v1.2 spec.infrastructure: annotations Cilium will
      # propagate to the LoadBalancer Service it creates. We use these
      # to tell AWS Load Balancer Controller (load-balancer-class) to
      # provision an NLB instead of letting the in-tree service-controller
      # (which has the "Multiple tagged security groups found" bug on
      # Karpenter-managed nodes) handle it.
      infrastructure = {
        annotations = {
          "service.beta.kubernetes.io/aws-load-balancer-type"   = "external"
          "service.beta.kubernetes.io/aws-load-balancer-scheme" = "internet-facing"
          # target-type=instance (NOT ip): Cilium's gateway controller
          # creates a Service with a sentinel endpoint 192.192.192.192:9999
          # (its convention for "I own this Service; route through
          # cilium-envoy"). AWS LBC with target-type=ip would try to
          # register 192.192.192.192 as a real target and fail silently.
          # With target-type=instance, AWS LBC registers EC2 nodes at the
          # NodePort (31899), and Cilium's eBPF NodePort handler intercepts
          # the inbound traffic on the node and routes through cilium-envoy
          # locally → matching HTTPRoute → backend pod IP.
          "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "instance"
          # Lab VPC has 1 public subnet (us-west-2a). Explicit allowlist
          # because the subnets aren't ELB-tagged.
          "service.beta.kubernetes.io/aws-load-balancer-subnets"                           = join(",", data.aws_subnets.public.ids)
          "service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled" = "true"
        }
      }
      listeners = [
        for spec in local.gateway_listener_specs : {
          name     = spec.name
          hostname = spec.hostname
          port     = 443
          protocol = "HTTPS"
          tls = {
            mode = "Terminate"
            certificateRefs = [{
              kind      = "Secret"
              name      = spec.cert
              namespace = spec.namespace
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
# ReferenceGrants — allow the Gateway in gateway-system to reference TLS
# Secrets in the apps' own namespaces. Without these, Gateway listener
# resolution fails with "Secret reference not authorized".
#
# One ReferenceGrant per target namespace (namespace-scoped resource).
# =============================================================================

resource "kubectl_manifest" "gateway_cert_reference_grants" {
  for_each = toset(local.gateway_allowed_namespaces)

  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1beta1"
    kind       = "ReferenceGrant"
    metadata = {
      name      = "gateway-tls-from-gateway-system"
      namespace = each.value
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
      }]
    }
  })

  depends_on = [
    kubectl_manifest.gateway_api_crds,
  ]
}
