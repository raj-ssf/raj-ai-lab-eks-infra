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

        # Ingress → NGINX → cert-manager (LE prod).
        ingress = {
          enabled          = true
          ingressClassName = "nginx"
          hosts = [{
            host  = "vault.${var.domain}"
            paths = []
          }]
          annotations = {
            "cert-manager.io/cluster-issuer" = "letsencrypt-prod"
            # Phase 8 of Gateway API migration: opt out of ExternalDNS
            # so this Helm-managed Ingress no longer competes with the
            # vault HTTPRoute (kubectl_manifest below) for the
            # vault.ekstest.com record. cert-manager renewal continues
            # unaffected. See rag-service Ingress for full rationale.
            "external-dns.alpha.kubernetes.io/controller" = "skip-migrated"
          }
          tls = [{
            hosts      = ["vault.${var.domain}"]
            secretName = "vault-tls"
          }]
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
      injector = {
        enabled  = true
        replicas = 1

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
