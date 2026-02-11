#!/bin/sh
set -e

# Generate ~/.claude/claude.json with MCP server definitions from env vars.
# This runs every startup so config always reflects current environment.
node /app/generate-mcp-config.js

exec node /app/server.js
