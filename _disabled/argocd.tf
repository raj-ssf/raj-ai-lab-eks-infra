resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
    labels = {
      # Mesh-injection label declared HERE so the kubernetes_namespace
      # resource doesn't strip it on every TF run. Same fix applied to
      # keycloak.tf — see comment there for the full rationale.
      "istio-injection" = "enabled"
    }
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "7.7.7"

  values = [
    yamlencode({
      configs = {
        params = {
          # NGINX terminates TLS; let argocd-server speak plain HTTP inside
          # the cluster.
          "server.insecure" = true
        }

        cm = {
          # Canonical external URL. Required for OIDC: the issuer must be
          # able to redirect back to this host after login.
          url = "https://argocd.${var.domain}"

          # OIDC configuration. clientSecret is resolved from a k8s Secret
          # named argocd-oidc-vault (managed by VSO — see argocd-vso.tf).
          # ArgoCD's $<secret>:<key> syntax reads from any named Secret;
          # we use that instead of the default argocd-secret so Vault can
          # own the value without fighting the chart for that Secret.
          "oidc.config" = yamlencode({
            name            = "Keycloak"
            issuer          = "https://keycloak.${var.domain}/realms/${var.cluster_name}"
            clientID        = "argocd"
            clientSecret    = "$argocd-oidc-vault:client_secret"
            requestedScopes = ["openid", "profile", "email"]
            requestedIDTokenClaims = {
              groups = { essential = true }
            }
          })
        }

        # Map Keycloak groups to ArgoCD built-in roles. g, <group>, role:X.
        rbac = {
          "policy.default" = "role:readonly"
          "policy.csv"     = <<-EOT
            g, argocd-admins,  role:admin
            g, argocd-viewers, role:readonly
          EOT
          scopes           = "[groups]"
        }

        # OIDC client secret is delivered via VSO → argocd-oidc-vault Secret;
        # no longer merged into the chart-managed argocd-secret.
      }

      # Disable the redis-secret-init Helm pre-upgrade Job. The chart
      # creates this Job on every install/upgrade to populate the
      # argocd-redis Secret; that Secret was created on initial
      # install (2026-04-20) and persists unchanged. The Job's image
      # is tag-only (quay.io/argoproj/argocd:v2.13.1) which the lab's
      # verify-argocd-image-signatures Kyverno policy blocks at admission
      # because cosign verification requires a digest. Skipping the Job
      # avoids the Kyverno collision; the existing Secret keeps working.
      #
      # If we ever NEED to rotate the Redis password, options are:
      #   1. Re-enable temporarily, accept the Kyverno block, manually
      #      apply the Secret, then re-disable; OR
      #   2. Add a Kyverno PolicyException for this specific Job; OR
      #   3. Pin the Job image to digest format in helm values.
      redisSecretInit = {
        enabled = false
      }

      # Phase #74: argocd-redis → argocd-redis-ha.
      #
      # Replaces the single-pod argocd-redis Deployment with a 3-pod
      # Redis Sentinel StatefulSet + 3-replica HAProxy Deployment.
      # The argocd chart's `redis-ha` sub-chart wires this transparently:
      # argocd-server, argocd-repo-server, argocd-application-controller,
      # argocd-applicationset-controller all auto-detect redis-ha and
      # connect via argocd-redis-ha-haproxy Service (no manual env
      # rewiring needed in the consumer pods).
      #
      # Topology:
      #   redis-ha StatefulSet     3 pods (master + 2 replicas + sentinel
      #                            in each pod for leader election).
      #                            requiredDuringScheduling anti-affinity
      #                            on hostname (hardAntiAffinity: true)
      #                            so Sentinel quorum survives a node
      #                            failure. Cluster has 3 nodes spread
      #                            across us-west-2{a,b,c}, so the
      #                            constraint is satisfiable.
      #   haproxy Deployment       3 pods. Reads route to any healthy
      #                            replica; writes route to the current
      #                            master (Sentinel-elected). Clients
      #                            (argocd-server etc.) talk to HAProxy
      #                            on the standard 6379 port — no
      #                            client-side awareness of master/
      #                            replica or failover.
      #
      # Failover: Sentinel detects master loss within ~5s (down-after-
      # milliseconds default), elects a replica as new master,
      # HAProxy reconfigures backends. argocd-server's client
      # connection re-establishes against the new master with a brief
      # blip in cache reads.
      #
      # Cost: ~3 redis-ha pods × 100Mi memory + ~3 haproxy pods ×
      # 50Mi memory = ~450Mi cluster-wide. Negligible. Each redis-ha
      # pod uses an emptyDir (chart default) — no PVC, no EBS cost.
      # argocd-redis is a CACHE, not a system of record; in-memory
      # state is fine and the cache rebuilds from the K8s API on
      # cold start.
      #
      # Migration: helm upgrade replaces the existing argocd-redis
      # Deployment with the redis-ha StatefulSet + HAProxy. argocd-
      # redis Service flips to point at the haproxy Service. Brief
      # ~30s window where argocd's API responses are slow (cache
      # rebuilding) — acceptable.
      redis = {
        enabled = false
      }
      "redis-ha" = {
        enabled = true
        # Chart default replicas=3 — keeping. Sentinel quorum is
        # 2-of-3, so single-pod failure is tolerated. Single-AZ
        # failure (since we have 1 node per AZ) takes 1 of 3
        # pods → still quorum.
        # haproxy: 3 replicas keeps client connections HA across
        # node restarts.
        haproxy = {
          enabled  = true
          replicas = 3
          # Anti-affinity already required by chart default; making
          # the requirement explicit here for documentation.
          hardAntiAffinity = true
        }
        # Redis pod-level anti-affinity (keep chart default true) —
        # redis-ha StatefulSet pods MUST land on different nodes,
        # else losing a node takes down >1 sentinel-quorum member.
        hardAntiAffinity = true
        # Persistence: chart default is emptyDir (no PVC). Argocd's
        # redis is a cache; leaving as ephemeral. The cluster has
        # gp3 SC available if we ever flip to persistent.
      }

      server = {
        service = { type = "ClusterIP" }

        # Phase 12 of Gateway API migration: chart's Ingress disabled.
        # Traffic now flows through shared-gateway in gateway-system ns.
        ingress = {
          enabled = false
        }
      }
    })
  ]

  depends_on = [
    module.eks,
    helm_release.alb_controller,
    helm_release.cert_manager,
  ]
}

