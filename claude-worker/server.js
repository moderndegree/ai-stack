'use strict';

const express = require('express');
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const { randomUUID } = require('crypto');

// LangFuse is optional — tracing degrades gracefully if keys are absent
let langfuse = null;
if (process.env.LANGFUSE_PUBLIC_KEY && process.env.LANGFUSE_SECRET_KEY) {
  const { Langfuse } = require('langfuse');
  langfuse = new Langfuse({
    publicKey: process.env.LANGFUSE_PUBLIC_KEY,
    secretKey: process.env.LANGFUSE_SECRET_KEY,
    baseUrl: process.env.LANGFUSE_BASE_URL || 'http://langfuse:3000',
  });
  console.log('LangFuse tracing enabled');
}

const app = express();
app.use(express.json({ limit: '10mb' }));

const WORKSPACES_DIR = process.env.WORKSPACES_DIR || '/workspaces';
const DEFAULT_MAX_ITERATIONS = parseInt(process.env.DEFAULT_MAX_ITERATIONS || '20', 10);
const DEFAULT_COMPLETION_PROMISE = process.env.DEFAULT_COMPLETION_PROMISE || 'RALPH_COMPLETE';

// In-memory task registry. Each value:
// { status, workspace, iterations, maxIterations, completionPromise, output, error, startedAt, finishedAt }
const tasks = new Map();

// ── Routes ────────────────────────────────────────────────────────────────────

// Submit a new Ralph loop task
app.post('/tasks', (req, res) => {
  const {
    prompt,
    max_iterations = DEFAULT_MAX_ITERATIONS,
    completion_promise = DEFAULT_COMPLETION_PROMISE,
    // Optional: caller-supplied workspace id for idempotency / file sharing
    workspace_id,
  } = req.body;

  if (!prompt || typeof prompt !== 'string') {
    return res.status(400).json({ error: '`prompt` is required and must be a string' });
  }

  // Sanitize workspace_id: only allow alphanumeric, hyphens, and underscores
  const rawId = workspace_id || randomUUID();
  if (!/^[a-zA-Z0-9_-]+$/.test(rawId)) {
    return res.status(400).json({ error: '`workspace_id` may only contain letters, numbers, hyphens, and underscores' });
  }
  const taskId = rawId;
  const workspace = path.join(WORKSPACES_DIR, taskId);

  fs.mkdirSync(workspace, { recursive: true });

  // Write the invariant prompt. Claude reads this each iteration along with
  // whatever files already exist in the workspace.
  fs.writeFileSync(path.join(workspace, 'PROMPT.md'), prompt, 'utf8');

  const task = {
    status: 'running',
    workspace,
    iterations: 0,
    maxIterations: max_iterations,
    completionPromise: completion_promise,
    output: null,
    error: null,
    startedAt: new Date().toISOString(),
    finishedAt: null,
  };

  tasks.set(taskId, task);

  // Fire-and-forget: the loop runs async, caller polls /tasks/:id
  runRalphLoop(taskId).catch((err) => {
    const t = tasks.get(taskId);
    if (t) {
      t.status = 'error';
      t.error = err.message;
      t.finishedAt = new Date().toISOString();
    }
  });

  res.status(202).json({ task_id: taskId, status: 'running', workspace });
});

// Poll task status
app.get('/tasks/:id', (req, res) => {
  const task = tasks.get(req.params.id);
  if (!task) return res.status(404).json({ error: 'Task not found' });
  // Exclude internal bookkeeping fields from the public response
  const { _cancel, ...pub } = task;
  res.json({ task_id: req.params.id, ...pub });
});

// List all tasks (useful for n8n workflows that enumerate work)
app.get('/tasks', (_req, res) => {
  const list = [];
  for (const [id, task] of tasks.entries()) {
    list.push({ task_id: id, status: task.status, iterations: task.iterations, startedAt: task.startedAt });
  }
  res.json(list);
});

// Cancel a running task (sets a cancellation flag; loop checks it between iterations)
app.delete('/tasks/:id', (req, res) => {
  const task = tasks.get(req.params.id);
  if (!task) return res.status(404).json({ error: 'Task not found' });
  if (task.status !== 'running') {
    return res.status(409).json({ error: `Task is already ${task.status}` });
  }
  task._cancel = true;
  res.json({ task_id: req.params.id, status: 'cancelling' });
});

