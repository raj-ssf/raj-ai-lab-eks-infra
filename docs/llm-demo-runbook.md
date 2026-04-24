# vLLM 70B Demo Runbook

On-demand Llama 3.3 70B AWQ serving on a Karpenter-provisioned GPU node.
Idle cost ~$6/mo (PVC + S3). Demo cost is GPU-instance-dependent:
~$5.67/hr on g5.12xlarge, ~$4.60/hr on g6.12xlarge (Karpenter picks the
cheapest available in its allowed list).

**Lifecycle shift (2026-04-24):** The old `enable_gpu_node_group` toggle
+ `terraform apply` dance is gone. Karpenter watches for vllm pods
requesting `nvidia.com/gpu: 4`, provisions a node to satisfy them, and
consolidates the node when the pod scales to zero. Demo spin-up is now a
single `kubectl scale` command.

## Prerequisites

- Cluster `raj-ai-lab-eks` running (default node group healthy)
- Karpenter installed + healthy (`kubectl -n kube-system get pod -l app.kubernetes.io/name=karpenter`)
- GPU NodePool + EC2NodeClass present (`kubectl get nodepool gpu` / `kubectl get ec2nodeclass gpu`)
- S3 bucket `raj-ai-lab-eks-model-weights` has the Llama 3.3 70B AWQ
  weights at key prefix `llama-3.3-70b-instruct-awq/`
- PVC `vllm-model-cache` in namespace `llm` is in AZ `us-west-2c` (the
  NodePool is pinned to that zone). Verify:
  `kubectl get pv $(kubectl -n llm get pvc vllm-model-cache -o jsonpath='{.spec.volumeName}') -o yaml | grep -A 3 nodeAffinity`

## Spin up

```bash
# Scale vllm up. Karpenter sees the Pending nvidia.com/gpu-requesting pod
# and provisions a GPU node in ~60-90 seconds.
kubectl -n llm scale deployment vllm --replicas=1

# Watch Karpenter's NodeClaim + actual node come up.
kubectl get nodeclaims -w
# (Ctrl-C when the NodeClaim shows ready=True + a node name)

# Then the pod flow:
kubectl -n llm get pod -l app=vllm -w
# Expected transitions:
#   Pending            (waiting for Karpenter → node join, ~60-90s)
#   Init:0/1           (aws s3 sync to PVC — seconds if PVC is warm)
#   ContainerCreating  (vllm/vllm-openai image pull)
#                      * 3-5 min first time on a given node
#                      * Seconds if the image-prepull DaemonSet got there first
#   Running 0/1        (2-3 min — 70B loads across 4 GPUs)
#   Running 1/1        (startup probe passed)
```

## Smoke test

Two paths — in-cluster via port-forward or end-to-end via the public ingress.

### Port-forward (fastest)

```bash
kubectl -n llm port-forward svc/vllm 8000:8000 &
sleep 2
curl -s http://localhost:8000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "llama-3.3-70b",
    "messages": [{"role":"user","content":"In 3 sentences, explain why tensor parallelism is used for large-model serving."}],
    "max_tokens": 200
  }' | jq '{text: .choices[0].message.content, tokens_in: .usage.prompt_tokens, tokens_out: .usage.completion_tokens}'
kill %1 2>/dev/null
```

Expected: 15-25 tok/s generation rate. First request ~5-10s, subsequent faster.

### Via public ingress (full north-south path)

```bash
curl -s https://llm.ekstest.com/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "llama-3.3-70b",
    "messages": [{"role":"user","content":"Name three prime numbers above 100."}],
    "max_tokens": 100
  }' | jq
```

External-DNS should have published the A record; cert-manager should have a
Let's Encrypt cert. If DNS isn't resolving yet, give external-dns up to 60s
to reconcile after the pod goes Ready.

### Hybrid routing through rag-service

With `LLM_PROVIDER=auto` on the rag-service Deployment (default is `bedrock`
— flip to `auto` via `kubectl set env deployment/rag-service LLM_PROVIDER=auto -n rag`
before the demo), every `/invoke` call tries vLLM first and falls back to
Bedrock on failure. Default stays `bedrock` so the rag-service rollout is
safe to land when vLLM isn't running.

