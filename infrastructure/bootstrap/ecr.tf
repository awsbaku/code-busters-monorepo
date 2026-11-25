# ---------------------------------------------------------------------------
# The container registry lives in the bootstrap, not in a phase.
#
# Reason: phase 3 creates the ECS service, and a service whose image is not in
# ECR fails its deployment circuit breaker. By creating the repository here and
# pushing a seed image once (see ../../docs/BOOTSTRAP.md), the service comes up
# healthy the first time it is created, in front of an audience.
#
# The application pipeline then replaces that seed image with commit-tagged
# builds. Nothing after the bootstrap ever pushes the "seed" tag again.
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "this" {
  name                 = local.name
  image_tag_mutability = "IMMUTABLE" # a tag, once pushed, always means the same image

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name = local.name
  }
}

# Images are tagged with commit SHAs, so they accumulate without this.
resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 10 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
