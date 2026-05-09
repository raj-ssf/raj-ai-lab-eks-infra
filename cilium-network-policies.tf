# =============================================================================
# Phase 5e: CiliumNetworkPolicy — Cilium-native L3/L4 (and optional L7)
# replacements for the standard K8s NetworkPolicies stripped in Phase 3.
#
# Why CNP not standard NP:
#   - Standard K8s NetworkPolicy with `ipBlock` for the link-local
#     169.254.170.23 (Pod Identity agent) didn't behave reliably
#     under Cilium's kpr=false mode in Phase 3 — DNAT-resolved
#     ServiceIPs vs ipBlock semantics didn't cooperate. Stripped
#     them to unblock Phase 3.
#   - CiliumNetworkPolicy uses identity-aware selectors (`toEntities:
#     [kube-apiserver, host, world]`) plus label-aware
#     `toEndpoints`, so the DNAT issue doesn't apply (Cilium
#     enforces on identity, not post-DNAT IP).
#   - Denied flows show up in Hubble with the EXACT policy that
#     denied them: `hubble observe --verdict DENIED` returns the CNP
#     name + reason, vs standard NP which just silently drops.
#   - L7 awareness available later (HTTP method/path filtering)
#     without needing a separate Envoy/sidecar.
#
# Failure mode if a rule is too tight: pod can't reach a destination,
# Hubble shows DENIED with policy=<this CNP name>. Easy to debug
# vs the original "egress is just dropped, no signal anywhere".
#
# Pattern shared across cert-manager + external-dns + future controllers:
#   - DNS to kube-dns (TCP+UDP 53)
#   - Pod Identity agent at 169.254.170.23:80 (toEntities: host —
#     PIA listens on host loopback alias)
#   - HTTPS egress to K8s API + AWS APIs (toEntities:
#     [kube-apiserver, world])
# =============================================================================

# --- external-dns -------------------------------------------------------------
# Egress destinations: kube-dns (resolve Route53 endpoints), PIA (AWS
# creds), 0.0.0.0/0:443 (Route53 + STS + EKS API).
# Ingress: none (controller, not a service).

resource "kubectl_manifest" "external_dns_cnp" {
  yaml_body = yamlencode({
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "external-dns"
      namespace = "external-dns"
    }
    spec = {
      endpointSelector = {
        matchLabels = {
          "app.kubernetes.io/name" = "external-dns"
        }
      }
      egress = [
        # DNS to coredns
        {
          toEndpoints = [{
            matchLabels = {
              "k8s:io.kubernetes.pod.namespace" = "kube-system"
              "k8s:k8s-app"                     = "kube-dns"
            }
          }]
          toPorts = [{
            ports = [
              { port = "53", protocol = "UDP" },
              { port = "53", protocol = "TCP" },
            ]
          }]
        },
        # Pod Identity agent — 169.254.170.23:80 reachable via the node host.
        # `host` entity = node's own kernel networking stack (handles
        # link-local routing transparently under Cilium kpr=true).
        {
          toEntities = ["host"]
          toPorts = [{
            ports = [{ port = "80", protocol = "TCP" }]
          }]
        },
        # K8s API server (the InClusterConfig path).
        {
          toEntities = ["kube-apiserver"]
          toPorts = [{
            ports = [{ port = "443", protocol = "TCP" }]
          }]
        },
        # External AWS APIs: Route53, STS. `world` = anything not
        # cluster-scoped + not host-scoped. With AWS APIs at
        # *.amazonaws.com, can't enumerate IPs reliably — `world`
        # is the right scope.
        {
          toEntities = ["world"]
          toPorts = [{
            ports = [{ port = "443", protocol = "TCP" }]
          }]
        },
      ]
    }
  })

  depends_on = [
    helm_release.cilium,
    helm_release.external_dns,
  ]
}

# --- cert-manager controller --------------------------------------------------
# Same egress shape as external-dns:
#   - DNS to kube-dns
#   - PIA for AWS creds
#   - K8s API + AWS APIs (Route53 for DNS-01 challenges) + ACME (Let's
#     Encrypt) over 443.
# Ingress: webhook traffic from K8s API server (cert-manager-webhook)
# is a SEPARATE policy below.

