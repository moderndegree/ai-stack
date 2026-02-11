#!/usr/bin/env bash
# Creates host directories required by compose.yaml before first run.
# Run as root (or with sudo) since /mnt/data is typically root-owned.
#
# On Fedora (SELinux enforcing), this script also pre-applies the
# container_file_t context to every directory. Without this, rootless
# Podman fails to relabel directories it doesn't own when mounting
# volumes with the :Z option.

set -euo pipefail

# ── helpers ──────────────────────────────────────────────────────────────────

# Detect whether SELinux is available and enforcing
SELINUX_ACTIVE=false
if command -v selinuxenabled &>/dev/null && selinuxenabled 2>/dev/null; then
  SELINUX_ACTIVE=true
fi

make_dir() {
  local dir="$1" mode="${2:-755}" owner="${3:-}"
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir"
    echo "created  $dir"
  else
    echo "exists   $dir"
  fi
  chmod "$mode" "$dir"
  [[ -n "$owner" ]] && chown "$owner" "$dir"
  # Pre-label with container_file_t so rootless Podman's :Z mount option
  # doesn't fail on directories owned by root or other non-current UIDs.
  if [[ "$SELINUX_ACTIVE" == true ]]; then
    chcon -t container_file_t "$dir" 2>/dev/null || true
  fi
}

# ── infrastructure ────────────────────────────────────────────────────────────

# postgres — container runs as uid 999 (postgres)
make_dir /mnt/data/postgres       700 "999:999"

# redis — container runs as uid 999 (redis)
make_dir /mnt/data/redis          700 "999:999"

# qdrant — container runs as uid 1000 (qdrant)
make_dir /mnt/data/qdrant         755 "1000:1000"

# ── AI/ML ─────────────────────────────────────────────────────────────────────

# ollama — container runs as root
make_dir /mnt/data/ollama         755 "root:root"

# shared model cache
make_dir /mnt/data/models         755 "root:root"

# ── workflow automation ───────────────────────────────────────────────────────

# n8n + n8n-worker both mount this; containers run as uid 1000 (node)
make_dir /mnt/data/n8n            755 "1000:1000"

# ── AI web interfaces ─────────────────────────────────────────────────────────

# open-webui — container runs as uid 1000
make_dir /mnt/data/open-webui     755 "1000:1000"

# shared documents directory (open-webui)
make_dir /mnt/data/documents      755 "root:root"

# ── search ────────────────────────────────────────────────────────────────────

# searxng — container runs as uid 977 (searxng)
make_dir /mnt/data/searxng        755 "977:977"

# ── object storage ────────────────────────────────────────────────────────────

# garage meta + data
make_dir /mnt/data/garage/meta    755 "root:root"
make_dir /mnt/data/garage/data    755 "root:root"

# garage config file lives here (bind-mounted as a file, so the dir must exist)
make_dir ./garage                 755 "root:root"

# ── git hosting ───────────────────────────────────────────────────────────────

# gitea — explicitly USER_UID=1000, USER_GID=1000
make_dir /mnt/data/gitea          755 "1000:1000"

# ── observability ─────────────────────────────────────────────────────────────

# langfuse postgres — same image/uid as postgres (999)
make_dir /mnt/data/langfuse-db    700 "999:999"

# ── agentic workflows ─────────────────────────────────────────────────────────

# claude-worker workspaces — custom build; default to root until UID is known
make_dir /mnt/data/claude-workspaces 755 "root:root"

echo ""
if [[ "$SELINUX_ACTIVE" == true ]]; then
  echo "All directories ready (SELinux container_file_t context applied)."
else
  echo "All directories ready."
fi
