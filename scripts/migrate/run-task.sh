#!/usr/bin/env bash
# Run a one-off command inside AWS, as a Fargate task using the web image,
# its database secrets and its permissions, then show its logs.
#
# Used for jobs that must run inside the VPC, next to the private database
# (which can't be reached from your codespace, by design).
#
# Usage:  ./scripts/migrate/run-task.sh python -m app.migrate counts
#
# Extra environment variables for the task (e.g. to point it at a restored
# database during a disaster recovery drill):
#   RUN_TASK_ENV="DB_HOST=docflow-demo-db-drill.xxxx.rds.amazonaws.com" ./scripts/migrate/run-task.sh ...
set -euo pipefail
export AWS_PAGER=""

[ $# -gt 0 ] || { echo "Usage: $0 <command...>"; exit 2; }

TF="terraform -chdir=$(dirname "$0")/../../infra"
CLUSTER=$($TF output -raw ecs_cluster)
FAMILY=$($TF output -raw web_task_family)
SUBNETS=$($TF output -raw public_subnet_ids_csv)
SG=$($TF output -raw app_security_group_id)
OVERRIDES=$(RUN_TASK_ENV="${RUN_TASK_ENV:-}" python3 -c '
import json, os, sys
env = [dict(zip(("name", "value"), pair.split("=", 1))) for pair in os.environ["RUN_TASK_ENV"].split()]
override = {"name": "web", "command": sys.argv[1:]}
if env:
    override["environment"] = env
print(json.dumps({"containerOverrides": [override]}))' "$@")

echo "Starting one-off task: $*" >&2
TASK_ARN=$(aws ecs run-task \
  --cluster "$CLUSTER" \
  --task-definition "$FAMILY" \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SG],assignPublicIp=ENABLED}" \
  --overrides "$OVERRIDES" \
  --query 'tasks[0].taskArn' --output text)
TASK_ID="${TASK_ARN##*/}"

echo "Task $TASK_ID started; waiting for it to finish (usually 1-2 minutes)..." >&2
aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$TASK_ARN"

EXIT_CODE=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" \
  --query 'tasks[0].containers[?name==`web`].exitCode | [0]' --output text)

echo "--- task output ---" >&2
aws logs get-log-events \
  --log-group-name "/ecs/$CLUSTER/web" \
  --log-stream-name "web/web/$TASK_ID" \
  --start-from-head --output json \
  | python3 -c 'import json, sys; [print(e["message"]) for e in json.load(sys.stdin)["events"]]'

if [ "$EXIT_CODE" != "0" ]; then
  REASON=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" --query 'tasks[0].stoppedReason' --output text)
  echo "Task failed (exit code: $EXIT_CODE, reason: $REASON)" >&2
  exit 1
fi
