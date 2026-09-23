# Private registry for mirrored images. With no internet egress, ECR (via the
# ecr.api/ecr.dkr endpoints and the S3 gateway) is the only place the cluster
# can pull from. scripts/mirror-image.sh copies public images in.

resource "aws_ecr_repository" "mirror" {
  for_each = var.ecr_repositories

  name = each.key

  # A tag can never be re-pointed to different content, so a deployed tag
  # always means the same bytes. Manifests pin by digest anyway.
  image_tag_mutability = "IMMUTABLE"

  # Dev only: lets `terraform destroy` remove repositories that still hold
  # images. Production would keep the default (false).
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }

  # SSE-KMS with the AWS managed aws/ecr key. A customer managed key would
  # add grant management for ECR without changing who can pull.
  encryption_configuration {
    encryption_type = "KMS"
  }
}

resource "aws_ecr_lifecycle_policy" "mirror" {
  for_each = aws_ecr_repository.mirror

  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the 10 most recent images"
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
