# AI Stack

A self-hosted AI infrastructure platform built on Podman Compose. Combines local LLM inference, workflow automation, agentic task execution, observability, and storage into a single deployable unit.

---

## Architecture

```
                        ┌─────────────────────────────────────────┐
                        │              External Traffic            │
                        └──────────┬───────────────────────────────┘
                                   │ (reverse proxy / Cloudflare)
          ┌────────────────────────┼──────────────────────┐
          │                        │                       │
    ┌─────▼──────┐         ┌───────▼──────┐        ┌──────▼──────┐
    │    n8n     │         │  Open WebUI  │         │ AnythingLLM │
    │  :5678     │         │   :8080      │         │   :3001     │
    └─────┬──────┘         └───────┬──────┘         └──────┬──────┘
          │ orchestrates           │                        │
          │                        └────────────┬───────────┘
          │                                     │ local inference
    ┌─────▼──────────────────┐          ┌───────▼──────┐
    │     claude-worker      │          │    Ollama    │
    │  Ralph Wiggum Loop API │          │   (Vulkan)   │
    │       :3002            │          └──────────────┘
    └─────┬──────────────────┘
          │ spawns fresh processes
          │ (each iteration = clean context window)
          ▼
    claude --print --dangerously-skip-permissions
          │
          │ MCP tools available per session:
          ├── postgres  (direct SQL)
          ├── filesystem (scoped to /workspaces)
          └── fetch     (HTTP requests)

Supporting services:
  PostgreSQL :5432    — n8n workflow state
  Redis      :6379    — n8n job queue
  Qdrant     :6333    — vector embeddings
  Garage     :3900    — S3-compatible artifact storage
  Gitea      :3003    — local git hosting for agent workspaces
  LangFuse   :3004    — LLM observability and trace inspection
  Browserless :3005   — headless Chromium for web automation
  SearXNG    :8082    — private metasearch
```

---

## Services

| Service | Port | Purpose |
|---|---|---|
| n8n | 5678 | Workflow automation and orchestration |
| n8n-worker | — | Queue worker for n8n (no exposed port) |
| open-webui | 8080 | Chat UI for Ollama models |
| anythingllm | 3001 | Document-centric AI interface |
| ollama | — | Local LLM inference with Vulkan/GPU acceleration |
| claude-worker | 3002 | Ralph Wiggum loop API (agentic task executor) |
| searxng | 8082 | Private metasearch engine |
| garage | 3900 | S3-compatible object storage (artifact persistence) |
| gitea | 3003 | Local git server for agent workspaces |
| langfuse | 3004 | LLM trace and cost observability |
| browserless | 3005 | Headless Chrome API for browser automation |
| postgres | 5432 | Relational database (n8n, internal) |
| langfuse-db | — | Dedicated Postgres for LangFuse |
| redis | 6379 | Job queue and cache |
| qdrant | 6333 / 6334 | Vector database |

---

## The Ralph Wiggum Loop

The core agentic pattern. Named after the Simpsons character — persistent, unaware of failure, keeps going.

**Key principle:** each iteration spawns a completely fresh `claude` process. No context accumulates across iterations. The filesystem is the only memory — Claude reads its own previous outputs from the workspace directory to understand where it left off.

```
n8n  →  POST /tasks  →  claude-worker
                              │
                         for i in 0..N:
                           spawn fresh: claude --print --dangerously-skip-permissions
                           stdin ← PROMPT.md          (invariant goal)
                           cwd  ← workspace/          (Claude sees all files)
                           stdout → iter_NNN.log      (persists for next iteration)
                           if output contains completion_promise → done
                              │
n8n  ←  GET /tasks/:id  ←  status: complete | max_iterations_reached | error
```

This resolves context bloat: a 20-iteration loop that would otherwise exhaust a 200k token window instead uses ~10k tokens per iteration, with state carried in files.

### Writing effective prompts for the loop

```markdown
## Goal
[What you want done]

## Success criteria
- [criterion 1 — verifiable, not subjective]
- [criterion 2]

## Instructions
1. Check existing files and iter_*.log files in this workspace first.
2. Assess what is complete and what remains.
3. Do the next logical chunk of work.
4. Run any tests or validators.
5. If ALL criteria are met, output exactly: RALPH_COMPLETE

## Constraints
[Tech stack, limits, style rules, etc.]
```

**Escape hatch:** always include in your prompt what Claude should do if stuck after N iterations:

```
After 15 iterations without completing, document:
- What was attempted
- What is blocking progress
- Suggested next steps
Then output: RALPH_COMPLETE
```

---

## Prerequisites

- Podman with the compose plugin (`podman compose version`)
- GPU with Vulkan support (optional — Ollama falls back to CPU)
- `/mnt/data/` with sufficient disk space for model files and data volumes

---

## Setup

### 1. Clone and configure

```bash
git clone <repo>
cd ai-stack
cp .env.example .env
```

Edit `.env` and fill in every variable. Generate random passwords:

```bash
node -e "console.log(require('crypto').randomBytes(24).toString('base64url'))"
```

For `LANGFUSE_ENCRYPTION_KEY` specifically, you need 64 hex characters:

```bash
node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
```

### 2. Configure Garage

```bash
cp garage/garage.toml.example garage/garage.toml
# Edit garage/garage.toml and replace rpc_secret with a generated 64-char hex string
```

### 3. Start infrastructure first

```bash
podman compose up -d postgres redis qdrant ollama langfuse-db
```

Wait for health checks to pass:

```bash
podman compose ps
```

### 4. Initialize Garage (one-time)

```bash
podman compose up -d garage
bash garage/init.sh
# Copy the printed GARAGE_ACCESS_KEY_ID and GARAGE_SECRET_ACCESS_KEY into .env
```

