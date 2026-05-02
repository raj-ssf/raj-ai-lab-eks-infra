resource "kubernetes_namespace" "vault" {
  metadata {
    name = "vault"
  }
}

resource "helm_release" "vault" {
  name       = "vault"
  namespace  = kubernetes_namespace.vault.metadata[0].name
  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault"
  version    = "0.29.1"

  values = [
    yamlencode({
      # --- Server (3-node HA cluster, raft integrated storage, KMS auto-unseal) -
      server = {
        # Explicit ServiceAccount name so aws_eks_pod_identity_association.vault
        # binds to the right identity. Chart creates the SA.
        serviceAccount = {
          create = true
          name   = "vault"
        }

        # HA with raft integrated storage. 3 replicas gives us the standard
        # quorum (tolerates 1 failure). retry_join lets vault-1/2 auto-join
        # once vault-0 has initialized raft. KMS auto-unseal means all three
        # come back online after restart without manual intervention.
        ha = {
          enabled  = true
          replicas = 3
          raft = {
            enabled   = true
            setNodeId = true
            config    = <<-EOT
              ui = true

              listener "tcp" {
                address         = "0.0.0.0:8200"
                cluster_address = "0.0.0.0:8201"
                tls_disable     = true
              }

              storage "raft" {
                path    = "/vault/data"

                retry_join {
                  leader_api_addr = "http://vault-0.vault-internal:8200"
                }
                retry_join {
                  leader_api_addr = "http://vault-1.vault-internal:8200"
                }
                retry_join {
                  leader_api_addr = "http://vault-2.vault-internal:8200"
                }
              }

              seal "awskms" {
                region     = "${var.region}"
                kms_key_id = "${aws_kms_key.vault_unseal.key_id}"
              }

              service_registration "kubernetes" {}
            EOT
          }
        }

        # Spread the 3 replicas across different nodes. Chart default is a
        # preferred-only podAntiAffinity; upgrade to "required" here so we
        # get real blast-radius reduction (a single node loss takes down
        # at most 1 of 3 = still quorum).
        affinity = <<-EOT
          podAntiAffinity:
            requiredDuringSchedulingIgnoredDuringExecution:
              - labelSelector:
                  matchLabels:
                    app.kubernetes.io/name: vault
                    app.kubernetes.io/instance: vault
                    component: server
                topologyKey: kubernetes.io/hostname
        EOT

        dataStorage = {
          enabled      = true
          size         = "10Gi"
          storageClass = "gp3"
          accessMode   = "ReadWriteOnce"
        }

        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }

        # Phase 12 of Gateway API migration: chart's Ingress disabled.
        # Traffic now flows through shared-gateway in gateway-system ns.
        ingress = {
          enabled = false
        }

        # Readiness needs Vault unsealed; during first boot (before init) the
        # pod is "running but not ready". Give it a longer grace so KMS auto
        # -unseal has time to complete.
        readinessProbe = {
          enabled             = true
          path                = "/v1/sys/health?standbyok=true&sealedcode=204&uninitcode=204"
          initialDelaySeconds = 10
          periodSeconds       = 5
          failureThreshold    = 10
        }
      }

      # --- Agent Injector (mutating webhook + controller) ------------------
      # Pods annotated with vault.hashicorp.com/agent-inject=true get init +
      # sidecar containers that fetch secrets via the pod's SA token.
      #
      # Phase #62: 1 → 2 replicas. The injector serves a Mutating-
      # WebhookConfiguration that runs on EVERY pod CREATE in any
      # namespace where vault-injection is annotated. Lab workloads
      # using the injector today: grafana (admin password +
      # OIDC client secret), langgraph-service, rag-service,
      # ingestion-service, chat-ui (KV reads on first start). A
      # single-pod injector means any restart pauses pod creation
      # cluster-wide for ~30s while the new pod becomes Ready —
      # specifically, the webhook's failurePolicy=Ignore would let
      # pods through, but the chart sets failurePolicy=Fail so
      # mid-restart pod creates get rejected with TLS handshake
      # errors until recovery.
      #
      # 2 replicas behind the existing vault-agent-injector-svc
      # Service give the webhook proper pod-failure HA. Anti-
      # affinity (heredoc string per chart convention) prefers
      # different nodes; 3 static nodes available so spread is
      # satisfiable. Used "preferred" not "required" — same
      # Phase #59/#60 lesson.
      injector = {
        enabled  = true
        replicas = 2

        # Chart uses YAML-string convention for affinity (same as
        # server.affinity above). Preferred anti-affinity on hostname
        # so the 2 injector pods spread across nodes when possible
        # but colocate if the cluster is constrained.
        affinity = <<-EOT
          podAntiAffinity:
            preferredDuringSchedulingIgnoredDuringExecution:
              - weight: 100
                podAffinityTerm:
                  labelSelector:
                    matchLabels:
                      app.kubernetes.io/name: vault-agent-injector
                      app.kubernetes.io/instance: vault
                      component: webhook
                  topologyKey: kubernetes.io/hostname
        EOT

        resources = {
          requests = { cpu = "50m", memory = "64Mi" }
          limits   = { cpu = "100m", memory = "128Mi" }
        }
      }

      ui = {
        enabled     = true
        serviceType = "ClusterIP"
      }
    })
  ]

  depends_on = [
    module.eks,
    helm_release.alb_controller,
    helm_release.cert_manager,
    aws_eks_pod_identity_association.vault,
    kubernetes_storage_class_v1.gp3,
  ]
}