# =============================================================================
# Phase 9 of Gateway API migration: HTTPRoute for argocd.ekstest.com.
#
# argocd-server serves both REST (HTTP) + gRPC (SPDY/HTTP-2) + WebSockets
# on /api/v1/stream/... (live application status streams). All speak HTTP/1.1
# or HTTP/2 over TLS — Envoy routes them all transparently from a single
# HTTPRoute, no per-protocol config needed.
#
# The legacy Ingress had:
#   - backend-protocol: HTTP        — Envoy doesn't need (default)
#   - proxy-read/send-timeout: 1800 — Envoy default 1h covers WS streams
#   - upstream-vhost rewrite        — Envoy doesn't need (mesh-native)
# All three NGINX-isms drop away.
#
# argocd-server has TWO Service ports: http(80) + https(443), both
# targetPort 8080. The HTTPRoute uses port 80 (matches the Ingress'
# choice; Envoy speaks plain HTTP to the backend, terminates TLS at
# the listener).
# =============================================================================

resource "kubectl_manifest" "argocd_httproute" {
  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "argocd-server"
      namespace = "argocd"
      labels    = { app = "argocd-server" }
    }
    spec = {
      parentRefs = [{
        name        = "shared-gateway"
        namespace   = "gateway-system"
        sectionName = "argocd-https"
      }]
      hostnames = ["argocd.${var.domain}"]
      rules = [{
        matches = [{
          path = { type = "PathPrefix", value = "/" }
        }]
        backendRefs = [{
          name = "argocd-server"
          port = 80
        }]
      }]
    }
  })

  depends_on = [
    helm_release.argocd,
  ]
}

# =============================================================================
# Phase #70g: NetworkPolicy for argocd namespace.
#
# Same meshed-app pattern as Phase #70f (rag/langgraph/ingestion/
# chat-ui), with two additions:
#   1. Gateway-system ingress — argocd-server is exposed externally
#      via shared-gateway, identical to chat-ui's pattern in #70f.
#   2. podSelector matches the entire namespace (empty selector)
#      because argocd has 6 deployments + redis. Per-component
#      policies would yield ~7 NetworkPolicies for marginal precision
#      gain over Istio AuthZ's existing per-component allows.
#
# Why empty podSelector is acceptable here:
#   The whole argocd namespace is one logical workload — server,
#   repo-server, dex, applicationset-controller, notifications-
#   controller, redis. Treating them as a unit aligns with how
#   they're managed (single helm release) and the namespace-wide
#   intra-ns allow already in istio-zero-trust.tf.
#
# Egress reuses local.app_common_egress from
# app-network-policies.tf — DNS, istiod, all meshed namespaces,
# vault, K8s API. argocd-repo-server's git egress (github.com:443)
# is covered by the K8s-API rule's 0.0.0.0/0:443 allow.
# =============================================================================

resource "kubectl_manifest" "argocd_netpol" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "argocd"
      namespace = "argocd"
    }
    spec = {
      podSelector = {} # all pods in argocd ns
      policyTypes = ["Ingress", "Egress"]
      # Common-meshed ingress + gateway-system (north-south for
      # argocd-server). Mirrors chat-ui's pattern in #70f.
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

  depends_on = [
    helm_release.argocd,
    helm_release.istiod,
  ]
}
