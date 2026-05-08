# Phase 0 — Pre-Migration Inventory

**Generated:** 2026-05-07
**Source cluster:** `raj-ai-lab-eks` (account 050693401425, us-west-2)
**Target architecture:** EKS + Cilium native CNI + Fargate-bootstrapped Karpenter + Cilium Service Mesh + Hubble + Tetragon
**DNS zone:** `ekstest.com` (preserved across migration)

## External hostnames (11 total — all on `ekstest.com`)

| Host | Source | Cert source |
|---|---|---|
| `argocd.ekstest.com` | argocd/argocd-server HTTPRoute | argocd/argocd-server-tls |
| `chat.ekstest.com` | chat/chat-ui HTTPRoute | chat/chat-ui-tls |
| `grafana.ekstest.com` | monitoring/grafana HTTPRoute | monitoring/grafana-tls |
| `hello.ekstest.com` + `hello2.ekstest.com` | default/hello HTTPRoute | default/hello-tls-prod |
| `keycloak.ekstest.com` | keycloak/keycloak HTTPRoute | keycloak/keycloak-tls |
| `langfuse.ekstest.com` | langfuse/langfuse HTTPRoute | langfuse/langfuse-tls |
| `langgraph.ekstest.com` | langgraph/langgraph-service HTTPRoute | langgraph/langgraph-service-tls |
| `llm.ekstest.com` | llm/vllm HTTPRoute | llm/vllm-tls |
| `rag.ekstest.com` | rag/rag-service HTTPRoute | rag/rag-tls |
| `rollouts.ekstest.com` | argo-rollouts/rollouts-dashboard HTTPRoute | argo-rollouts/rollouts-tls |
| `vault.ekstest.com` | vault/vault HTTPRoute | vault/vault-tls |

**Cert posture:** No wildcard cert. Each app has a per-name cert. New cluster will need 11 new certs issued for `*-v2.ekstest.com` during migration window. Cert-manager + Let's Encrypt HTTP-01 challenge handles this automatically once Cilium Gateway routes are in place.

**External-DNS owner ID:** `raj-ai-lab-eks` (set in `txtOwnerId`). New cluster MUST use a different ID (`raj-ai-lab-eks-cilium`) to prevent record-ownership fights.

## Istio injection footprint

11 namespaces have `istio-injection=enabled`:

```
argo-rollouts, argocd, chat, ingestion, keycloak, langgraph, llm,
monitoring, presidio, qdrant, rag
```

Every workload in these namespaces currently runs an Istio sidecar. **In the new cluster these labels are removed**; the workloads run sidecarless and Cilium SM provides mTLS at L3/L4 via WireGuard/IPsec.

Existing Istio resources to translate:
- 4 VirtualServices (chat-ui-canary-vs, ingestion-service-canary-vs, langgraph-service-canary-vs, rag-service-canary-vs) — these are mesh-internal canary policies; Argo Rollouts probably drives them
- All HTTPRoutes already use Gateway API (Cilium implements Gateway API natively — drop-in compatible)

## Stateful PVCs (~1.2 TB total)

| PVC | Size | Migration approach |
|---|---|---|
| `vllm-cache-llama-405b` (S3 Mountpoint) | 250 GiB | Re-mount on new cluster — already S3-backed, zero data movement |
| `vllm-cache-llama-405b-gp3` + AZ replicas (`-usw2a`, `-usw2b`) | 750 GiB | Velero EBS snapshot → restore (or accept re-download from HF) |
| `vllm-cache-deepseek-r1-70b` | 60 GiB | Velero snapshot → restore |
| `vllm-cache-llama-8b` / `llama-guard-3-8b` | 60 GiB | Velero snapshot → restore |
| `vllm-cache-bge-m3` / `llama-1b-distilled` / `llama-3.2-1b-draft` | 30 GiB | Velero snapshot → restore (or skip — small re-download) |
| `keycloak-postgres data` | 10 GiB | **CRITICAL** — pg_dump → restore (user/realm config) |
| `langfuse-postgresql / clickhouse / zookeeper / redis / s3` | 50 GiB | Velero snapshot OR pg_dump (LangFuse trace history — keep) |
| `langgraph-redis-ha` (3 nodes) | 3 GiB | Skip — let it rebuild from cache miss |

**Velero is already installed** (`velero` namespace, helm release version 8.5.0) — use existing Velero with new BackupStorageLocation pointing to a shared S3 bucket. Both clusters can access the same bucket.

## Helm releases on the cluster (24 total)

These need to redeploy on the new cluster (most via ArgoCD app-of-apps):

```
argo-rollouts (2.37.7)            karpenter (1.5.0)
argocd (7.7.7)                    keda (2.16.1)
aws-load-balancer-controller      keycloak + keycloak-postgres
cert-manager (v1.16.2)            kube-prometheus-stack (65.5.0)
dcgm-exporter (4.8.1)             kyverno (3.3.5)
external-dns (1.15.0)             langfuse (1.0.0)
istio-base / istio-cni / istiod  ──────► REMOVE (replaced by Cilium SM)
nvidia-device-plugin              langgraph-redis-ha
oauth2-proxy (7.7.4)              prometheus-adapter (4.13.0)
tempo (1.24.4)                    vault + vault-secrets-operator
velero (8.5.0)
```

**New helm releases on the new cluster:**

```
cilium (CNI + Gateway API + Service Mesh + Hubble + Tetragon)
trivy-operator
```

## Constraints flagged for the IaC plan

1. **No wildcard cert today.** Plan IaC adds an optional `*.ekstest.com` Certificate resource for the new cluster to simplify future hostname additions.
2. **`enable_irsa = false` on existing EKS module** — the cluster uses Pod Identity associations exclusively. New cluster must replicate this pattern (already an IaC-level decision; just preserve).
3. **`node_security_group_additional_rules` opens all node-to-node ports** — required for Cilium control plane traffic and pod-to-pod on low ports. Preserve in new cluster.
4. **GPU node pool** — `gpu-experiments` Karpenter NodePool exists; preserve config for vLLM workloads. Karpenter NodePool spec migrates 1:1.
5. **Velero S3 backup bucket** — needs cross-cluster access. Confirm bucket policy allows both clusters' Velero IAM roles.

## OAuth2-proxy + Keycloak redirect URIs

Keycloak realm clients have specific redirect URI patterns (e.g., `https://argocd.ekstest.com/auth/callback`). During migration:

- Either add `https://*-v2.ekstest.com/auth/callback` patterns to each client temporarily, OR
- Skip OAuth flow on the new cluster during validation (port-forward + basic auth)

**TODO (manual):** enumerate keycloak realm clients and their redirect URIs before Phase 4. See `kubectl exec -n keycloak keycloak-0 -- /opt/keycloak/bin/kcadm.sh get clients -r master` (or whichever realm).
