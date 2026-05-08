resource "aws_ecr_repository" "rag_service" {
  name                 = "rag-service"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "rag_service" {
  repository = aws_ecr_repository.rag_service.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images, expire older untagged/tagged"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = {
        type = "expire"
      }
    }]
  })
}

output "rag_service_ecr_url" {
  value       = aws_ecr_repository.rag_service.repository_url
  description = "Use for docker tag / docker push"
}
