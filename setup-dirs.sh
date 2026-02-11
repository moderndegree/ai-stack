#!/usr/bin/env bash
# Creates host directories required by compose.yaml before first run.
# Run as root (or with sudo) since /mnt/data is typically root-owned.
#
# Ownership model for rootless Podman
# ------------------------------------
# In rootless Podman, container uid 0 (root) maps to the host user running
# Podman. All data directories must be owned by that user so Podman can
# bind-mount them. Container images handle their own internal chown in their
# entrypoints before dropping to their service user (postgres, redis, etc.).
#
# On Fedora (SELinux enforcing), this script also pre-applies the
# container_file_t type to each directory. Without this, rootless Podman
# fails to relabel directories it doesn't own when mounting with :Z.

set -euo pipefail

# ── Detect the user who will run Podman ──────────────────────────────────────
# When invoked with sudo, SUDO_USER is the original user.
if [[ -n "${SUDO_USER:-}" ]]; then
  PODMAN_USER="$SUDO_USER"
else
  PODMAN_USER=$(id -un)
fi
PODMAN_UID=$(id -u "$PODMAN_USER")
PODMAN_GID=$(id -g "$PODMAN_USER")

echo "Data directories will be owned by: $PODMAN_USER ($PODMAN_UID:$PODMAN_GID)"
echo ""

# ── Detect SELinux ────────────────────────────────────────────────────────────
SELINUX_ACTIVE=false
if command -v selinuxenabled &>/dev/null && selinuxenabled 2>/dev/null; then
  SELINUX_ACTIVE=true
fi

# ── helpers ──────────────────────────────────────────────────────────────────

make_dir() {
  local dir="$1" mode="${2:-755}"
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir"
    echo "created  $dir"
  else
    echo "exists   $dir"
  fi
  chmod "$mode" "$dir"
  chown "$PODMAN_UID:$PODMAN_GID" "$dir"
  # Pre-label with container_file_t so Podman's :Z mount option can refine the
  # MCS categories even on directories not originally owned by the current user.
  if [[ "$SELINUX_ACTIVE" == true ]]; then
    chcon -t container_file_t "$dir" 2>/dev/null || true
  fi
}

# ── infrastructure ────────────────────────────────────────────────────────────

# Postgres entrypoint chowns $PGDATA to the postgres user internally
make_dir /mnt/data/postgres       700

# Redis entrypoint chowns /data to the redis user internally
make_dir /mnt/data/redis          700

# Qdrant
make_dir /mnt/data/qdrant         755

# ── AI/ML ─────────────────────────────────────────────────────────────────────

make_dir /mnt/data/ollama         755
make_dir /mnt/data/models         755

# ── workflow automation ───────────────────────────────────────────────────────

# n8n + n8n-worker both mount this (uses :z shared label, not :Z)
make_dir /mnt/data/n8n            755

# ── AI web interfaces ─────────────────────────────────────────────────────────

make_dir /mnt/data/open-webui     755
make_dir /mnt/data/documents      755

# ── search ────────────────────────────────────────────────────────────────────

# SearXNG entrypoint chowns /etc/searxng internally
make_dir /mnt/data/searxng        755

# ── object storage ────────────────────────────────────────────────────────────

make_dir /mnt/data/garage/meta    755
make_dir /mnt/data/garage/data    755

# garage config file lives here (bind-mounted as a file, so the dir must exist)
make_dir ./garage                 755

# ── git hosting ───────────────────────────────────────────────────────────────

make_dir /mnt/data/gitea          755

# ── observability ─────────────────────────────────────────────────────────────

# Langfuse postgres — same entrypoint behavior as postgres above
make_dir /mnt/data/langfuse-db    700

# ── agentic workflows ─────────────────────────────────────────────────────────

make_dir /mnt/data/claude-workspaces 755

echo ""
if [[ "$SELINUX_ACTIVE" == true ]]; then
  echo "All directories ready (owned by $PODMAN_USER, container_file_t context applied)."
else
  echo "All directories ready (owned by $PODMAN_USER)."
fi
