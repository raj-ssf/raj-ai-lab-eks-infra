resource "kubernetes_namespace" "ingress_nginx" {
  metadata {
    name = "ingress-nginx"
  }
}

resource "helm_release" "ingress_nginx" {
  name       = "ingress-nginx"
  namespace  = kubernetes_namespace.ingress_nginx.metadata[0].name
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = "4.11.3"

  values = [
    yamlencode({
      controller = {
        service = {
          type = "LoadBalancer"
          annotations = {
            "service.beta.kubernetes.io/aws-load-balancer-type"                              = "external"
            "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type"                   = "ip"
            "service.beta.kubernetes.io/aws-load-balancer-scheme"                            = "internet-facing"
            "service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled" = "true"
            "service.beta.kubernetes.io/aws-load-balancer-subnets"                           = join(",", data.aws_subnets.public.ids)
          }
        }
        config = {
          use-forwarded-headers     = "true"
          allow-snippet-annotations = "true"
        }
        ingressClassResource = {
          name    = "nginx"
          default = true
        }
        nodeSelector = {
          "topology.kubernetes.io/zone" = "us-west-2a"
        }
      }
    })
  ]

  depends_on = [
    module.eks,
    helm_release.alb_controller,
    kubernetes_namespace.ingress_nginx,
  ]
}

# Force-delete fallback via provisioner — runs on destroy BEFORE helm uninstall
resource "null_resource" "nginx_cleanup" {
  triggers = {
    cluster_name = module.eks.cluster_name
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
        # Graceful Service delete first — lets ALB controller clean up NLB + TGs properly
        kubectl -n ingress-nginx delete svc ingress-nginx-controller --ignore-not-found=true --timeout=60s 2>/dev/null || true

        # Fallback: strip Service finalizer, force-delete
        kubectl -n ingress-nginx patch svc ingress-nginx-controller --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
        kubectl -n ingress-nginx delete svc ingress-nginx-controller --force --grace-period=0 --ignore-not-found=true 2>/dev/null || true

        # Critical: strip TargetGroupBinding finalizers — these block namespace deletion if ALB controller is gone
        kubectl -n ingress-nginx get targetgroupbinding.elbv2.k8s.aws -o name 2>/dev/null | \
          xargs -r -I{} kubectl -n ingress-nginx patch {} --type=merge -p '{"metadata":{"finalizers":null}}'
      EOT
  }
  depends_on = [helm_release.ingress_nginx]
}

output "ingress_nginx_hostname" {
  value       = "Run: kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
  description = "How to fetch the NLB hostname (won't be in TF state because it's set by the controller, not by TF)"
}