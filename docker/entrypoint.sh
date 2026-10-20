#!/usr/bin/env bash
# ============================================================================
# Podium — a self-updating, multi-site static-site runner.
#
#   1. Read a list of sites (SITES, a JSON array). For each site:
#        clone its repo, build it, and serve the output with nginx on its
#        own container PORT.
#   2. Poll every site's branch forever. When a remote HEAD moves, pull,
#      rebuild, and atomically swap just that site's live files — no reload,
#      no container restart, no Docker image rebuild.
#
# A single container can therefore serve many independent repos, each on a
# different port. A failed build for one site is logged and that site's
# previous version stays live; the other sites are unaffected.
#
# Declaring sites (SITES, JSON array of objects):
#   [
#     {"repo":"https://github.com/you/app.git","port":8080,
#      "branch":"main","build":"npm ci && npm run build","output":"dist"},
#     {"repo":"https://github.com/you/blog.git","port":8081,
#      "build":"","output":"."}
#   ]
#   Per-object fields: repo (required), port (required, unique),
#   branch (default "main"), build (default npm build; "" skips building),
#   output (default "dist").
#
# Backward compatible: if SITES is unset, a single site is synthesized from
# the legacy REPO_URL / REPO_BRANCH / PORT / BUILD_CMD / OUTPUT_DIR vars.
# ============================================================================
set -euo pipefail

POLL_INTERVAL="${POLL_INTERVAL:-300}"
SITES_DIR="/srv/sites"          # per-site working trees + web roots live here
HTTPD_DIR="/etc/nginx/http.d"   # one generated server-block .conf per site
RUN_DIR="/run/podium"

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S')Z] $*"; }

# --- Resolve the site list -------------------------------------------------
# Prefer SITES (JSON). Fall back to the legacy single-repo env vars so older
# deployments keep working unchanged.
SITES="${SITES:-}"
if [ -z "$SITES" ]; then
  if [ -n "${REPO_URL:-}" ]; then
    log "No SITES set; using legacy single-repo env vars (REPO_URL=...)."
    SITES="$(jq -n \
      --arg repo   "$REPO_URL" \
      --arg branch "${REPO_BRANCH:-main}" \
      --argjson port "${PORT:-80}" \
      --arg build  "${BUILD_CMD:-npm ci --no-audit --no-fund && npm run build}" \
      --arg output "${OUTPUT_DIR:-dist}" \
      '[{repo:$repo,branch:$branch,port:$port,build:$build,output:$output}]')"
  else
    log "ERROR: set SITES (a JSON array of sites) or REPO_URL (single site)."
    exit 1
  fi
fi

if ! echo "$SITES" | jq -e 'type=="array" and length>0' >/dev/null 2>&1; then
  log "ERROR: SITES must be a non-empty JSON array. Got:"
  echo "$SITES" | sed 's/^/    /'
  exit 1
fi

# --- Build + deploy one site (never touches the live files on failure) -----
# Args: <src_dir> <build_cmd> <output_dir> <web_root> <label>
build_and_deploy() {
  local src="$1" build="$2" output="$3" web="$4" label="$5"
  (
    cd "$src"
    if [ -n "$build" ]; then
      log "[$label] building: $build"
      bash -c "$build" || { log "[$label] build failed"; exit 1; }
    else
      log "[$label] BUILD_CMD empty — serving '$output' as-is."
    fi

    if [ ! -d "$output" ]; then
      log "[$label] OUTPUT_DIR '$output' does not exist after build"; exit 1
    fi

    # Stage into a sibling dir, then swap it in so a request never sees a
    # half-copied tree.
    local stage="${web}.new"
    rm -rf "$stage"; mkdir -p "$stage"
    cp -r "$output/." "$stage/"
    rm -rf "${web:?}"; mv "$stage" "$web"
    log "[$label] published to web root."
  )
}