resource "kubectl_manifest" "cert_manager_controller_cnp" {
  yaml_body = yamlencode({
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "cert-manager-controller"
      namespace = "cert-manager"
    }
    spec = {
      endpointSelector = {
        matchLabels = {
          "app.kubernetes.io/name"      = "cert-manager"
          "app.kubernetes.io/component" = "controller"
        }
      }
      egress = [
        {
          toEndpoints = [{
            matchLabels = {
              "k8s:io.kubernetes.pod.namespace" = "kube-system"
              "k8s:k8s-app"                     = "kube-dns"
            }
          }]
          toPorts = [{
            ports = [
              { port = "53", protocol = "UDP" },
              { port = "53", protocol = "TCP" },
            ]
          }]
        },
        {
          toEntities = ["host"]
          toPorts = [{
            ports = [{ port = "80", protocol = "TCP" }]
          }]
        },
        {
          toEntities = ["kube-apiserver", "world"]
          toPorts = [{
            ports = [{ port = "443", protocol = "TCP" }]
          }]
        },
      ]
    }
  })

  depends_on = [
    helm_release.cilium,
    helm_release.cert_manager,
  ]
}

# --- cert-manager webhook -----------------------------------------------------
# Different shape from controller — webhook accepts inbound from K8s API
# server (admission/conversion webhook) and only egresses to its own
# DNS for fully-qualified-name resolution on backed Issuer references.

resource "kubectl_manifest" "cert_manager_webhook_cnp" {
  yaml_body = yamlencode({
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "cert-manager-webhook"
      namespace = "cert-manager"
    }
    spec = {
      endpointSelector = {
        matchLabels = {
          "app.kubernetes.io/name"      = "webhook"
          "app.kubernetes.io/instance"  = "cert-manager"
        }
      }
      ingress = [
        # K8s API server calls webhook on port 10250 (admission +
        # conversion). `kube-apiserver` entity covers this — Cilium
        # auto-allocates an identity for the apiserver pods.
        {
          fromEntities = ["kube-apiserver"]
          toPorts = [{
            ports = [{ port = "10250", protocol = "TCP" }]
          }]
        },
      ]
      egress = [
        {
          toEndpoints = [{
            matchLabels = {
              "k8s:io.kubernetes.pod.namespace" = "kube-system"
              "k8s:k8s-app"                     = "kube-dns"
            }
          }]
          toPorts = [{
            ports = [
              { port = "53", protocol = "UDP" },
              { port = "53", protocol = "TCP" },
            ]
          }]
        },
        {
          toEntities = ["kube-apiserver"]
          toPorts = [{
            ports = [{ port = "443", protocol = "TCP" }]
          }]
        },
      ]
    }
  })

  depends_on = [
    helm_release.cilium,
    helm_release.cert_manager,
  ]
}

# =============================================================================
# Phase 5f: L7-aware CNP — HTTP-method enforcement on argo-rollouts-dashboard.
#
# argo-rollouts-dashboard has NO native auth (Phase 4d documented this gap).
# Adding L7 GET-only enforcement at the network layer = defense in depth:
# even if an attacker reaches the dashboard, they can only READ, not
# mutate. (The dashboard is read-only by design too, but pinning at L7
# means a future bug in the dashboard that adds a write endpoint
# wouldn't accidentally expose mutation.)
#
# How L7 enforcement works in Cilium 1.16:
#   - CiliumNetworkPolicy with `toPorts.rules.http` clauses tells Cilium
#     to redirect matching traffic through cilium-envoy (the L7 proxy
#     DaemonSet, already running on every EC2 worker since Phase 1a).
#   - Envoy parses the HTTP request, matches against the rules
#     (method, path, host header), and ACCEPTS or DENIES with a
#     synthetic 403.
#   - Hubble flows show the L7 verdict + the actual HTTP method/path
#     that triggered it: `hubble observe --type l7`.
#
# Performance cost: ~50-200μs per request for L7 redirect (Envoy
# parses + emits flow event). For low-traffic dashboards, negligible.
# For high-volume API services, only enforce L7 on egress paths that
# need it — not blanket "all HTTP" enforcement.
# =============================================================================

# --- monitoring namespace -----------------------------------------------------
# Prometheus has the broadest egress shape in the cluster — scrapes every
# meshed AND unmeshed namespace plus per-node endpoints (kubelet:10250,
# node-exporter:9100, metric endpoints across cert-manager, kyverno,
# vault, etc.). Tightening egress to "only meshed namespaces" would
# silently break observability of system pods.
#
# Egress is permissive on common scrape ports + standard cluster paths.
# Ingress: kube-apiserver (for Prometheus's K8s SD watches), other
# monitoring pods, Cilium gateway pods (for grafana / hubble HTTPRoute
# traffic).

