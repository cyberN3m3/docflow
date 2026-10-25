#!/usr/bin/env bash
# Audit the AWS account with Prowler (open-source CSPM) and print a score.
# Run it twice: once before the Phase 8 hardening and once after, to get a
# before/after comparison.
#
# Usage:  ./scripts/security/prowler-scan.sh before
#         ./scripts/security/prowler-scan.sh after
#         ./scripts/security/prowler-scan.sh before --report-only   (re-print the summary, no new scan)
#
# Reports go to security-reports/ (git-ignored: they describe your account).
# Takes 10-30 minutes. Read-only: Prowler never changes anything.
set -euo pipefail
export AWS_PAGER=""

LABEL="${1:?Usage: $0 before|after [--report-only]}"
REPORT_ONLY="${2:-}"
PROFILE="${AWS_PROFILE:-docflow}"
REGION="${AWS_REGION:-us-east-1}"
OUT="$(dirname "$0")/../../security-reports"
mkdir -p "$OUT"

if [ "$REPORT_ONLY" != "--report-only" ]; then
if ! command -v prowler >/dev/null; then
  echo "Installing Prowler (one time, about a minute)..."
  pip install --quiet prowler
fi

aws sts get-caller-identity --profile "$PROFILE" >/dev/null \
  || { echo "Not signed in. Run: aws sso login --profile $PROFILE --use-device-code"; exit 1; }

echo "Scanning account with profile '$PROFILE' in $REGION (plus global services)..."
# Prowler exits with code 3 when it finds failed checks; that is expected.
prowler aws --profile "$PROFILE" -f "$REGION" \
  -M csv html -o "$OUT" -F "docflow-$LABEL" --no-banner || [ $? -eq 3 ]
fi

python3 - "$OUT" "$LABEL" <<'PY'
import csv, glob, os, sys
from collections import Counter

out, label = sys.argv[1], sys.argv[2]

csv.field_size_limit(10_000_000)

def read(path):
    with open(path, newline="", encoding="utf-8") as f:
        header = f.readline(); f.seek(0)
        # Prowler writes ";"-separated files; pick whichever separator the header uses most.
        delimiter = ";" if header.count(";") >= header.count(",") else ","
        return list(csv.DictReader(f, delimiter=delimiter))

def score(rows):
    status = Counter(r.get("STATUS", "").upper() for r in rows
                     if r.get("MUTED", "False").lower() != "true")
    passed, failed = status.get("PASS", 0), status.get("FAIL", 0)
    pct = 100 * passed / (passed + failed) if passed + failed else 0
    return passed, failed, pct

rows = read(os.path.join(out, f"docflow-{label}.csv"))
p, f, pct = score(rows)
print(f"\n=== Prowler result: {label} ===")
print(f"All checks:   {p} passed, {f} failed  ->  {pct:.1f}% passing")

sev = Counter(r.get("SEVERITY", "?").lower() for r in rows if r.get("STATUS", "").upper() == "FAIL")
print("Failed by severity: " + ", ".join(f"{k} {sev[k]}" for k in ["critical", "high", "medium", "low"] if sev[k]))

def version(path):
    v = os.path.basename(path).split("_cis_")[1].split("_")[0]
    return [int(x) if x.isdigit() else 0 for x in v.split(".")]

cis = sorted(glob.glob(os.path.join(out, "compliance", f"docflow-{label}_cis_*_aws.csv")), key=version)
if cis:
    p, f, pct = score(read(cis[-1]))
    name = os.path.basename(cis[-1]).replace(f"docflow-{label}_", "").replace(".csv", "")
    print(f"CIS benchmark ({name}): {p} passed, {f} failed  ->  {pct:.1f}% passing")

top = Counter(r.get("CHECK_ID") for r in rows if r.get("STATUS", "").upper() == "FAIL"
              and r.get("SEVERITY", "").lower() in ("critical", "high"))
if top:
    print("\nCritical/high failures:")
    for check, n in top.most_common(15):
        print(f"  {check}  ({n})")
print(f"\nFull HTML report: {out}/docflow-{label}.html  (right-click > Download)")
PY
