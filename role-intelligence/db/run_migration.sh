#!/bin/bash
# Run Phase 1 migration against Neon database.
# Usage: DATABASE_URL="..." ./run_migration.sh
# Or:    ./run_migration.sh  (reads from .env in repo root)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../../.env"

if [ -z "$DATABASE_URL" ]; then
    if [ -f "$ENV_FILE" ]; then
        export $(grep -v '^#' "$ENV_FILE" | xargs)
    else
        echo "ERROR: DATABASE_URL not set and no .env file found at $ENV_FILE"
        exit 1
    fi
fi

echo "Running Phase 1 schema migration..."
psql "$DATABASE_URL" -f "$SCRIPT_DIR/001_phase1_schema.sql"
echo "Migration complete."
