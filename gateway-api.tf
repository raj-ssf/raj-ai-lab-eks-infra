# =============================================================================
# Gateway API CRDs — Phase 3 of Cilium migration.
#
# Cilium's helm flag `gatewayAPI.enabled=true` (set in cilium.tf) installs
# the Cilium Gateway API CONTROLLER but NOT the upstream CRDs themselves.
# Without the CRDs, Cilium has nothing to reconcile — and external-dns
# crashes trying to watch HTTPRoute. This file installs the CRDs.
#
# Channel — EXPERIMENTAL (required by Cilium):
#   Cilium 1.16's gateway-api controller checks for TLSRoute CRD at
#   startup and refuses to register the GatewayClass if it's missing.
#   TLSRoute is in the experimental channel only. experimental-install
#   is a superset of standard-install (same standard CRDs + TLSRoute,
#   TCPRoute, UDPRoute, alpha policies). The standard-channel CRDs
#   themselves are byte-identical between the two manifests, so this
#   doesn't change semantics for HTTPRoute/Gateway/etc.
#
# Version — v1.2.1:
#   Latest stable as of 2026-05. Cilium 1.16.5 supports v1.2.x.
#
# Controller — Cilium (replaces Istio from the old lab):
#   Cilium auto-registers a `cilium` GatewayClass once the CRDs land.
#   HTTPRoutes attach to shared-gateway via parentRefs.sectionName.
# =============================================================================

data "http" "gateway_api_crds" {
  url = "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/experimental-install.yaml"

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

  # CRDs are cluster-scoped. Cilium's gateway controller is already
  # running (gatewayAPI.enabled=true) and starts reconciling once the
  # CRDs appear — no hard ordering with helm_release.cilium needed.
  depends_on = [module.eks]
}
