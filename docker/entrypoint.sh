#!/usr/bin/env bash
# ============================================================================
# Podium — a self-updating static-site runner.
#
#   1. Clone REPO_URL on first boot and build it with BUILD_CMD.
#   2. Serve the built output (OUTPUT_DIR) with nginx on PORT.
#   3. Poll the branch forever. When the remote HEAD moves, pull, rebuild,
#      and atomically swap the live site — all without restarting the
#      container or rebuilding the Docker image.
#
# Point it at any GitHub repo via env vars; push to the tracked branch and the
# site updates itself within POLL_INTERVAL seconds. A failed build is logged
# and the previous version stays live.
# ============================================================================
set -euo pipefail

REPO_URL="${REPO_URL:-}"
REPO_BRANCH="${REPO_BRANCH:-main}"
POLL_INTERVAL="${POLL_INTERVAL:-300}"
BUILD_CMD="${BUILD_CMD:-npm ci --no-audit --no-fund && npm run build}"
OUTPUT_DIR="${OUTPUT_DIR:-dist}"
PORT="${PORT:-80}"
SRC_DIR="/app/src-repo"
WEB_ROOT="/usr/share/nginx/html"

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S')Z] $*"; }

if [ -z "$REPO_URL" ]; then
  log "ERROR: REPO_URL is required (the GitHub repo to clone and serve)."
  exit 1
fi

# Run BUILD_CMD (if any), then swap OUTPUT_DIR into the web root only on
# success. Returns non-zero (without touching the live site) if anything
# fails, so a bad commit never takes the site down.
build_and_deploy() {
  if [ -n "$BUILD_CMD" ]; then
    log "Building site: $BUILD_CMD"
    bash -c "$BUILD_CMD" || { log "build failed"; return 1; }
  else
    log "BUILD_CMD empty — skipping build, serving '$OUTPUT_DIR' as-is."
  fi

  if [ ! -d "$OUTPUT_DIR" ]; then
    log "OUTPUT_DIR '$OUTPUT_DIR' does not exist after build"; return 1
  fi

  log "Publishing '$OUTPUT_DIR' to web root..."
  rm -rf "${WEB_ROOT:?}/"*
  cp -r "$OUTPUT_DIR/." "$WEB_ROOT/"
}

# --- First boot: clone + initial build -------------------------------------
if [ ! -d "$SRC_DIR/.git" ]; then
  log "Cloning $REPO_URL (branch: $REPO_BRANCH)..."
  git clone --branch "$REPO_BRANCH" "$REPO_URL" "$SRC_DIR"
fi

cd "$SRC_DIR"
git config --global --add safe.directory "$SRC_DIR"

# A failed *initial* build is fatal — let the container restart policy retry.
build_and_deploy

# Poll the branch in the background and hot-swap the built site into the web
# root. nginx serves straight from disk, so a new build needs no reload or
# restart — the next request just picks up the new files.
#
# This runs as a background job; nginx (below) is the container's main process.
# If nginx ever dies, the container exits and Docker restarts it cleanly — no
# second `nginx` is ever launched while the first still holds the port.
poll_loop() {
  log "Watching '$REPO_BRANCH' every ${POLL_INTERVAL}s for new commits."
  while true; do
    sleep "$POLL_INTERVAL"

    if ! git fetch --quiet origin "$REPO_BRANCH"; then
      log "git fetch failed; will retry next cycle."
      continue
    fi

    local_sha="$(git rev-parse HEAD 2>/dev/null)" || continue
    remote_sha="$(git rev-parse "origin/$REPO_BRANCH" 2>/dev/null)" || continue

    if [ "$local_sha" != "$remote_sha" ]; then
      log "Update detected: ${local_sha:0:7} -> ${remote_sha:0:7}"
      git reset --hard "origin/$REPO_BRANCH"
      if build_and_deploy; then
        log "Site updated to ${remote_sha:0:7}."
      else
        log "Build failed; previous version remains live."
      fi
    fi
  done
}

poll_loop &

# Render the nginx config with the chosen PORT (only ${PORT} is substituted,
# so nginx's own $uri/$host variables are left intact), then run nginx in the
# foreground as the container's main process. tini supervises it directly, so
# its lifetime == the container's lifetime.
envsubst '${PORT}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf
log "Starting nginx on port ${PORT}..."
exec nginx -g 'daemon off;'
