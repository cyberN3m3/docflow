#!/usr/bin/env bash
# Disaster recovery drill 3: "a server dies".
#
# Kills a running web task and measures how the site behaves while ECS heals
# itself. Run it in two modes to see why running two copies matters:
#
#   ./scripts/dr/task-failure-drill.sh 1   one web task (today's setting): expect a short outage
#   ./scripts/dr/task-failure-drill.sh 2   two web tasks in two AZs: expect no outage
#
# With 1 task, the "site-down" alarm should email you (if alert_email is set).
set -euo pipefail
export AWS_PAGER=""
cd "$(dirname "$0")/../.."

TASKS="${1:?Usage: $0 1|2}"
TF="terraform -chdir=infra"
CLUSTER=$($TF output -raw ecs_cluster)
SERVICE=$($TF output -raw web_service_name)
URL="$($TF output -raw app_url)/healthz"
RESOURCE="service/$CLUSTER/$SERVICE"
mkdir -p dr-reports

set_tasks() {
  # Autoscaling owns the task count, so change its minimum, not the service.
  aws application-autoscaling register-scalable-target --service-namespace ecs \
    --scalable-dimension ecs:service:DesiredCount --resource-id "$RESOURCE" \
    --min-capacity "$1" --max-capacity 3
  aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --desired-count "$1" >/dev/null
  echo "Waiting for $1 healthy web task(s)..."
  aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE"
}

if [ "$TASKS" = "2" ]; then
  set_tasks 2
  trap 'echo "Restoring 1 web task..."; set_tasks 1' EXIT
fi

TASK=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" \
  --desired-status RUNNING --query 'taskArns[0]' --output text)
echo "== Stopping web task ${TASK##*/} (simulating a crash) at $(date -u +%T)"
aws ecs stop-task --cluster "$CLUSTER" --task "$TASK" --reason "DR drill: simulated crash" >/dev/null

START=$(date -u +%s); FAILED=0; FIRST_FAIL=""; LAST_FAIL=""
echo "Checking $URL every 2 seconds for 4 minutes..."
for _ in $(seq 1 120); do
  NOW=$(date -u +%s)
  if curl -fs -m 3 "$URL" >/dev/null; then printf '.'; else
    printf 'X'; FAILED=$((FAILED + 1))
    [ -z "$FIRST_FAIL" ] && FIRST_FAIL=$NOW
    LAST_FAIL=$NOW
  fi
  sleep 2
done
echo

RUNNING=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].runningCount' --output text)
{
  echo "Mode:                $TASKS web task(s)"
  echo "Failed health checks: $FAILED of 120"
  if [ -n "$FIRST_FAIL" ]; then
    echo "Outage window:       about $((LAST_FAIL - FIRST_FAIL + 2)) s (from $((FIRST_FAIL - START)) s after the crash)"
  else
    echo "Outage window:       none: every request succeeded"
  fi
  echo "Running tasks now:   $RUNNING (ECS replaced the stopped task automatically)"
} | tee "dr-reports/task-drill-$TASKS.txt"
