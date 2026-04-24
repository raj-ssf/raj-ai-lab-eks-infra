# Kubernetes Secret holding Langfuse API keys for rag-service.
#
# rag-service's Deployment (in the raj-ai-lab-eks app repo) mounts this via
# `envFrom.secretRef.name: rag-service-langfuse` with optional=true, so the
# pod admits even when the Secret is missing/empty. The Langfuse Python SDK
# no-ops gracefully if the env vars aren't set.
#
# Lifecycle: the Secret is only created when BOTH keys are non-empty in
# tfvars. The count = ... gate means a fresh clone with no Langfuse keys
# set won't generate an orphan Secret resource, and `terraform apply`
# before the keys are minted is a clean no-op.

resource "kubernetes_secret" "rag_service_langfuse" {
  count = (var.langfuse_public_key != "" && var.langfuse_secret_key != "") ? 1 : 0

  metadata {
    name      = "rag-service-langfuse"
    namespace = "rag"
  }

  type = "Opaque"

  data = {
    # K8s Secret values are base64-encoded automatically by the provider.
    # The Python SDK reads these exact env var names out of os.environ —
    # don't rename unless you also change the envFrom binding in the app
    # repo.
    LANGFUSE_PUBLIC_KEY = var.langfuse_public_key
    LANGFUSE_SECRET_KEY = var.langfuse_secret_key
  }
}
