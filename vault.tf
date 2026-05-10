# =============================================================================
# Phase 4c: Vault — secrets engine with KMS auto-unseal.
#
# Differences from the original vault.tf in _disabled:
#   - No standard NetworkPolicies (Phase 5e replaced standard NPs with
#     CNPs; vault CNP can be added to cilium-network-policies.tf later).
#   - No depends_on on alb_controller (already deployed in Phase 3).
#
# 2026-05-10: HTTPRoute on vault.${var.domain} added (bottom of file)
# now that we're bringing vault-config.tf back. Listener wired in
# gateway-system.tf gateway_apps; cert in gateway-app-certs.tf.
#
# Bootstrap is a 2-step process:
#   1. terraform apply — deploys 3 vault pods, all in `Running` but
#      `Not Ready` because uninitialized (sealedcode=204 makes the
#      probe forgiving).
#   2. Manual `vault operator init` against vault-0:
#        kubectl -n vault exec -it vault-0 -- \
#          vault operator init -recovery-shares=5 -recovery-threshold=3
#      Save the recovery keys + initial root token in 1Password.
#      KMS auto-unseal handles all subsequent unseals — recovery keys
#      are break-glass only.
#
# Phase 4c-2 (next): bring up vault-config.tf for K8s auth + KV mounts +
# policies. Needs the vault terraform provider configured against a
# reachable Vault address (port-forward or post-DNS-cutover).
# =============================================================================

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
      # --- Server: 3-replica HA cluster with Raft + KMS auto-unseal ---
      server = {
        serviceAccount = {
          create = true
          name   = "vault"
        }

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
                path = "/vault/data"
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

        # Required pod-anti-affinity — single-node failure must take down
        # at most 1 of 3, preserving Raft quorum.
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

        ingress = {
          enabled = false
        }

        # Readiness probe is forgiving on the uninit/sealed states so
        # the pod can run while waiting for `vault operator init`.
        readinessProbe = {
          enabled             = true
          path                = "/v1/sys/health?standbyok=true&sealedcode=204&uninitcode=204"
          initialDelaySeconds = 10
          periodSeconds       = 5
          failureThreshold    = 10
        }
      }

      # --- Agent Injector: webhook for vault.hashicorp.com/agent-inject=true ---
      # 2 replicas for HA — the injector is on the path of every pod create
      # in vault-annotated namespaces. Single-pod outage = pod-create stalls.
      injector = {
        enabled  = true
        replicas = 2
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
    helm_release.cert_manager,
    aws_eks_pod_identity_association.vault,
    kubernetes_storage_class_v1.gp3,
  ]
}

output "vault_init_hint" {
  value = <<-EOT
    Bootstrap Vault (one-time):
      kubectl -n vault exec -it vault-0 -- \
        vault operator init -recovery-shares=5 -recovery-threshold=3
    Save the 5 recovery keys + initial root token immediately.
    KMS auto-unseal handles subsequent unseals; recovery keys are break-glass only.
  EOT
}

# =============================================================================
# HTTPRoute exposing the active leader on vault.${var.domain}.
#
# Backend is `vault-active` — the chart's leader-tracking Service whose
# selector flips to whichever pod currently holds the raft lease. On
# leader-election change, no HTTPRoute reconfig needed. We only route
# port 8200 (HTTP API); 8201 is raft-internal TLS, never external.
#
# Listener `vault-https` lives on shared-gateway in gateway-system. The
# Gateway terminates Let's Encrypt TLS using `vault-tls` Secret in this
# namespace (cert-manager Certificate in gateway-app-certs.tf). The
# cross-namespace Secret reference is authorized by the per-namespace
# ReferenceGrant in gateway-system.tf.
# =============================================================================

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
          name = "vault-active"
          port = 8200
        }]
      }]
    }
  })

  depends_on = [
    helm_release.vault,
    kubectl_manifest.shared_gateway,
  ]
}
