# NVIDIA Device Plugin — advertises nvidia.com/gpu as a schedulable
# kubelet resource.
#
# Why this file exists: the AL2023_x86_64_NVIDIA AMI (used by the GPU node
# group in eks.tf) ships with:
#   - NVIDIA drivers installed and loaded
#   - NVIDIA Container Toolkit configured as containerd's runtime handler
#   - NOT the device plugin DaemonSet
#
# Without the plugin, `kubectl describe node <gpu>` shows zero
# `nvidia.com/gpu` capacity even though the GPUs are physically attached
# and drivers are loaded. Pods requesting `nvidia.com/gpu: N` pend forever
# with "Insufficient nvidia.com/gpu" because kubelet literally doesn't know
# about them.
#
# Alternative considered: NVIDIA GPU Operator. Overkill — the Operator
# manages driver installation, MIG partitioning, DCGM exporter, MPS, etc.
# We need exactly one of its components (device plugin); the standalone
# chart is a cleaner fit for a lab.
#
# Lifecycle: count-conditional on enable_gpu_node_group. When the toggle
# flips true, Terraform apply creates the GPU node group AND installs the
# device plugin. When the toggle flips back to false (between demos for
# cost), both are destroyed together. No orphan kube-system resources.

resource "helm_release" "nvidia_device_plugin" {
  count = var.enable_gpu_node_group ? 1 : 0

  name       = "nvidia-device-plugin"
  namespace  = "kube-system"
  repository = "https://nvidia.github.io/k8s-device-plugin"
  chart      = "nvidia-device-plugin"
  version    = "0.17.0"

  values = [
    yamlencode({
      # Schedule the DaemonSet only on GPU nodes. Labels set in eks.tf.
      nodeSelector = {
        "nvidia.com/gpu" = "true"
      }
      # Tolerate the GPU taint so the DS pods actually land on tainted nodes.
      tolerations = [
        {
          key      = "nvidia.com/gpu"
          operator = "Exists"
          effect   = "NoSchedule"
        },
      ]
      resources = {
        requests = { cpu = "50m", memory = "64Mi" }
        limits   = { cpu = "100m", memory = "128Mi" }
      }
      # (removed failOnInitError: the chart wires it through as an env
      # value, which must be a string — passing a YAML bool breaks the
      # DaemonSet schema. Default behavior is fine for our use case.)
    })
  ]

  depends_on = [module.eks]
}
