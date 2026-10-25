#!/usr/bin/env bash
# Disaster recovery drill 1: "the database is corrupted or someone deleted data".
#
# Restores the production database to the latest restorable second (point-in-
# time recovery) as a NEW instance, proves the restored copy holds the same
# data, reports RPO and RTO, then deletes the copy. Production is never touched.
#
# Usage:  ./scripts/dr/db-restore-drill.sh        (about 15-25 minutes)
set -euo pipefail
export AWS_PAGER=""
cd "$(dirname "$0")/../.."

TF="terraform -chdir=infra"
SRC=$($TF output -raw db_identifier)
DRILL="${SRC}-drill"
OUT=dr-reports
mkdir -p "$OUT"

cleanup() {
  if aws rds describe-db-instances --db-instance-identifier "$DRILL" >/dev/null 2>&1; then
    echo "Deleting the drill copy $DRILL (takes 5-10 minutes; terraform destroy needs it gone)..."
    aws rds delete-db-instance --db-instance-identifier "$DRILL" \
      --skip-final-snapshot --delete-automated-backups >/dev/null 2>&1 || true
    aws rds wait db-instance-deleted --db-instance-identifier "$DRILL"
    echo "Drill copy deleted."
  fi
}
trap cleanup EXIT

echo "== 1. Counting the data in production ($SRC)"
./scripts/migrate/run-task.sh python -m app.migrate counts > "$OUT/db-prod-counts.txt"

LATEST=$(aws rds describe-db-instances --db-instance-identifier "$SRC" \
  --query 'DBInstances[0].LatestRestorableTime' --output text)
[ "$LATEST" != "None" ] || { echo "No restorable time yet: the first backup takes ~5 minutes after the database is created. Try again shortly."; exit 1; }
RPO=$(( $(date -u +%s) - $(date -u -d "$LATEST" +%s) ))
echo "Latest restorable time: $LATEST (data written in the last ${RPO}s would be lost = RPO)"

echo "== 2. Restoring to a new instance: $DRILL"
START=$(date -u +%s)
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier "$SRC" \
  --target-db-instance-identifier "$DRILL" \
  --use-latest-restorable-time \
  --db-instance-class db.t4g.micro \
  --db-subnet-group-name "$($TF output -raw db_subnet_group)" \
  --vpc-security-group-ids "$($TF output -raw db_security_group_id)" \
  --db-parameter-group-name "$($TF output -raw db_parameter_group)" \
  --no-publicly-accessible --no-multi-az \
  --tags Key=Project,Value=docflow Key=Purpose,Value=dr-drill >/dev/null
echo "Restore started; waiting for the new instance to be available (usually 10-20 minutes)..."
aws rds wait db-instance-available --db-instance-identifier "$DRILL"
RESTORED=$(date -u +%s)
HOST=$(aws rds describe-db-instances --db-instance-identifier "$DRILL" \
  --query 'DBInstances[0].Endpoint.Address' --output text)

echo "== 3. Counting the data in the restored copy"
RUN_TASK_ENV="DB_HOST=$HOST" ./scripts/migrate/run-task.sh python -m app.migrate counts > "$OUT/db-drill-counts.txt"
VERIFIED=$(date -u +%s)

echo "== 4. Comparing"
python3 - "$OUT/db-prod-counts.txt" "$OUT/db-drill-counts.txt" "$RPO" $((RESTORED - START)) $((VERIFIED - START)) <<'PY' | tee "$OUT/db-drill-result.txt"
import json, sys
def counts(path):
    for line in open(path):
        if line.startswith("COUNTS "):
            return json.loads(line[len("COUNTS "):])
    sys.exit(f"No COUNTS line in {path}")
prod, drill = counts(sys.argv[1]), counts(sys.argv[2])
rpo, restore, total = (int(x) for x in sys.argv[3:6])
ok = True
print(f"{'check':<26}{'production':>12}{'restored':>12}  result")
for key in sorted(set(prod) | set(drill)):
    a, b = prod.get(key), drill.get(key)
    ok &= a == b
    show = lambda v: f"{len(v)} items" if isinstance(v, list) else str(v)
    print(f"{key:<26}{show(a):>12}{show(b):>12}  {'OK' if a == b else 'MISMATCH'}")
print(f"\nRPO (data at risk):          {rpo} s")
print(f"Database restore time:       {restore // 60} min {restore % 60} s")
print(f"RTO (restore + verification): {total // 60} min {total % 60} s")
if ok:
    print("\nDR DRILL PASSED: the restored database holds the same data.")
else:
    print("\nDR DRILL: MISMATCH. If data was written in the last few minutes, it may be newer")
    print("than the latest restorable time (that gap is the RPO). Wait 10 minutes and re-run.")
sys.exit(0 if ok else 1)
PY
