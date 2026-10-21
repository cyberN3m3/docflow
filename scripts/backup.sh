#!/usr/bin/env bash
# LEGACY "backup strategy": someone has to remember to run this by hand,
# and the backup lands on the same server it's protecting.
set -euo pipefail

cd "$(dirname "$0")/.."
source .env

STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p backups

echo "Dumping database..."
docker compose exec -T postgres pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom > "backups/db-$STAMP.dump"

echo "Archiving uploads..."
docker compose exec -T web tar -czf - -C /data uploads > "backups/uploads-$STAMP.tar.gz"

echo "Done: backups/db-$STAMP.dump and backups/uploads-$STAMP.tar.gz"
