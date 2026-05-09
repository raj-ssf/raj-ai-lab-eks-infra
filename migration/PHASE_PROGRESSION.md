# Cilium Migration — Phase Progression

End-to-end record of migrating an EKS-based AI lab from
**AWS VPC CNI + kube-proxy + Istio + Karpenter on managed-NG**
to **Cilium native CNI + Cilium kubeProxyReplacement + Cilium Service
Mesh + Cilium Gateway API + Karpenter on Fargate (hybrid)**.

22 commits, 17 helm releases, 3 K8s ConfigMap dashboards, 5 EKS-managed
addons, 4 CiliumNetworkPolicies, 5 Kyverno ClusterPolicies, 1 ScaledObject,
1 ACM cert, 1 RDS instance, 1 S3 bucket, 16 architectural memories.

## Phase summary

### Phase 1a — Cluster + Cilium native CNI on Karpenter+Fargate
`17ee4d3` → `bd0598d` (11 apply iterations)

- EKS cluster with 2 Fargate profiles: `karpenter` + `kube-system` (kube-dns
  selector only — Hubble UI/Relay later moved to EC2)
- Cilium 1.16.5 in `eni` IPAM mode with native routing + WireGuard
  encryption (nodeEncryption=true)
- Karpenter on Fargate (no managed NG anywhere)
- VPC CNI removed from managed addons; aws-node DaemonSet deleted manually

### Phase 2 — Foundation services
`d02f763` → `561f554` (3 commits)

- cert-manager + ClusterIssuers (Route53 DNS-01 via Pod Identity)
- external-dns (Route53, gateway-httproute source — restored in Phase 3)
- kube-prometheus-stack (Prometheus + Alertmanager + Grafana)
- prometheus-adapter (custom metrics API)
- Tempo (distributed tracing)
- Velero (backup/restore)
- gp3 default StorageClass

Stripped: Vault sidecar refs from grafana, istio-injection labels,
pre-existing standard NetworkPolicies (replaced with CNPs in Phase 5e).

### Phase 3 — Cilium Gateway API + AWS LBC + Let's Encrypt NLB
`5611ddc`

- Upstream Gateway API CRDs v1.2.1 (experimental channel — Cilium
  needs TLSRoute which is experimental-only)
- Cilium GatewayClass auto-registered after CRDs land
- shared-gateway in gateway-system ns with HTTPS listeners per app
- AWS Load Balancer Controller installed (in-tree controller fails
  with "Multiple tagged security groups found" on Karpenter nodes)
- NLB provisioned via AWS LBC, DNS-01 ACME certs issued
- `Gateway.spec.infrastructure.annotations` propagates AWS annotations
  to the auto-created LoadBalancer Service (NOT metadata.annotations)
- nodePort=true required when kubeProxyReplacement=false (bridge mode)

### Phase 4a — ArgoCD core (HA Redis Sentinel)
`ea560b2`

- ArgoCD 7.7.7 with redis-ha (3-pod Sentinel + 3 HAProxy)
- HTTPRoute via shared-gateway:argocd-https
- redisSecretInit re-enabled (Kyverno not deployed yet, so the chart's
  cleanup Job runs cleanly — original lab had it disabled because
  Kyverno blocked the tag-only image)

### Phase 4b — Keycloak IdP + ArgoCD/Grafana OIDC
`2716d58`

- Keycloak 26.3.3 with backing Postgres (gp3 PVC)
- Realm `raj-ai-lab-eks-cilium` imported with `argocd` + `grafana`
  OIDC clients (random_password-generated secrets)
- ArgoCD `oidc.config` wired to Keycloak realm; RBAC group→role mapping
- Grafana `GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET` envFrom Secret
- Realm filename strict-check (`<realm>-realm.json`)
- Bumped startup probe to 5min budget for first-boot import

### Phase 4c — Vault HA + KMS auto-unseal + VSO
`eb28917`

