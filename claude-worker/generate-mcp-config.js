'use strict';

// Generates ~/.claude/claude.json from environment variables at container startup.
// Claude Code reads this file to discover available MCP tool servers.
// Each server is a subprocess spawned per-session — no persistent connection.

const fs = require('fs');
const os = require('os');
const path = require('path');

const configDir = path.join(os.homedir(), '.claude');
const configPath = path.join(configDir, 'settings.json');

fs.mkdirSync(configDir, { recursive: true });

const servers = {};

// Postgres — gives Claude direct SQL query capability
if (process.env.MCP_POSTGRES_URL) {
  servers.postgres = {
    command: 'npx',
    args: ['-y', '@modelcontextprotocol/server-postgres', process.env.MCP_POSTGRES_URL],
  };
}

// Filesystem — scoped to the workspaces volume
// Claude can read/write files here without shell escapes
if (process.env.MCP_FILESYSTEM_ROOT) {
  servers.filesystem = {
    command: 'npx',
    args: ['-y', '@modelcontextprotocol/server-filesystem', process.env.MCP_FILESYSTEM_ROOT],
  };
}

// Fetch — lets Claude retrieve URLs during a task (web research, API calls)
// Uses the official Python-based server via uvx
servers.fetch = {
  command: 'uvx',
  args: ['mcp-server-fetch'],
};

const config = { mcpServers: servers };
fs.writeFileSync(configPath, JSON.stringify(config, null, 2), 'utf8');

console.log(`MCP config written: ${Object.keys(servers).join(', ')}`);