output "vault_url_hint" {
  value       = "https://vault.${var.domain} (init: kubectl -n vault exec -it vault-0 -- vault operator init -recovery-shares=5 -recovery-threshold=3)"
  description = "Vault external URL + bootstrap command"
}

# =============================================================================
# Phase 8 of Gateway API migration: HTTPRoute for vault.ekstest.com.
# Sibling to the helm_release; see langfuse.tf for the pattern's rationale.
#
# Routes to vault-active (the active leader of the Raft HA cluster). On
# leader-election change, vault-active's selector flips to the new leader
# automatically — no HTTPRoute reconfig needed. The plain port (8200) is
# the public-facing one; raft port 8201 has its own internal TLS and isn't
# exposed externally.
# =============================================================================

# =============================================================================
# Phase #70e: NetworkPolicies for vault stack.
#
# Vault is the highest-stakes component covered by this NetworkPolicy
# rollout so far. Two policies needed because the vault namespace has
# two distinct workload shapes:
#
#   1. vault server (StatefulSet, 3 pods) — raft peer-mesh on port
#      8201, HTTP API on 8200 reachable from every Vault-using pod
#      across ~10 namespaces.
#   2. vault-agent-injector (Deployment, 2 pods after Phase #62) —
#      MutatingWebhookConfiguration ingress on 8080 from kube-apiserver.
#
# Why this matters: vault is NOT meshed (per istio.tf — raft port
# 8201 uses its own TLS, double-encryption with Istio mTLS would
# break). So Istio AuthZ in istio-zero-trust.tf does NOT apply to
# vault pods. NetworkPolicy is the ONLY L3/L4 control.
#
# Pre-flight pod labels confirmed:
#   server pods    app.kubernetes.io/name=vault
#                  component=server
#   injector pods  app.kubernetes.io/name=vault-agent-injector
#                  component=webhook
#
# Pre-flight ports confirmed:
#   server     8200 (http API), 8201 (https-internal raft),
#              8202 (http-rep — replication, OSS-pod-template
#              vestige)
#   injector   listens 8080, Service maps 443→8080
# =============================================================================

