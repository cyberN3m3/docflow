#!/usr/bin/env bash
# End-to-end test against a running DocFlow stack (real Gotenberg, real worker).
# Usage:  docker compose up -d --build && ./scripts/e2e.sh [base_url]
set -euo pipefail

BASE="${1:-http://localhost}"
WORK=$(mktemp -d)
JAR="$WORK/cookies"
trap 'rm -rf "$WORK"' EXIT

say() { printf '\n==> %s\n' "$*"; }

say "Waiting for $BASE/healthz"
for i in $(seq 1 60); do
  if curl -fs "$BASE/healthz" >/dev/null; then break; fi
  [ "$i" -eq 60 ] && { echo "App never became healthy"; exit 1; }
  sleep 5
done
curl -fs "$BASE/healthz"; echo

say "Registering a test user"
EMAIL="e2e-$(date +%s)@example.com"
curl -fs -c "$JAR" -b "$JAR" -o /dev/null -X POST \
  --data-urlencode "email=$EMAIL" --data-urlencode "password=password123" "$BASE/register"

latest_job_id() {
  curl -fs -b "$JAR" "$BASE/dashboard" | grep -o 'data-job="[^"]*"' | head -1 | cut -d'"' -f2
}

wait_for_job() {
  local id=$1 status
  for i in $(seq 1 60); do
    status=$(curl -fs -b "$JAR" "$BASE/jobs/$id/status" | python3 -c 'import sys, json; print(json.load(sys.stdin)["status"])')
    case "$status" in
      done) echo "job $id: done"; return 0 ;;
      failed) echo "job $id FAILED:"; curl -fs -b "$JAR" "$BASE/jobs/$id/status"; echo; return 1 ;;
    esac
    sleep 2
  done
  echo "job $id timed out (last status: $status)"; return 1
}

check_pdf() {
  local file=$1
  if [ "$(head -c 5 "$file")" != "%PDF-" ]; then
    echo "$file is not a PDF"; head -c 200 "$file"; exit 1
  fi
  echo "$file is a valid PDF ($(wc -c < "$file") bytes)"
}

say "Converting a text file to PDF"
printf 'Hello from the DocFlow end-to-end test.\n' > "$WORK/hello.txt"
curl -fs -c "$JAR" -b "$JAR" -o /dev/null -F "file=@$WORK/hello.txt" "$BASE/convert"
JOB1=$(latest_job_id)
wait_for_job "$JOB1"
curl -fs -b "$JAR" -o "$WORK/one.pdf" "$BASE/jobs/$JOB1/download"
check_pdf "$WORK/one.pdf"

say "Converting a second file"
printf 'Second page.\n' > "$WORK/second.txt"
curl -fs -c "$JAR" -b "$JAR" -o /dev/null -F "file=@$WORK/second.txt" "$BASE/convert"
JOB2=$(latest_job_id)
wait_for_job "$JOB2"
curl -fs -b "$JAR" -o "$WORK/two.pdf" "$BASE/jobs/$JOB2/download"
check_pdf "$WORK/two.pdf"

say "Merging the two PDFs"
curl -fs -c "$JAR" -b "$JAR" -o /dev/null \
  -F "files=@$WORK/one.pdf" -F "files=@$WORK/two.pdf" "$BASE/merge"
JOB3=$(latest_job_id)
wait_for_job "$JOB3"
curl -fs -b "$JAR" -o "$WORK/merged.pdf" "$BASE/jobs/$JOB3/download"
check_pdf "$WORK/merged.pdf"

say "All end-to-end checks passed"
