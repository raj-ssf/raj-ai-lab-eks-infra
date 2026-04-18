resource "kubernetes_storage_class_v1" "gp3" {
    metadata {
      name = "gp3"
      annotations = {
        "storageclass.kubernetes.io/is-default-class" = "true"
      }
    }

    storage_provisioner    = "ebs.csi.aws.com"
    reclaim_policy         = "Delete"
    volume_binding_mode    = "WaitForFirstConsumer"
    allow_volume_expansion = true

    parameters = {
      type      = "gp3"
      encrypted = "true"
      fsType    = "ext4"
    }

    depends_on = [module.eks.cluster_addons]
  }

  resource "kubernetes_annotations" "gp2_not_default" {
    api_version = "storage.k8s.io/v1"
    kind        = "StorageClass"
    metadata {
      name = "gp2"
    }
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "false"
    }
    force = true

    depends_on = [module.eks.cluster_addons]
  }