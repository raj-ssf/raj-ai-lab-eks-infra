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
# Lifecycle: unconditional — always installed. With Karpenter (see
# karpenter.tf), GPU nodes appear dynamically in response to pod demand
# rather than via a static managed node group. The device-plugin DaemonSet
# has nodeSelector nvidia.com/gpu=true so it has zero pods when no GPU
# node exists (free at idle), and immediately schedules a pod onto any
# GPU node Karpenter provisions.

resource "helm_release" "nvidia_device_plugin" {
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
      # Tolerate every taint any GPU node may carry. The default `gpu`
      # NodePool only adds `nvidia.com/gpu`, but `gpu-experiments` (see
      # karpenter-nodepool.tf) also adds `gpu-experiment` for opt-in
      # workload isolation. Without the second toleration here, the
      # device plugin DS skips experiments-pool nodes entirely, GPUs
      # are never advertised on them, and any pod targeting that pool
      # stays Pending forever with `Insufficient nvidia.com/gpu`.
      tolerations = [
        {
          key      = "nvidia.com/gpu"
          operator = "Exists"
          effect   = "NoSchedule"
        },
        {
          key      = "gpu-experiment"
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
