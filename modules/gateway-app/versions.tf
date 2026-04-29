# Module needs the same kubectl provider version as the root module.
# Using a version constraint (rather than pinning) so the parent
# selects; the module just declares "I need this provider".
terraform {
  required_providers {
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
  }
}
