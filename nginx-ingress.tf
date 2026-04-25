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
        # Istio sidecar injection — pod-level opt-in via LABEL (not
        # annotation), since the ingress-nginx namespace doesn't carry
        # the istio-injection=enabled namespace label.
        #
        # Subtle point: Istio's mutating webhook fires based on label
        # match (namespaceSelector + objectSelector), not annotation
        # match. For opt-OUT, both `sidecar.istio.io/inject: "false"`
        # annotation and label work. For opt-IN in a namespace without
        # the namespace label, ONLY the label works — the webhook
        # doesn't even see pods that don't match its label selectors,
        # so any annotation we set goes unused. Bit by this on the
        # first attempt; pod had `inject: "true"` as an annotation but
        # the webhook never ran. Fixed by moving to podLabels.
        #
        # Why pod-level rather than namespace-level injection: the
        # ingress-nginx Helm chart's admission-webhook is configured
        # with pre-install/pre-upgrade hooks that run as Jobs. With a
        # namespace istio-injection=enabled label, those Jobs would
        # also get sidecars and never terminate (sidecar's idle Envoy
        # keeps the pod Running, blocking Job completion → Helm
        # upgrade hangs). controller.podLabels only labels the
        # controller Deployment's pods, so admission Jobs stay
        # un-meshed and finish normally.
        podLabels = {
          "sidecar.istio.io/inject" = "true"
        }
        # Three pod-level annotations control Envoy traffic capture for
        # this controller — each fixes a specific failure mode found
        # during the 2026-04-25 mTLS bringup.
        #
        # excludeInboundPorts: NLB → NGINX traffic terminates TLS at
        # NGINX (cert-manager handles Let's Encrypt) so ports 80/443
        # bypass Envoy. Port 8443 is the admission webhook port —
        # without excluding it, a cluster-wide deny-all blocks the
        # K8s API server's calls to validate.nginx.ingress.kubernetes.io,
        # breaking `kubectl apply` for any Ingress resource.
        #
        # includeOutboundIPRanges: explicitly tell istiod to generate
        # the virtualOutbound listener (0.0.0.0:15001) for this pod.
        # Without it, the excludeInboundPorts annotation suppresses
        # virtualOutbound generation as a side-effect, leaving CNI's
        # iptables redirecting outbound to a non-existent listener.
        # Symptom: pod is meshed, but all outbound traffic bypasses
        # Envoy entirely (zero connections through any outbound
        # cluster). "*" forces capture of all outbound IPv4.
        podAnnotations = {
          "traffic.sidecar.istio.io/excludeInboundPorts"      = "80,443,8443"
          "traffic.sidecar.istio.io/includeOutboundIPRanges"  = "*"
        }
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
          # service-upstream: route via the backend Service's ClusterIP
          # rather than per-pod Endpoints. Required for Istio sidecar
          # mTLS to engage cleanly.
          #
          # Without this: NGINX talks to pod_IP:targetPort directly.
          # Source Envoy looks for a cluster matching that exact dest
          # IP+port. For Services like argocd-server (ports 80/443
          # → targetPort 8080) there's no `outbound|8080||argocd-server`
          # cluster — only outbound|80 and outbound|443. Traffic to
          # pod_IP:8080 falls through to PassthroughCluster (plaintext),
          # breaking mTLS to the backend's sidecar.
          #
          # With service-upstream=true: NGINX talks to ClusterIP:80 (the
          # Service port). kube-proxy iptables resolves to a backend pod,
          # but as far as Envoy is concerned the destination is the
          # ClusterIP, which matches `outbound|80||<service>` cluster —
          # which our force_mtls DestinationRules give an ISTIO_MUTUAL
          # TLS transport_socket. mTLS engages, source SPIFFE arrives at
          # the backend's sidecar, allow-ingress-nginx matches.
          #
          # Tradeoff: NGINX loses per-pod load balancing (kube-proxy does
          # the LB instead) and per-pod session affinity. For low-traffic
          # internal services like this lab's, harmless.
          service-upstream            = "true"
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