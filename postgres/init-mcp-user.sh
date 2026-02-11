#!/usr/bin/env bash
# Creates a read-only 'mcp_readonly' user for the Claude MCP postgres tool.
# This script runs automatically on first container start (empty data dir).
# It runs as the postgres superuser against the database named in POSTGRES_DB.
#
# For existing deployments: run manually inside the container:
#   podman exec -it postgres psql -U n8n -d n8n -f /docker-entrypoint-initdb.d/init-mcp-user.sh
# Or connect with psql and paste the SQL block directly.

set -euo pipefail

psql -v ON_ERROR_STOP=1 \
     --username "$POSTGRES_USER" \
     --dbname "$POSTGRES_DB" \
     <<-EOSQL
  CREATE USER mcp_readonly WITH PASSWORD '${MCP_POSTGRES_PASSWORD}';
  GRANT CONNECT ON DATABASE ${POSTGRES_DB} TO mcp_readonly;
  GRANT USAGE ON SCHEMA public TO mcp_readonly;
  -- Grant SELECT on tables that already exist
  GRANT SELECT ON ALL TABLES IN SCHEMA public TO mcp_readonly;
  -- Grant SELECT on tables created in the future by the application user
  ALTER DEFAULT PRIVILEGES FOR ROLE ${POSTGRES_USER} IN SCHEMA public
    GRANT SELECT ON TABLES TO mcp_readonly;
EOSQL

echo "mcp_readonly user created."
