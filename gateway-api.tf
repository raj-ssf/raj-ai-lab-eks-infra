# Gateway API — Phase 0 of the Ingress → Gateway API migration.
#
# This file alone DOES NOT change traffic flow. It only:
#   1. Installs the upstream Gateway API standard-channel CRDs
#      (GatewayClass, Gateway, HTTPRoute, ReferenceGrant, GRPCRoute).
#   2. Lets Istio's istiod (1.24.3 in this lab) auto-register the
#      `istio` GatewayClass once it sees the CRDs.
#
# Apps still serve traffic through ingress-nginx. The migration to
# Gateway API happens app-by-app in subsequent phases by adding
# HTTPRoute resources alongside the existing Ingress, then cutting
# DNS over and removing the Ingress.
#
# Channel choice — STANDARD only:
#   The standard channel ships the 5 CRDs above (HTTP routing only).
#   The experimental channel adds TCPRoute, UDPRoute, TLSRoute, and
#   a few alpha policy types — none of which the lab uses today.
#   When/if we need TCPRoute (e.g., for raw TCP load-balancing of
#   non-HTTP services like a database), swap the URL below to
#   `experimental-install.yaml`.
#
# Version choice — v1.2.0:
#   Latest stable as of Nov 2024 GA; tested-against-Istio matrix is
#   firmer here than on v1.3.x. Bump in a follow-up commit once the
#   migration is complete and we want the latest features.
#
# Controller choice — Istio Gateway API (not ingress-nginx GW mode,
# not Envoy Gateway, not NGINX Gateway Fabric):
#   The lab already runs Istio for east-west AuthZ + mTLS. Adding
#   Istio as the north-south Gateway controller means ZERO new
#   control planes — same Helm chart, same logs, same istioctl
#   debugging vocabulary, same Envoy data plane handling traffic at
#   both ingress and inter-service hops.
#
# Once the CRDs land, run `kubectl get gatewayclass` to confirm
# the `istio` and `istio-remote` GatewayClasses appeared. The
# `istio` class is what HTTPRoutes will reference via parentRefs.

data "http" "gateway_api_crds" {
  url = "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml"

  request_headers = {
    Accept = "application/yaml"
  }
}

data "kubectl_file_documents" "gateway_api_crds" {
  content = data.http.gateway_api_crds.response_body
}

resource "kubectl_manifest" "gateway_api_crds" {
  for_each = data.kubectl_file_documents.gateway_api_crds.manifests

  yaml_body = each.value

  # CRDs are cluster-scoped; istiod's Gateway API discovery is lazy so
  # there's no hard ordering with helm_release.istiod — but we depend
  # on the cluster being up.
  depends_on = [module.eks]
}