resource "kubectl_manifest" "vault_server_netpol" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "vault-server"
      namespace = kubernetes_namespace.vault.metadata[0].name
    }
    spec = {
      podSelector = {
        matchLabels = {
          "app.kubernetes.io/name" = "vault"
          "component"              = "server"
        }
      }
      policyTypes = ["Ingress", "Egress"]

      # --- Ingress -------------------------------------------------
      ingress = [
        # 8200 (HTTP API) — reachable from every Vault-using pod
        # across ~10 namespaces (rag, langgraph, ingestion, chat,
        # langfuse, monitoring/grafana, qdrant, keycloak, argocd,
        # chat). Enumerating namespaceSelectors would be brittle
        # — every new app that uses Vault Agent Injector would
        # require an edit here. Allow from anywhere on 8200; Vault
        # itself authenticates every API call via K8s SA token
        # (the kubernetes auth backend). L3 broadness, L7 auth.
        {
          ports = [{ protocol = "TCP", port = 8200 }]
        },
        # 8201 (raft peer-mesh) — ONLY from other vault server
        # pods in the same namespace. This is a tight rule:
        # podSelector matches only the 3 vault-N pods. Kubelet
        # probes don't go to 8201 (probes hit 8200). External
        # traffic to 8201 is a misconfiguration to be denied.
        {
          from = [{
            podSelector = {
              matchLabels = {
                "app.kubernetes.io/name" = "vault"
                "component"              = "server"
              }
            }
          }]
          ports = [
            { protocol = "TCP", port = 8201 },
            { protocol = "TCP", port = 8202 }, # http-rep — OSS vestige but allow
          ]
        },
      ]

      # --- Egress --------------------------------------------------
      egress = [
        # DNS via CoreDNS
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
        # 8201 to other vault server pods — raft outbound. Same
        # podSelector as ingress 8201 above (each vault-N talks to
        # all others).
        {
          to = [{
            podSelector = {
              matchLabels = {
                "app.kubernetes.io/name" = "vault"
                "component"              = "server"
              }
            }
          }]
          ports = [
            { protocol = "TCP", port = 8201 },
            { protocol = "TCP", port = 8202 },
          ]
        },
        # Pod Identity Agent — Vault uses Pod Identity for AWS KMS
        # access (auto-unseal). vault.tf wires the iam role +
        # eks_pod_identity_association.
        {
          to = [{
            ipBlock = {
              cidr = "169.254.170.23/32"
            }
          }]
          ports = [{
            protocol = "TCP"
            port     = 80
          }]
        },
        # 443 outbound — K8s API server + AWS KMS for auto-unseal
        # (kms.us-west-2.amazonaws.com).
        {
          to = [{
            ipBlock = {
              cidr = "0.0.0.0/0"
              except = [
                "169.254.169.254/32", # IMDS — defense in depth
              ]
            }
          }]
          ports = [{ protocol = "TCP", port = 443 }]
        },
      ]
    }
  })

  depends_on = [
    helm_release.vault,
  ]
}

resource "kubectl_manifest" "vault_injector_netpol" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "vault-agent-injector"
      namespace = kubernetes_namespace.vault.metadata[0].name
    }
    spec = {
      podSelector = {
        matchLabels = {
          "app.kubernetes.io/name" = "vault-agent-injector"
          "component"              = "webhook"
        }
      }
      policyTypes = ["Ingress", "Egress"]

      # --- Ingress -------------------------------------------------
      # 8080 — MutatingWebhookConfiguration calls from kube-apiserver.
      # Same situation as cert-manager-webhook (Phase #70c): API
      # server is OUTSIDE the pod network, can't be matched via
      # namespaceSelector. Allow from anywhere; the webhook does
      # mTLS auth at L7. Failure mode: failurePolicy=Fail in the
      # chart, so any wrong rule blocks every pod CREATE annotated
      # with vault.hashicorp.com/agent-inject=true.
      ingress = [{
        ports = [{ protocol = "TCP", port = 8080 }]
      }]

      # --- Egress --------------------------------------------------
      # Tiny — DNS + K8s API only. Injector doesn't talk to vault
      # itself; it ONLY mutates pod specs to add agent sidecars.
      # The agent sidecars (running in the target pods) talk to
      # vault, but those are different pods.
      egress = [
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
        {
          to = [{
            ipBlock = {
              cidr = "0.0.0.0/0"
              except = [
                "169.254.169.254/32", # IMDS — defense in depth
              ]
            }
          }]
          ports = [{ protocol = "TCP", port = 443 }]
        },
      ]
    }
  })

  depends_on = [
    helm_release.vault,
  ]
}

resource "kubectl_manifest" "vault_httproute" {
  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "vault"
      namespace = "vault"
      labels    = { app = "vault" }
    }
    spec = {
      parentRefs = [{
        name        = "shared-gateway"
        namespace   = "gateway-system"
        sectionName = "vault-https"
      }]
      hostnames = ["vault.${var.domain}"]
      rules = [{
        matches = [{
          path = { type = "PathPrefix", value = "/" }
        }]
        backendRefs = [{
          # vault-active Service exposes port 8200 (named "http") for
          # the public API. The 8201 https-internal port is for Raft
          # only and isn't routed externally.
          name = "vault-active"
          port = 8200
        }]
      }]
    }
  })

  depends_on = [
    helm_release.vault,
  ]
}