```bash
# Test against rag.ekstest.com (via ingress)
curl -s https://rag.ekstest.com/invoke \
  -H 'content-type: application/json' \
  -d '{"prompt":"Explain how RAG retrieval grounds an LLM response.","max_tokens":200}' \
  | jq '{provider, model, routing, text}'
# Response now includes "provider": "vllm" when the hybrid path is hitting
# self-hosted; flips to "provider": "bedrock" when vLLM is down.
```

## Shut down

```bash
# 1. If rag-service was flipped to vllm/auto, revert it so Bedrock is the
#    steady-state provider.
kubectl set env deployment/rag-service -n rag LLM_PROVIDER=bedrock

# 2. Scale vllm down. Karpenter detects the now-empty GPU node, consolidates
#    after 30s, and terminates the EC2 instance. No terraform apply needed.
kubectl -n llm scale deployment vllm --replicas=0

# 3. Verify the NodeClaim is gone after ~60s
kubectl get nodeclaims

# 4. Sanity — no g5/g6 instances in any billable state
aws ec2 describe-instances \
  --filters "Name=instance-type,Values=g5.12xlarge,g6.12xlarge" \
            "Name=instance-state-name,Values=running,pending,stopping,stopped" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output table
# Expect: empty
```

## What persists between demos

- S3 bucket + weights (~$1/mo)
- PVC `vllm-model-cache` with 60 GiB of populated gp3 EBS (~$5/mo)
- Pod Identity role bindings (free)
- ArgoCD Application manifest — Application stays OutOfSync/Missing until
  the GPU node reappears; automatic re-sync on next spin-up
- Kyverno catch-all allowlist entries for vllm/aws-cli (free)
- `llm` namespace and its Service/Ingress/ServiceAccount (free)

## Reference cost envelope

| Workload | Idle | Demo-hour |
|---|---|---|
| m5.xlarge × 3 (default node group) | $0.60/hr — always on | same |
| EKS control plane | $0.10/hr — always on | same |
| g5.12xlarge (GPU node) | $0 | +$5.67/hr |
| nvidia-device-plugin helm | free | free |
| PVC + S3 + other K8s | ~$0.008/hr (~$6/mo prorated) | same |
| **Total additional** | **$0** | **$5.67/hr** |

A 2-hour interview demo costs ~$11.34. A 30-min sanity check during prep
costs ~$2.85.

## Known gotchas (captured in project memory)

1. **PVC AZ-lock** — Karpenter's NodePool requirement
   `topology.kubernetes.io/zone In [us-west-2c]` pins the GPU node to the
   same AZ as the vllm-model-cache PVC's EBS volume. If the PVC ever gets
   recreated in a different AZ (delete + re-bind on a non-2c node), update
   the NodePool's zone requirement.

2. **`enableServiceLinks: false`** is set on the vllm pod spec — without
   it, Kubernetes injects `VLLM_PORT=tcp://<svc>:8000` (from the
   namespace's own `vllm` Service), which shadows vLLM's native `VLLM_PORT`
   config and crashes engine init with `ValueError`. Don't remove.

3. **NodePool `limits`** caps total GPU capacity (currently cpu=96,
   nvidia.com/gpu=8 — max 2 × 4-GPU instances simultaneously). Prevents
   runaway provisioning if something mass-creates GPU-requesting pods.
   Bump only deliberately.

4. **NodePool has `expireAfter: 720h`** — nodes auto-recycle after 30 days.
   Avoids the 'drift from the latest AL2023 NVIDIA AMI' / 'leak transient
   CUDA allocation' problems that come with long-lived GPU nodes. For
   active demos you'll never hit this; just worth knowing.

5. **Karpenter needs a reachable default node group to land on** —
   Karpenter controller pins itself via nodeSelector `workload=general`,
   which only matches the static m5.xlarge node group. If you ever
   rename/relabel/remove the default node group, Karpenter pods go
   Pending → no GPU provisioning happens.
