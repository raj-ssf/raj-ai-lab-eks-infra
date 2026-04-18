# raj-ai-lab-eks-infra

Terraform for the Raj AI Lab on AWS EKS.

## Layout

```
versions.tf    provider pins
providers.tf   aws, kubernetes, helm
variables.tf   inputs (region, cluster name, node sizing, GPU toggle, RDS)
locals.tf     tags
vpc.tf         data sources for SRE-Sandbox-Non-Prod_VPC1 subnets
eks.tf         EKS cluster + managed node groups
outputs.tf
```

## Usage

```bash
aws sso login --profile raj
terraform init
terraform plan
terraform apply
```

After apply:

```bash
$(terraform output -raw kubeconfig_command)
kubectl get nodes
```

## Resources provisioned so far

- EKS 1.32 cluster `raj-ai-lab` in `us-west-2`
- Managed node group: 3x t3.medium in private subnets
- Core addons: coredns, kube-proxy, vpc-cni, pod-identity-agent, ebs-csi-driver
- OIDC provider for IRSA
- Optional GPU node group (`enable_gpu_node_group = true`)

## Planned additions

- RDS Aurora Serverless v2 Postgres
- IRSA roles for External Secrets Operator, AWS Load Balancer Controller, Bedrock access
- Route 53 hosted zone + ACM cert (pending domain choice)
- S3 buckets for Velero backups and lab object storage
