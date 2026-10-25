#!/usr/bin/env bash
# Disaster recovery drill 2: "a user's file was deleted by mistake".
#
# Uploads a test file to the files bucket, deletes it, then recovers it from
# S3 versioning and proves the content is identical. Cleans up afterwards.
#
# Usage:  ./scripts/dr/s3-recovery-drill.sh        (under a minute)
set -euo pipefail
export AWS_PAGER=""
cd "$(dirname "$0")/../.."

BUCKET=$(terraform -chdir=infra output -raw files_bucket)
KEY="dr-drill/$(date -u +%Y%m%dT%H%M%SZ).txt"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p dr-reports

echo "DocFlow DR drill $(date -u) $RANDOM" > "$WORK/original.txt"
ORIGINAL_SHA=$(sha256sum "$WORK/original.txt" | cut -d' ' -f1)

echo "== 1. Upload a test file: s3://$BUCKET/$KEY"
aws s3 cp --quiet "$WORK/original.txt" "s3://$BUCKET/$KEY"

echo "== 2. Delete it (simulating the accident)"
aws s3 rm --quiet "s3://$BUCKET/$KEY"
if aws s3api head-object --bucket "$BUCKET" --key "$KEY" >/dev/null 2>&1; then
  echo "File still visible after delete?"; exit 1
fi
echo "File is gone for the app (S3 now returns 404)."

echo "== 3. Recover it"
START=$(date -u +%s)
MARKER=$(aws s3api list-object-versions --bucket "$BUCKET" --prefix "$KEY" \
  --query 'DeleteMarkers[?IsLatest].VersionId | [0]' --output text)
# Removing the "delete marker" brings the previous version back.
aws s3api delete-object --bucket "$BUCKET" --key "$KEY" --version-id "$MARKER" >/dev/null
aws s3 cp --quiet "s3://$BUCKET/$KEY" "$WORK/recovered.txt"
END=$(date -u +%s)

RECOVERED_SHA=$(sha256sum "$WORK/recovered.txt" | cut -d' ' -f1)

echo "== 4. Clean up the test file (all versions)"
aws s3api list-object-versions --bucket "$BUCKET" --prefix "$KEY" \
  --query 'Versions[].VersionId' --output text | tr '\t' '\n' | while read -r v; do
  [ -n "$v" ] && [ "$v" != "None" ] && aws s3api delete-object --bucket "$BUCKET" --key "$KEY" --version-id "$v" >/dev/null
done

{
  echo "Original SHA-256:  $ORIGINAL_SHA"
  echo "Recovered SHA-256: $RECOVERED_SHA"
  echo "Recovery time:     $((END - START)) s"
  if [ "$ORIGINAL_SHA" = "$RECOVERED_SHA" ]; then
    echo "DR DRILL PASSED: the deleted file was recovered byte for byte."
  else
    echo "DR DRILL FAILED: recovered content differs."; exit 1
  fi
} | tee dr-reports/s3-drill-result.txt
