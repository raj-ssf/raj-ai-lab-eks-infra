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
        }
      })
    ]

    depends_on = [
      module.eks,
      helm_release.alb_controller,
    ]
  }

  output "ingress_nginx_hostname" {
    value       = "Run: kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
    description = "How to fetch the NLB hostname (won't be in TF state because it's set by the controller, not by TF)"
  }