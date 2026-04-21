# Read each service's current image tag from a plain-text file in the app repo.
# The file is updated by the GitHub Actions workflow after a successful build+push.
# Reading via raw.githubusercontent.com — works because the app repo is public.
# Terraform refreshes this data source on every plan, so running `terraform apply`
# after a workflow completes picks up the new SHA tag automatically.

data "http" "rag_service_image_tag" {
  url = "https://raw.githubusercontent.com/${var.gha_repo_owner}/${var.gha_repo_name}/main/rag-service/image.tag"

  request_headers = {
    Accept = "text/plain"
  }

  lifecycle {
    postcondition {
      condition     = contains([200], self.status_code)
      error_message = "Failed to fetch rag-service/image.tag: HTTP ${self.status_code}"
    }
  }
}

locals {
  rag_service_image_tag = trimspace(data.http.rag_service_image_tag.response_body)
}

output "rag_service_deployed_tag" {
  value       = local.rag_service_image_tag
  description = "Tag Terraform will use for rag-service. Matches what's in rag-service/image.tag in the app repo."
}
