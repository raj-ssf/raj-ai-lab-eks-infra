# gateway-app module — wires one application's per-namespace resources
# for attaching to the cluster's shared Istio Gateway.
#
# What this module does NOT manage (lives in the root module):
#   - The Gateway resource itself (one shared singleton)
#   - The Gateway's listener for this app (declared in the listeners
#     list in the root module's locals)
#   - The Gateway's allowedRoutes selector (uses the root module's
#     namespace allowlist)
#
# What this module DOES manage (one set per app):
#   - Cross-namespace ReferenceGrant authorizing the gateway to read
#     the app's TLS Secret
#   - Istio AuthorizationPolicy permitting the gateway pod's SPIFFE
#     principal to reach the app's backend pods

variable "app_name" {
  description = "Logical name of the app — used in TF state addressing only, not in K8s resource names."
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace where the app's Service + cert Secret live."
  type        = string
}

variable "cert_secret_name" {
  description = "Name of the TLS Secret in <namespace> that the Gateway listener will reference. The ReferenceGrant authorizes this specific Secret."
  type        = string
}

variable "gateway_namespace" {
  description = "Namespace where the shared Gateway resource lives. ReferenceGrant.from points here; AuthorizationPolicy.principals references the gateway pod's SA in this namespace."
  type        = string
  default     = "gateway-system"
}

variable "gateway_sa_name" {
  description = "ServiceAccount name of the gateway pod. Istio's gateway controller auto-creates an SA named after the Gateway resource (e.g., shared-gateway-istio for a Gateway named shared-gateway)."
  type        = string
  default     = "shared-gateway-istio"
}