resource "kubectl_manifest" "monitoring_cnp" {
  yaml_body = yamlencode({
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "monitoring-stack"
      namespace = "monitoring"
    }
    spec = {
      # Empty selector = all pods in monitoring ns. Same logical
      # workload boundary (prometheus + alertmanager + grafana +
      # tempo + kube-state-metrics + prometheus-operator + adapter
      # all share lifecycle + chart).
      endpointSelector = {}
      ingress = [
        # Allow gateway-system (Cilium gateway) → grafana for the
        # external HTTPRoute traffic
        {
          fromEndpoints = [{
            matchLabels = {
              "k8s:io.kubernetes.pod.namespace" = "kube-system"
              "k8s:k8s-app"                     = "cilium-envoy"
            }
          }]
        },
        # Allow kube-apiserver → metrics endpoints (for SD watches +
        # webhook calls if any)
        {
          fromEntities = ["kube-apiserver"]
        },
        # Allow intra-monitoring traffic (prometheus → alertmanager,
        # operator → CR-managed StatefulSets, etc.)
        {
          fromEndpoints = [{
            matchLabels = {
              "k8s:io.kubernetes.pod.namespace" = "monitoring"
            }
          }]
        },
      ]
      egress = [
        # DNS
        {
          toEndpoints = [{
            matchLabels = {
              "k8s:io.kubernetes.pod.namespace" = "kube-system"
              "k8s:k8s-app"                     = "kube-dns"
            }
          }]
          toPorts = [{
            ports = [
              { port = "53", protocol = "UDP" },
              { port = "53", protocol = "TCP" },
            ]
          }]
        },
        # K8s API + AWS APIs
        {
          toEntities = ["kube-apiserver", "world"]
          toPorts = [{
            ports = [{ port = "443", protocol = "TCP" }]
          }]
        },
        # Common scrape ports across all namespaces. Prometheus
        # legitimately needs to reach pods in any namespace at
        # these ports.
        {
          toEndpoints = [{ matchLabels = {} }] # any pod
          toPorts = [{
            ports = [
              { port = "8080", protocol = "TCP" },  # kube-state-metrics
              { port = "8443", protocol = "TCP" },  # cert-manager metrics, etc.
              { port = "9090", protocol = "TCP" },  # Prometheus self
              { port = "9091", protocol = "TCP" },  # Pushgateway-style
              { port = "9100", protocol = "TCP" },  # node-exporter
              { port = "9153", protocol = "TCP" },  # kube-dns metrics
              { port = "9402", protocol = "TCP" },  # cert-manager
              { port = "8000", protocol = "TCP" },  # generic /metrics
              { port = "8001", protocol = "TCP" },  # generic
              { port = "8081", protocol = "TCP" },  # alt /metrics
              { port = "9402", protocol = "TCP" },  # alt
              { port = "10250", protocol = "TCP" }, # kubelet
              { port = "15020", protocol = "TCP" }, # istio-merged metrics (no longer relevant)
            ]
          }]
        },
      ]
    }
  })

  depends_on = [
    helm_release.cilium,
    helm_release.kube_prometheus_stack,
  ]
}

resource "kubectl_manifest" "rollouts_dashboard_l7_cnp" {
  yaml_body = yamlencode({
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "rollouts-dashboard-readonly"
      namespace = "argo-rollouts"
    }
    spec = {
      endpointSelector = {
        matchLabels = {
          "app.kubernetes.io/name" = "argo-rollouts-dashboard"
        }
      }
      ingress = [{
        # Allow only Cilium's gateway pods (in kube-system, where the
        # cilium-envoy DaemonSet runs as the Gateway data plane) to
        # reach the dashboard.
        fromEndpoints = [{
          matchLabels = {
            "k8s:io.kubernetes.pod.namespace" = "kube-system"
            "k8s:k8s-app"                     = "cilium-envoy"
          }
        }]
        toPorts = [{
          ports = [{
            port     = "3100"
            protocol = "TCP"
          }]
          # L7 HTTP rule — only GET allowed. Anything else gets a 403
          # at Envoy. The dashboard's own JS bundle reads from /api/...
          # via GET, so the UI keeps working.
          rules = {
            http = [{
              method = "GET"
            }]
          }
        }]
      }]
    }
  })

  depends_on = [
    helm_release.cilium,
    helm_release.argo_rollouts,
  ]
}

# =============================================================================
# Verification commands:
#
#   # See denied flows:
#   kubectl exec -n kube-system $(kubectl get pod -n kube-system \
#     -l k8s-app=cilium -o name | head -1) -c cilium-agent -- \
#     hubble observe --verdict DROPPED --pod cert-manager/cert-manager
#
#   # See allowed flows for a specific pod:
#   ... -- hubble observe --pod external-dns/external-dns
#
#   # Validate which policies match a pod's identity:
#   ... -- cilium endpoint list | grep cert-manager
#   ... -- cilium endpoint get <id> | jq '.[].status.policy'
# =============================================================================