### 5. Start remaining services

```bash
podman compose up -d
```

### 6. Complete UI-based setup

**LangFuse** — visit `:3004`, create an account and a project, then copy the API keys into `.env`:
```
LANGFUSE_PUBLIC_KEY=pk-lf-...
LANGFUSE_SECRET_KEY=sk-lf-...
```

**Gitea** — visit `:3003`, complete the setup wizard, then go to **Settings → Applications → Generate Token** and paste into `.env`:
```
GITEA_TOKEN=<token>
```

Restart claude-worker to pick up the new keys:

```bash
podman compose restart claude-worker
```

---

## claude-worker API

Base URL: `http://localhost:3002`

### Submit a task

```bash
curl -X POST http://localhost:3002/tasks \
  -H 'Content-Type: application/json' \
  -d '{
    "prompt": "## Goal\nWrite a Python script that...\n\n## Success criteria\n...\n\nOutput RALPH_COMPLETE when done.",
    "max_iterations": 15,
    "completion_promise": "RALPH_COMPLETE",
    "workspace_id": "my-task-001"
  }'
```

Response:
```json
{ "task_id": "my-task-001", "status": "running", "workspace": "/workspaces/my-task-001" }
```

### Poll status

```bash
curl http://localhost:3002/tasks/my-task-001
```

Response fields:
- `status`: `running` | `complete` | `max_iterations_reached` | `cancelled` | `error`
- `iterations`: number of iterations run so far
- `output`: final output text (when `status: complete`)
- `startedAt` / `finishedAt`: ISO timestamps

### Read iteration log

```bash
curl http://localhost:3002/tasks/my-task-001/logs/3   # iteration 3
```

### Cancel

```bash
curl -X DELETE http://localhost:3002/tasks/my-task-001
```

### Environment overrides

| Variable | Default | Description |
|---|---|---|
| `DEFAULT_MAX_ITERATIONS` | `20` | Iterations before giving up |
| `DEFAULT_COMPLETION_PROMISE` | `RALPH_COMPLETE` | String Claude must output to signal completion |
| `CLAUDE_TIMEOUT_MS` | `600000` | Per-iteration process timeout (10 min) |

---

## n8n Integration

### Basic pattern: submit → poll → branch

1. **HTTP Request** node → `POST http://claude-worker:3000/tasks`
2. **Set** node → save `task_id` from response
3. **Wait** node → pause 30s
4. **HTTP Request** node → `GET http://claude-worker:3000/tasks/{{ $json.task_id }}`
5. **IF** node → branch on `status`
   - `complete` → continue with `output`
   - `running` → loop back to step 3
   - anything else → error branch

### Useful workflow patterns

**Git-backed tasks** — create a Gitea repo before submitting, include the repo URL in the prompt, Claude commits its work each iteration. Gitea webhooks can trigger downstream n8n workflows on push.

**Parallel tasks** — submit multiple tasks with different `workspace_id` values, collect all task IDs, poll all in parallel. Each runs in its own isolated workspace.

**Chained tasks** — pass a `workspace_id` from a completed task as input to a new task. Claude inherits all files from the previous run — useful for multi-phase work (plan → implement → test).

---

## MCP Tools Available to Claude

Each Claude process in the loop has access to these Model Context Protocol tool servers:

| Tool | Capability |
|---|---|
| `postgres` | Run SQL queries against the stack database |
| `filesystem` | Read/write files in `/workspaces` |
| `fetch` | Make HTTP requests (internal APIs, web research) |

---

## Storage Layout

All persistent data lives under `/mnt/data/`:

```
/mnt/data/
├── postgres/          — n8n application database
├── langfuse-db/       — LangFuse observability database
├── redis/             — n8n job queue
├── qdrant/            — vector embeddings
├── ollama/            — Ollama configuration
├── models/            — LLM model files (shared with Ollama)
├── n8n/               — n8n workflows and credentials
├── open-webui/        — Open WebUI data
├── anythingllm/       — AnythingLLM storage
├── documents/         — shared document store (open-webui + anythingllm)
├── searxng/           — SearXNG configuration
├── gitea/             — Gitea repositories and data
├── garage/            — Garage S3 metadata and object data
│   ├── meta/
│   └── data/
└── claude-workspaces/ — Ralph loop task workspaces
    └── <task-id>/
        ├── PROMPT.md     — invariant goal (written once by API)
        ├── iter_000.log  — Claude output, iteration 0
        ├── iter_001.log  — Claude output, iteration 1
        ├── ralph.log     — rolling summary of all iterations
        └── ...           — any files Claude creates
```

---

## Directory Structure

```
ai-stack/
├── compose.yaml              — all services
├── .env                      — secrets (gitignored)
├── .env.example              — variable reference (no values)
├── .gitignore
├── README.md
├── claude-worker/
│   ├── Dockerfile
│   ├── package.json
│   ├── server.js             — Ralph loop API
│   ├── generate-mcp-config.js — writes ~/.claude/settings.json at startup
│   └── entrypoint.sh
└── garage/
    ├── garage.toml           — Garage config with RPC secret (gitignored)
    ├── garage.toml.example   — template (committed)
    └── init.sh               — one-time cluster initialization
```

---

## Security Notes

- All secrets live in `.env` (gitignored). Never commit it.
- `garage/garage.toml` contains the cluster RPC secret (gitignored). The `rpc_secret` must never change after the cluster is initialized — doing so will make stored data inaccessible.
- `claude --dangerously-skip-permissions` is intentional for unattended container operation. The blast radius is scoped to the workspace volume and the services reachable from within the pod. Do not expose the claude-worker API to the internet.
- LangFuse, Gitea, and Browserless are internal services. Secure them behind your reverse proxy if exposing externally.
