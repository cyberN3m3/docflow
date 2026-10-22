# Container registry for DocFlow images. Lives in the bootstrap layer so
# images survive the daily destroy of the main environment.
resource "aws_ecr_repository" "app" {
  name = "docflow"

  # A pushed tag (e.g. a Git commit hash) can never be overwritten.
  image_tag_mutability = "IMMUTABLE"

  # Scan every pushed image for known vulnerabilities.
  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# Keep only the 10 most recent images so storage stays cheap.
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 10 images"
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