- 3-replica Vault Raft cluster with required pod-anti-affinity
- AWS KMS auto-unseal (dedicated key, rotation enabled)
- Vault Agent Injector (2 replicas)
- Vault Secrets Operator (defaultVaultConnection to vault.svc:8200)
- vault-config.tf deferred (needs vault provider connectivity)

### Phase 4d — Apps: Langfuse + Argo Rollouts
`5253b1d`, `7580518`

- Langfuse v3 (web + worker + Postgres + ClickHouse + Valkey + MinIO,
  all 4 stateful subcharts via bitnamilegacy/* image overrides)
- Argo Rollouts controller (HA, 2 replicas) + dashboard
- All Bitnami subcharts use `global.security.allowInsecureImages=true`
  (Aug-2025 catalog change requires this with bitnamilegacy/*)

### Phase 4d-supplement — ECR + GHA + ACM + RDS + Presidio
`af27f3f`, `0ba3589`, `9b04a96`

- ECR repo for rag-service (imported existing from old lab)
- GitHub Actions OIDC IAM role (scoped to repo:owner/name + main branch)
- ACM wildcard cert (DNS-validated via Route53)
- RDS Postgres db.t4g.micro (5432 from EKS node SG only, encrypted)
- Microsoft Presidio (analyzer + anonymizer, 2 replicas each, HPAs,
  spaCy en_core_web_lg)

### Phase 4e-prep — GPU support + S3 model-weights
`8c0a39c`, then GPU stack

- AWS Mountpoint S3 CSI driver (read-only model-weights bucket mount)
- model-weights S3 bucket (versioned, SSE-S3, public-blocked)
- NVIDIA Device Plugin (waits for nvidia.com/gpu=true nodes)
- DCGM Exporter (per-GPU metrics → Prometheus)
- vLLM image prepull DaemonSet (cold-start optimization)
- Kubeflow Training Operator v1.8.0 (PyTorchJob + 5 other CRDs)

### Phase 5 — Full Cilium kubeProxyReplacement
`e5fc02c`

- `kubeProxyReplacement: "true"` (was "false" with bridge nodePort)
- kube-proxy EKS addon removed
- kube-proxy DaemonSet manually deleted
- Confirmed: ClusterIP routing via Cilium eBPF, no iptables in data path
- Hubble flows now show real source IPs (no kube-proxy DNAT)

### Phase 5b — Tetragon (eBPF runtime security)
`1b95ce4`

- DaemonSet on every EC2 worker (Fargate excluded via top-level
  `affinity:` — chart key gotcha)
- Live process exec/exit/file/network events with full pod identity
- Stdout export available via `kubectl logs -n tetragon -c export-stdout`
- Same eBPF foundation as cilium-agent — different hooks

### Phase 5c — KEDA event-driven autoscaling
`fccd21b`, `91bf871`

- KEDA 2.16.1 (operator + metrics-server, both HA)
- ScaledObject demo on argo-rollouts-dashboard with cron trigger
  (9am-2am PT business hours, scale-to-zero off-hours)
- Solves HPA's scale-from-zero limitation (KEDA queries Prometheus
  directly; empty PromQL = legitimate `0`, not "metric unavailable")

### Phase 5d — Trivy Operator (CVE/config/RBAC scanning)
`d57ce20`

- Trivy 0.24.1 in Standalone mode
- 5 scanner types: vuln + config audit + RBAC + infra + secrets
- VulnerabilityReport CRs per scanned image (24h interval)
- ServiceMonitor wired for kube-prometheus-stack scrape

### Phase 5e — CiliumNetworkPolicy (replaces stripped K8s NPs)
`f334b8c`

- 3 L3/L4 CNPs: external-dns, cert-manager-controller, cert-manager-webhook
- Identity-aware: `toEntities: [host, kube-apiserver, world]` instead
  of ipBlock CIDRs (sidesteps the post-DNAT semantic that broke
  the original NPs)
- Hubble flows show denied verdicts with policy name

### Phase 5f — L7 CiliumNetworkPolicy (HTTP-method enforcement)
`b6c3836`

- argo-rollouts-dashboard restricted to GET-only via L7 CNP
- cilium-envoy DaemonSet handles L7 redirect (already running since
  Phase 1a)
- Defense-in-depth on a dashboard with no native auth
- Demonstrates Cilium's L7 capability without separate Istio mesh

### Phase 6 — Kyverno admission controller
`cf5da4f`

- Kyverno 3.3.5 with 3-replica admissionController (HA), 1 each for
  background/cleanup/reports
- bitnamilegacy/kubectl override for chart's cleanup hook Jobs
  (Broadcom rename trap)

### Phase 6b — Kyverno baseline policies (Audit mode)
`2533355`

- 4 ClusterPolicies in `validationFailureAction: Audit`:
  - disallow-privileged-containers (PSS Baseline)
  - require-resource-limits
  - disallow-latest-tag
  - disallow-host-path (system namespaces exempt)
- PolicyReport CRs surface violations across all running workloads

### Phase 6c — Cosign signature verification (ArgoCD)
`097551a`

- Single Enforce-mode policy: verify-argocd-image-signatures
- Keyless cosign verification against argoproj/argo-cd image-reuse.yaml
  on semver tag refs
- Other publishers (Istio, Vault, Kyverno) noted as gaps — they don't
  ship keyless Sigstore signatures

## Architectural memories saved (16 portable lessons)

Each is a 10-30 min debugging story now durable across future sessions:

- `feedback_cilium_karpenter_on_fargate_gotchas` — Karpenter needs AWS_REGION env
- `feedback_eks_daemonset_fargate_exclusion` — Use `karpenter.sh/nodepool=Exists`
- `feedback_myriad_tls_interception_personal_aws` — Palo Alto MITM, `insecure=true` on TF providers
- `feedback_cilium_egress_masquerade_al2023` — `ens+` not `eth0` on AL2023
- `feedback_eks_addon_removal_leaves_daemonset` — Manual DS cleanup needed
- `feedback_cilium_wireguard_fargate_incompat` — Pin Fargate workloads to EC2
- `feedback_cilium_gateway_api_crds` — Three preconditions Cilium 1.16 needs
- `feedback_cilium_gateway_infrastructure_annotations` — Use `spec.infrastructure.annotations`
- `feedback_eks_intree_lb_karpenter_sg_bug` — Multiple SGs error → install AWS LBC
- `feedback_keycloak_realm_import_gotchas` — Filename + first-boot probes
- `feedback_tetragon_helm_affinity_path` — Top-level `affinity:`, not nested
- `feedback_no_wrap_suggestions` — Don't offer "stop/pause" as menu options

Plus pre-migration: `feedback_bitnami_broadcom_traps`, `feedback_hpa_scale_from_zero`,
`feedback_karpenter_istio_cni_race`, `feedback_zoom_out_for_architectural_advice`.

## What's deployed in the cluster

### Networking + Ingress
- Cilium 1.16.5 (kpr=true, WireGuard, native routing, ENI IPAM)
- Cilium Gateway API (shared-gateway with 6 listeners — grafana, hubble,
  argocd, keycloak, langfuse, rollouts)
- AWS Load Balancer Controller (1 NLB)
- external-dns (Route53)

### Auth + GitOps
- Keycloak 26.3.3 + realm + 2 OIDC clients (argocd, grafana)
- ArgoCD 7.7.7 (HA Redis Sentinel) with Keycloak OIDC

### Observability
- Prometheus + Alertmanager + Grafana + 30 dashboards
- Tempo (distributed tracing)
- Hubble (Cilium flow observability)
- Tetragon (eBPF runtime security)
- DCGM Exporter (per-GPU metrics, dormant until GPU nodes)

### Security
- cert-manager + Let's Encrypt (DNS-01 via Route53)
- Trivy Operator (CVE / config / RBAC scanning)
- Kyverno (5 ClusterPolicies, baseline + cosign signature)
- 4 CiliumNetworkPolicies (3 L3/L4 + 1 L7)
- Vault HA Raft (init pending) + Agent Injector + VSO
- Velero (backup/restore)

### Platform
- Karpenter (general NodePool, c6a.large)
- KEDA + ScaledObject demo
- Argo Rollouts (canary/blueGreen-ready)
- Kubeflow Training Operator v1.8.0
- Microsoft Presidio (PII detect + anonymize)

### AI Plane (not yet deployed)
- Langfuse v3 (LLM observability — ready, awaiting traces from apps)
- vLLM image prepull DS (waiting for GPU NodePool)
- model-weights S3 bucket + Mountpoint S3 CSI driver

### AWS Infra
- 1 NLB, 1 RDS Postgres, 1 ACM wildcard cert, 1 KMS key (Vault),
  1 model-weights S3 bucket, 1 Velero S3 bucket, 1 ECR repo

## Operational follow-ups

1. **DNS cutover from old lab cluster** — old cluster's external-dns
   still owns Route53 records for grafana / argocd / keycloak / langfuse.
   New cluster's external-dns has policy=upsert-only and won't overwrite.
   Resolution: scale old cluster's external-dns to 0, then delete the
   stale records once.

2. **Vault initialization** — `kubectl -n vault exec -it vault-0 -- vault
   operator init -recovery-shares=5 -recovery-threshold=3`. Save recovery
   keys + initial root token. KMS handles all subsequent unseals.

3. **Vault config layer** — `vault-config.tf` (in `_disabled/`) adds the
   K8s auth backend + KV mounts + policies. Needs vault provider to
   reach Vault (port-forward or post-DNS-cutover).

4. **GPU NodePool** — `karpenter-nodepool.tf` currently only has the
   `general` pool. Phase 4e proper adds a GPU pool (g6.xlarge or g5.xlarge)
   so vLLM workloads can request `nvidia.com/gpu: 1`.

5. **App workloads** — `chat-ui`, `rag-service`, `langgraph-service`,
   `ingestion-service`, `vllm` — need app images built + pushed to ECR
   first. The argocd-apps.tf wires them up via ArgoCD Application CRs;
   currently in `_disabled/`.

6. **oauth2-proxy** — closes the unauthenticated-dashboard gap on the
   argo-rollouts dashboard. Currently in `_disabled/`; needs the
   keycloak terraform provider to reach keycloak.${var.domain} (post-DNS-cutover).

## Resume narrative

> Migrated production-grade EKS cluster's networking + ingress + service
> mesh from AWS VPC CNI + kube-proxy + Istio → Cilium eBPF datapath
> end-to-end. Cilium native CNI in ENI IPAM mode replaces VPC CNI. Full
> kubeProxyReplacement eliminates iptables NAT — all Service routing
> via eBPF, real source IPs preserved in Hubble flows. Cilium Gateway
> API with AWS Load Balancer Controller replaces Istio + ingress-nginx.
> Cilium WireGuard pod-to-pod encryption replaces Istio mTLS.
>
> Deployed across hybrid Karpenter+Fargate compute (Karpenter agent runs
> on Fargate; EC2 workers provisioned dynamically by Karpenter). 17 helm
> releases including ArgoCD with Keycloak OIDC, Vault HA with KMS
> auto-unseal, Tetragon eBPF runtime security, Trivy + Kyverno (detective
> + preventive), KEDA event-driven autoscaling, Langfuse for LLM
> observability, full Prometheus + Tempo + Hubble observability stack.
>
> 16 architectural lessons documented as portable engineering memories
> covering Cilium gotchas, Bitnami catalog migration traps, EKS addon
> lifecycle, and admission policy patterns.
