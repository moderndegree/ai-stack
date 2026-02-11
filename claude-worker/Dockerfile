FROM node:22-slim

RUN apt-get update && apt-get install -y \
    git \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code CLI globally
RUN npm install -g @anthropic-ai/claude-code

# Install official MCP servers that Claude Code will use as tools
RUN npm install -g \
    @modelcontextprotocol/server-postgres \
    @modelcontextprotocol/server-filesystem \
    @modelcontextprotocol/server-fetch

# Set up the API server
WORKDIR /app
COPY package.json .
RUN npm install --production

COPY server.js .
COPY generate-mcp-config.js .
COPY entrypoint.sh .
RUN chmod +x entrypoint.sh

# Workspaces live on a mounted volume
ENV WORKSPACES_DIR=/workspaces
RUN mkdir -p /workspaces

EXPOSE 3000

ENTRYPOINT ["./entrypoint.sh"]
