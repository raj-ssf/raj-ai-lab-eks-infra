# Pre-pull the vllm/vllm-openai image onto GPU nodes as soon as they join,
# so the 3-5 minute image-pull cold-start on the real vllm pod drops to a
# few seconds (image already in the node's containerd cache).
#
# Pattern: one-shot DaemonSet with an initContainer that "pulls" the image
# (runs /bin/true against it so containerd fetches all layers) and a main
# container (pause) that holds the pod in a trivially-ready state. Because
# the initContainer runs to completion before the main container starts,
# the image ends up in the node's containerd cache by the time the pod is
# Ready — same mechanic kubelet uses for any other scheduled pod, just
# without any real workload attached.
#
# Lifecycle: count-conditional on enable_gpu_node_group. When the toggle
# flips true, Terraform creates the DaemonSet; it lands on the (just-joined)
# GPU node in <30s; image pull completes in ~3-5 min in parallel with vllm
# pod scheduling. Kyverno catch-all doesn't gate kube-system, so no
# allowlist changes needed.
#
# Cost: zero. The pause container uses ~1 MB RAM and no CPU.

resource "kubectl_manifest" "vllm_image_prepull" {
  count = var.enable_gpu_node_group ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "DaemonSet"
    metadata = {
      name      = "vllm-image-prepull"
      namespace = "kube-system"
      labels    = { app = "vllm-image-prepull" }
    }
    spec = {
      selector = {
        matchLabels = { app = "vllm-image-prepull" }
      }
      template = {
        metadata = {
          labels = { app = "vllm-image-prepull" }
        }
        spec = {
          # Run only on GPU nodes.
          nodeSelector = {
            "nvidia.com/gpu.present" = "true"
          }
          tolerations = [
            {
              key      = "nvidia.com/gpu"
              operator = "Exists"
              effect   = "NoSchedule"
            },
          ]
          # initContainer pulls the image as a side effect of being
          # scheduled. Its command runs to completion immediately, but
          # by then containerd has already fetched all the image layers
          # onto the node. Main container (pause) keeps the pod alive
          # and Ready.
          initContainers = [
            {
              name    = "prepull-vllm"
              image   = "vllm/vllm-openai:v0.7.2"
              command = ["/bin/true"]
              resources = {
                requests = { cpu = "10m", memory = "16Mi" }
                limits   = { cpu = "50m", memory = "32Mi" }
              }
            },
          ]
          containers = [
            {
              name  = "pause"
              image = "registry.k8s.io/pause:3.9"
              resources = {
                requests = { cpu = "10m", memory = "8Mi" }
                limits   = { cpu = "50m", memory = "16Mi" }
              }
            },
          ]
          # Don't fight node shutdown during scale-down — image is cached
          # on node, so there's no cleanup needed.
          terminationGracePeriodSeconds = 5
        }
      }
    }
  })

  depends_on = [
    module.eks,
    helm_release.nvidia_device_plugin,
  ]
}