# --- Poll one site's branch forever and hot-swap on new commits ------------
# Args: <src_dir> <branch> <build_cmd> <output_dir> <web_root> <label>
poll_loop() {
  local src="$1" branch="$2" build="$3" output="$4" web="$5" label="$6"
  cd "$src"
  log "[$label] watching '$branch' every ${POLL_INTERVAL}s for new commits."
  while true; do
    sleep "$POLL_INTERVAL"

    if ! git fetch --quiet origin "$branch"; then
      log "[$label] git fetch failed; will retry next cycle."; continue
    fi

    local l r
    l="$(git rev-parse HEAD 2>/dev/null)" || continue
    r="$(git rev-parse "origin/$branch" 2>/dev/null)" || continue

    if [ "$l" != "$r" ]; then
      log "[$label] update detected: ${l:0:7} -> ${r:0:7}"
      git reset --hard "origin/$branch"
      if build_and_deploy "$src" "$build" "$output" "$web" "$label"; then
        log "[$label] updated to ${r:0:7}."
      else
        log "[$label] build failed; previous version remains live."
      fi
    fi
  done
}

# --- Provision every site --------------------------------------------------
mkdir -p "$SITES_DIR" "$HTTPD_DIR" "$RUN_DIR"
rm -f "$HTTPD_DIR"/*.conf

declare -A seen_ports
count="$(echo "$SITES" | jq 'length')"

for i in $(seq 0 $((count - 1))); do
  site="$(echo "$SITES" | jq -c ".[$i]")"
  repo="$(echo "$site"   | jq -r '.repo   // empty')"
  branch="$(echo "$site" | jq -r '.branch // "main"')"
  port="$(echo "$site"   | jq -r '.port   // empty')"
  build="$(echo "$site"  | jq -r '.build  // "npm ci --no-audit --no-fund && npm run build"')"
  output="$(echo "$site" | jq -r '.output // "dist"')"

  if [ -z "$repo" ]; then
    log "ERROR: site #$i is missing a 'repo'."; exit 1
  fi
  if [ -z "$port" ]; then
    log "ERROR: site #$i ($repo) is missing a 'port'."; exit 1
  fi
  if [ -n "${seen_ports[$port]:-}" ]; then
    log "ERROR: port $port is used by more than one site."; exit 1
  fi
  seen_ports[$port]=1

  label="$port:$(basename "$repo" .git)"
  src="$SITES_DIR/$i/src"
  web="$SITES_DIR/$i/web"
  mkdir -p "$(dirname "$src")" "$web"

  if [ ! -d "$src/.git" ]; then
    log "[$label] cloning $repo (branch: $branch)..."
    git clone --branch "$branch" "$repo" "$src"
  fi
  git config --global --add safe.directory "$src"

  # Initial build. Non-fatal per site: log and keep going so one bad repo
  # doesn't stop the others from coming up. The poll loop retries on the
  # next commit.
  if ! build_and_deploy "$src" "$build" "$output" "$web" "$label"; then
    log "[$label] initial build failed; this site serves nothing until it builds."
  fi

  # Generate this site's nginx server block.
  PORT="$port" WEB_ROOT="$web" envsubst '${PORT} ${WEB_ROOT}' \
    < /etc/nginx/site.conf.template > "$HTTPD_DIR/site-$port.conf"

  poll_loop "$src" "$branch" "$build" "$output" "$web" "$label" &
done

# Record the first site's port for the Docker HEALTHCHECK to probe.
echo "$SITES" | jq -r '.[0].port // 80' > "$RUN_DIR/health-port"

# nginx (below) is the container's main process: tini supervises it directly,
# so its lifetime == the container's lifetime. If it ever dies the container
# exits and Docker restarts it cleanly.
cp /etc/nginx/nginx.conf.template /etc/nginx/nginx.conf
log "Starting nginx serving $count site(s): $(echo "$SITES" | jq -r '[.[].port]|join(", ")')"
exec nginx -g 'daemon off;'