// Read a specific iteration log
app.get('/tasks/:id/logs/:iter', (req, res) => {
  const task = tasks.get(req.params.id);
  if (!task) return res.status(404).json({ error: 'Task not found' });

  const iterNum = String(req.params.iter).padStart(3, '0');
  const logPath = path.join(task.workspace, `iter_${iterNum}.log`);

  if (!fs.existsSync(logPath)) {
    return res.status(404).json({ error: 'Iteration log not found' });
  }

  res.type('text/plain').send(fs.readFileSync(logPath, 'utf8'));
});

// ── Ralph loop ────────────────────────────────────────────────────────────────

async function runRalphLoop(taskId) {
  const task = tasks.get(taskId);
  const prompt = fs.readFileSync(path.join(task.workspace, 'PROMPT.md'), 'utf8');

  // One LangFuse trace per task — spans added per iteration
  const trace = langfuse?.trace({
    id: taskId,
    name: 'ralph-loop',
    input: { prompt, maxIterations: task.maxIterations },
    metadata: { workspace: task.workspace },
  });

  for (let i = 0; i < task.maxIterations; i++) {
    if (task._cancel) {
      task.status = 'cancelled';
      task.finishedAt = new Date().toISOString();
      trace?.update({ output: { status: 'cancelled', iterations: i } });
      await langfuse?.flushAsync();
      return;
    }

    task.iterations = i + 1;

    const span = trace?.span({ name: `iteration-${i + 1}`, input: { iteration: i + 1 } });

    // Each call spawns a completely fresh claude process.
    // No shared context between iterations — state lives in the workspace files.
    const output = await runClaude(task.workspace);

    span?.end({ output: { text: output.slice(0, 2000) } }); // truncate for LangFuse storage

    // Write iteration output so Claude can introspect its own history next round
    const logFile = path.join(task.workspace, `iter_${String(i).padStart(3, '0')}.log`);
    fs.writeFileSync(logFile, output, 'utf8');

    // Append to the rolling summary log
    fs.appendFileSync(
      path.join(task.workspace, 'ralph.log'),
      `\n\n=== Iteration ${i + 1} / ${task.maxIterations} ===\n${output}\n`,
      'utf8',
    );

    if (output.includes(task.completionPromise)) {
      task.status = 'complete';
      task.output = output;
      task.finishedAt = new Date().toISOString();
      trace?.update({ output: { status: 'complete', iterations: i + 1 } });
      await langfuse?.flushAsync();
      return;
    }
  }

  task.status = 'max_iterations_reached';
  task.finishedAt = new Date().toISOString();
  trace?.update({ output: { status: 'max_iterations_reached', iterations: task.maxIterations } });
  await langfuse?.flushAsync();
}

// ── Claude invocation ─────────────────────────────────────────────────────────

const CLAUDE_TIMEOUT_MS = parseInt(process.env.CLAUDE_TIMEOUT_MS || String(10 * 60 * 1000), 10);

function runClaude(workspace) {
  return new Promise((resolve, reject) => {
    const prompt = fs.readFileSync(path.join(workspace, 'PROMPT.md'), 'utf8');

    // Fresh process = fresh context window every time.
    // --dangerously-skip-permissions: unattended container operation.
    // cwd set to workspace so Claude's relative file operations land here.
    const proc = spawn(
      'claude',
      ['--print', '--dangerously-skip-permissions'],
      {
        cwd: workspace,
        env: { ...process.env },
        stdio: ['pipe', 'pipe', 'pipe'],
      },
    );

    proc.stdin.write(prompt);
    proc.stdin.end();

    const chunks = [];
    proc.stdout.on('data', (d) => chunks.push(d));
    proc.stderr.on('data', (d) => chunks.push(d));

    const timer = setTimeout(() => {
      proc.kill('SIGTERM');
      reject(new Error(`claude process timed out after ${CLAUDE_TIMEOUT_MS}ms`));
    }, CLAUDE_TIMEOUT_MS);

    proc.on('close', () => {
      clearTimeout(timer);
      resolve(Buffer.concat(chunks).toString('utf8'));
    });

    proc.on('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
  });
}

// ── Boot ─────────────────────────────────────────────────────────────────────

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`claude-worker listening on :${PORT}`);
  console.log(`workspaces: ${WORKSPACES_DIR}`);
  console.log(`default max iterations: ${DEFAULT_MAX_ITERATIONS}`);
});
