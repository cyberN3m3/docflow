#!/usr/bin/env bash
# Build the DocFlow image and push it to ECR, tagged with the current Git
# commit hash, so every image can be traced back to the exact code in it.
#
# Usage:  ./scripts/push-image.sh
# Then:   export TF_VAR_image_tag=<the tag it prints>
set -euo pipefail

cd "$(dirname "$0")/.."
REGION="${AWS_REGION:-us-east-1}"

# The tag must describe the code exactly, so refuse to build uncommitted changes.
if [ -n "$(git status --porcelain -- app requirements.txt Dockerfile)" ]; then
  echo "You have uncommitted changes in app/, requirements.txt or Dockerfile."
  echo "Commit them first, so the image tag matches the code inside it."
  exit 1
fi

TAG="$(git rev-parse --short HEAD)"
REPO="$(aws ecr describe-repositories --repository-names docflow --region "$REGION" \
  --query 'repositories[0].repositoryUri' --output text)"

if aws ecr describe-images --repository-name docflow --image-ids imageTag="$TAG" \
  --region "$REGION" >/dev/null 2>&1; then
  echo "Image $REPO:$TAG is already in ECR. Nothing to push."
else
  echo "Logging Docker in to ECR (the login lasts 12 hours)..."
  aws ecr get-login-password --region "$REGION" \
    | docker login --username AWS --password-stdin "${REPO%%/*}"

  echo "Building $REPO:$TAG ..."
  docker build --platform linux/amd64 -t "$REPO:$TAG" .

  echo "Pushing..."
  docker push "$REPO:$TAG"
fi

echo
echo "Done. Tell Terraform which image to run:"
echo "  export TF_VAR_image_tag=$TAG"
