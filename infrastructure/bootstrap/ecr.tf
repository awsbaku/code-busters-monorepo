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
#
# The obvious single rule — tagStatus "any", keep the 10 newest — ate the seed
# image. Every pipeline deploy pushes THREE artifacts, not one: the image plus
# two untagged attestation manifests from buildx. Four deploys is twelve
# images, and the oldest thing in the repository is the seed, which is the one
# image the demo cannot lose.
#
# So: sweep the untagged attestations on their own, and count only tagged
# images for the cap.
resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged attestation manifests after a day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the 20 most recent tagged images"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = 20
        }
        action = { type = "expire" }
      },
    ]
  })
}
