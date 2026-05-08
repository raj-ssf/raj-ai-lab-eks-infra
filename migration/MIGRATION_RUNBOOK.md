# Cilium Migration Runbook — `raj-ai-lab-eks` → `raj-ai-lab-eks-cilium`

**Goal:** rebuild the EKS lab on a unified Cilium eBPF stack (CNI + Hubble + Tetragon + Service Mesh), eliminating AWS VPC CNI and Istio. Use Fargate-bootstrapped Karpenter so 100% of EC2 capacity is Karpenter-managed.

**Approach:** parallel rebuild. Both clusters run side-by-side during migration. New cluster uses `*-v2.ekstest.com` subdomains for validation. At Phase 8 cutover, primary names flip to new cluster, old cluster destroyed.

**DNS zone:** `ekstest.com` (preserved — same Route53 hosted zone for both clusters).

---

## Phase 1 — Build new cluster on Cilium native CNI + Fargate-bootstrapped Karpenter

**Estimated time:** 4-6 hours. **Destructive?** Provisions new infra. Old cluster untouched.

1. Create feature branch in `raj-ai-lab-eks-infra` (already done: `migration/cilium-fargate`).
2. Apply Terraform changes (see `TERRAFORM_DELTA.md`):
   - New `var.cluster_name = "raj-ai-lab-eks-cilium"`
   - Remove `eks_managed_node_groups` from `module.eks`
   - Add 2 Fargate profiles: `karpenter` namespace, `kube-system` (CoreDNS pods only via labelSelector)
   - Disable VPC CNI addon (or set `before_compute = true` and uninstall after Cilium is up — see https://docs.cilium.io/en/stable/installation/k8s-install-helm/#aws-eks)
3. After `terraform apply`:
   - Verify EKS control plane is healthy: `aws eks describe-cluster --name raj-ai-lab-eks-cilium`
   - Verify Fargate profiles exist: `aws eks list-fargate-profiles --cluster-name raj-ai-lab-eks-cilium`
4. Install Cilium via helm (BEFORE any non-Fargate workload tries to schedule):
   ```
   helm install cilium cilium/cilium \
     --version 1.16.5 \
     --namespace kube-system \
     --set eni.enabled=true \
     --set ipam.mode=eni \
     --set egressMasqueradeInterfaces=eth0 \
     --set routingMode=native \
     --set k8sServiceHost=<new-cluster-api-endpoint> \
     --set k8sServicePort=443 \
     --set hubble.enabled=true \
     --set hubble.relay.enabled=true \
     --set hubble.ui.enabled=true \
     --set encryption.enabled=true \
     --set encryption.type=wireguard
   ```
5. Install Karpenter helm chart with `tolerations` to land on Fargate:
   - Karpenter pods need to schedule on the Fargate profile we created
   - Verify with `kubectl get pods -n karpenter -o wide` — pods should show `fargate-*` node names
6. Define Karpenter NodePool + EC2NodeClass for the cluster's general workload capacity. Reuse existing definitions in `karpenter.tf` with minor edits.
7. Install Cilium Tetragon:
   ```
   helm install tetragon cilium/tetragon \
     --version 1.5.x \
     --namespace kube-system
   ```
8. Verify by deploying a test workload in `default` ns, confirming it lands on a Karpenter-provisioned EC2 node, and Hubble UI shows the pod's traffic.

**Phase 1 success criteria:**
- ✅ EKS cluster up, no managed node groups
- ✅ Karpenter pods running on Fargate
- ✅ Cilium DaemonSet running on Karpenter-provisioned EC2 nodes
- ✅ Hubble UI accessible (port-forward) and showing pod traffic
- ✅ Test workload deploys and reaches kubernetes.default.svc

---

## Phase 2 — Foundation services

**Estimated time:** 2-3 hours. **Destructive?** No.

Re-deploy on new cluster (via ArgoCD or direct helm) — these don't depend on Istio:

- `cert-manager` (v1.16.2) — needed for Phase 3 cert issuance
- `external-dns` with `txtOwnerId: raj-ai-lab-eks-cilium` (different from old cluster's `raj-ai-lab-eks`)
- `kube-prometheus-stack` for monitoring + Tempo for tracing (later)
- `velero` with shared S3 backend (so we can restore PVCs from old cluster's backups)

**Verification:**
- ✅ `cert-manager` issues a test Certificate successfully
- ✅ `external-dns` writes a TXT ownership record in `ekstest.com` zone with new ID
- ✅ Velero Backups from old cluster are visible: `velero backup get`

---

## Phase 3 — Cilium Gateway API + ingress for `*-v2.ekstest.com`

**Estimated time:** 2-3 hours. **Destructive?** No.

1. Enable Cilium Gateway API:
   ```
   helm upgrade cilium cilium/cilium -n kube-system --reuse-values \
     --set gatewayAPI.enabled=true
   ```
2. Define a Gateway resource with hostnames matching `*-v2.ekstest.com`:
   ```yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: Gateway
   metadata:
     name: cilium-gateway
     namespace: kube-system
   spec:
     gatewayClassName: cilium
     listeners:
       - name: https
         port: 443
         protocol: HTTPS
         hostname: "*.ekstest.com"
         tls:
           mode: Terminate
           certificateRefs:
             - name: wildcard-cert
   ```
3. Issue wildcard cert via cert-manager (`*.ekstest.com`) — simpler than 11 per-name certs
4. Verify Gateway provisions an ALB (via aws-load-balancer-controller) or NLB — record the address
5. external-dns picks up the Gateway's hostname → creates DNS record

**Phase 3 success criteria:**
- ✅ Cilium Gateway has `Programmed` condition true
- ✅ ALB/NLB exists in AWS console
- ✅ DNS record `*-v2.ekstest.com` resolves to the new ALB
- ✅ Wildcard cert is `Ready: True`

---

## Phase 4 — Re-deploy app workloads (no Istio sidecars)

**Estimated time:** 3-4 hours. **Destructive?** No.

For each of the 11 Istio-injected namespaces:

1. Strip `istio-injection=enabled` from the namespace label in manifests
2. Replace Istio `Gateway` + `VirtualService` with `HTTPRoute` (most workloads already have HTTPRoute — those are kept)
3. Translate Istio canary `VirtualService`s (chat-ui, ingestion-service, langgraph-service, rag-service) to Argo Rollouts traffic management — likely uses the Argo Rollouts Gateway API plugin
4. Update HTTPRoute hostnames to `*-v2.ekstest.com` for validation:
   - `argocd.ekstest.com` → `argocd-v2.ekstest.com`
   - etc.
5. ArgoCD syncs apps to new cluster; verify each comes up healthy
6. **Stateful workloads:**
   - keycloak-postgres: Velero restore from latest backup, OR pg_dump → restore
   - langfuse-postgresql + clickhouse: Velero restore
   - langgraph-redis: skip (cache, regenerable)
   - vllm caches: Velero restore for the big ones (llama-405b, deepseek-r1-70b); accept re-download for smaller models if Velero restore is slow
7. Update Keycloak realm clients to allow `*-v2.ekstest.com/auth/callback` redirect URIs (TEMPORARY — revert at Phase 8)

**Verification per namespace:**
- ✅ Pods Running, no sidecars (`kubectl get pod -n <ns> -o jsonpath='{.items[*].spec.containers[*].name}'` should not contain `istio-proxy`)
- ✅ HTTPRoute reaches workload via `*-v2.ekstest.com`
- ✅ For OAuth-protected apps, login flow works end-to-end

---

## Phase 5 — Cilium Service Mesh + mTLS

**Estimated time:** 2-3 hours. **Destructive?** Toggles cluster-wide encryption.

1. Confirm Cilium WireGuard encryption is healthy on all nodes:
   ```
   cilium encrypt status
   ```
2. Define Cilium Service Mesh (CSM) features: L7-aware policies via CiliumNetworkPolicy
3. Translate Istio AuthorizationPolicy resources to CiliumNetworkPolicy with HTTP rules. Example:
   ```yaml
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   spec:
     endpointSelector:
       matchLabels:
         app: keycloak
     ingress:
       - fromEndpoints:
           - matchLabels: {namespace: argocd, app: argocd-server}
         toPorts:
           - ports: [{port: "8443", protocol: TCP}]
             rules:
               http:
                 - method: "POST"
                   path: "/realms/master/protocol/openid-connect/token"
   ```
4. Apply Cilium ClusterMesh (only if multi-cluster traffic in future — skip for single-cluster lab)

**Verification:**
- ✅ All node-to-node traffic is encrypted (WireGuard packets visible via tcpdump on host)
- ✅ Hubble shows L7 HTTP visibility (path/method per request)
- ✅ CiliumNetworkPolicy denies test traffic when violated, allows when matched

---

## Phase 6 — Trivy Operator + AWS-side defense in depth

**Estimated time:** 1-2 hours. **Destructive?** No.

1. Install Trivy Operator helm chart:
   ```
   helm install trivy-operator aqua/trivy-operator \
     --namespace trivy-system --create-namespace \
     --version 0.24.x \
     --set trivy.command=image,filesystem,rootfs \
     --set compliance.cron='@daily'
   ```
2. Verify it produces `VulnerabilityReport` and `ConfigAuditReport` CRs for existing workloads
3. Enable AWS GuardDuty Runtime Monitoring on account 050693401425
4. Enable Inspector v2 with ECR integration

**Verification:**
- ✅ `kubectl get vulnerabilityreport -A` returns reports for app pods
- ✅ AWS GuardDuty findings page shows "EKS Runtime Monitoring: Enabled"
- ✅ ECR scan results visible for any pushed image

---

## Phase 7 — Pre-cutover validation

**Estimated time:** 1-2 hours. **Destructive?** No.

Run end-to-end validation BEFORE flipping primary DNS:

1. Login to `argocd-v2.ekstest.com` via OAuth → confirm Keycloak flow works
2. Generate vLLM inference traffic to `llm-v2.ekstest.com` → confirm latency + throughput similar to old cluster
3. Run a Langfuse trace through `langfuse-v2.ekstest.com`
4. Verify Hubble UI shows expected service-to-service traffic
5. Verify Tetragon detects an intentional policy violation (e.g., exec into a pod)
6. Verify Trivy reports show no high-severity CVEs (or at least matches old cluster's baseline)
7. Verify backups are flowing to S3 from new cluster's Velero

If anything fails, fix on the new cluster — old cluster is still serving traffic on primary names.

---

## Phase 8 — DNS cutover + decommission old cluster

**Estimated time:** 1-2 hours. **Destructive?** Yes — destroys old cluster.

1. Update HTTPRoute hostnames on new cluster: `argocd-v2.ekstest.com` → `argocd.ekstest.com` (drop the `-v2`)
2. external-dns reconciles → primary DNS records now point to new cluster's gateway
3. Wait for DNS propagation (~5 min depending on TTL)
4. Verify each app reachable on its primary name and routes to new cluster
5. Update Keycloak realm clients: remove the `-v2` redirect URIs added in Phase 4
6. Update local kubeconfig: `aws eks update-kubeconfig --name raj-ai-lab-eks-cilium --alias raj-ai-lab-eks` (rename context for muscle memory)
7. Verify Datadog (or whatever monitoring) shows the new cluster reporting under expected names
8. Take final Velero backup of old cluster for archive
9. Destroy old cluster IaC: `terraform destroy` against the old cluster's state file
10. Confirm AWS console shows old EKS cluster gone, leftover ELBs/ENIs cleaned up
11. Update documentation: cluster name, Datadog cluster_name tags, oncall runbooks
12. Celebrate. Update LinkedIn / resume.

**Phase 8 success criteria:**
- ✅ All 11 hostnames resolve to new cluster
- ✅ End-to-end smoke tests pass on primary names
- ✅ Old cluster is destroyed; AWS bill shows only one EKS cluster running
- ✅ DNS records have ownership ID `raj-ai-lab-eks-cilium` only (no orphans)
