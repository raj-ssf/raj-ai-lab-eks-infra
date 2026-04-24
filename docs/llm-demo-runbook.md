# vLLM 70B Demo Runbook

On-demand spin-up for Llama 3.3 70B AWQ serving on a g5.12xlarge GPU node.
Idle cost ~$6/mo (PVC + S3); demo cost ~$5.67/hr while the GPU node is up.

## Prerequisites

- Cluster `raj-ai-lab-eks` already running (default node group healthy)
- `terraform.tfvars` present and gitignored
- S3 bucket `raj-ai-lab-eks-model-weights` has the Llama 3.3 70B AWQ weights
  at key prefix `llama-3.3-70b-instruct-awq/` (staged once via
  `stage-weights-job.yaml`; persistent — only re-run if the model changes)
- PVC `vllm-model-cache` in namespace `llm` is in AZ matching `var.gpu_az`
  (defaults to `us-west-2c`). Verify: `kubectl -n llm get pvc vllm-model-cache`
  then `kubectl get pv <bound-pv-name> -o yaml | grep -A 3 nodeAffinity`.

## Spin up

```bash
cd ~/git/raj-ai-lab-eks-infra

# 1. Flip the GPU toggle in tfvars
sed -i.bak 's/^enable_gpu_node_group *=.*$/enable_gpu_node_group = true/' terraform.tfvars
rm -f terraform.tfvars.bak
grep enable_gpu_node_group terraform.tfvars

# 2. Apply — expect 2 to add (gpu nodegroup + nvidia-device-plugin helm release)
terraform apply

# 3. Wait for GPU node join (~2-3 min after apply)
kubectl get nodes -l nvidia.com/gpu=true -w
# Ctrl-C when: status is Ready

# 4. Confirm device plugin advertising 4 GPUs (~30s after node Ready)
GPU_NODE=$(kubectl get nodes -l nvidia.com/gpu=true -o jsonpath='{.items[0].metadata.name}')
kubectl describe node "$GPU_NODE" | grep -E "Capacity:|Allocatable:" -A 8 | grep nvidia
# Expect: nvidia.com/gpu: 4 on both Capacity and Allocatable

# 5. Force ArgoCD to sync the vllm Deployment (auto-sync also picks it up within ~3 min)
kubectl -n argocd patch application vllm --type merge -p '{"operation":{"sync":{}}}'

# 6. Watch pod cold-start flow (total ~8-10 min first time on a fresh node)
kubectl -n llm get pod -l app=vllm -w
# Expected transitions:
#   Pending          (scheduler places on GPU node)
#   Init:0/1         (aws s3 sync to PVC, ~60s or seconds if PVC already warm)
#   ContainerCreating (~3-5 min, vllm/vllm-openai image pull)
#   Running 0/1      (~2-3 min, 70B weights load across 4 GPUs)
#   Running 1/1      (startup probe passed → ready for traffic)
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
cd ~/git/raj-ai-lab-eks-infra

# 1. Flip GPU toggle off
sed -i.bak 's/^enable_gpu_node_group *=.*$/enable_gpu_node_group = false/' terraform.tfvars
rm -f terraform.tfvars.bak
grep enable_gpu_node_group terraform.tfvars

# 2. If rag-service was set to auto, revert it so Bedrock is the steady state
kubectl set env deployment/rag-service -n rag LLM_PROVIDER=bedrock

# 3. Apply — expect 2 to destroy (gpu nodegroup + nvidia-device-plugin)
terraform apply

# 4. Verify no g5 compute running
aws eks list-nodegroups --cluster-name raj-ai-lab-eks --output table
# Expect: only default-...

aws ec2 describe-instances \
  --filters "Name=instance-type,Values=g5.12xlarge" \
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

1. **PVC AZ-lock** — the GPU node MUST be in the same AZ as the PVC's EBS
   volume. `var.gpu_az` in the infra Terraform pins the node group subnets
   to a single AZ (defaults `us-west-2c`, matching where the PVC currently
   lives). If the PVC ever gets recreated in a different AZ (deleted, then
   re-bound by a pod landing elsewhere), update `var.gpu_az` to match.

2. **`enableServiceLinks: false`** is set on the vllm pod spec — without
   it, Kubernetes injects `VLLM_PORT=tcp://<svc>:8000` (from the
   namespace's own `vllm` Service), which shadows vLLM's native `VLLM_PORT`
   config and crashes engine init with `ValueError`. Don't remove.

3. **Don't combine `disk_size` and `block_device_mappings`** on the GPU
   nodegroup — this triggered a runaway rolling-update loop on 2026-04-24
   that burned ~18 g5.12xlarge instances. `block_device_mappings` is the
   single source of truth for root disk; see eks.tf comments.

4. **`max_size = 1`** on the GPU node group is intentional. No bursting
   during rolling updates — any LT change terminates then launches, with
   vllm downtime during replacement. Correct tradeoff for a lab.

5. **ASG suspension cleanup** — if you ever manually suspend ASG processes
   for emergency cost control, make sure to resume `Terminate` +
   `HealthCheck` + `ReplaceUnhealthy` before asking EKS to delete the
   nodegroup. `Launch` can stay suspended. Otherwise EKS delete-nodegroup
   fails with `AutoScalingGroupInvalidConfiguration: Couldn't terminate
   instances in ASG as Terminate process is suspended`.
