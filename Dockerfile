# Podium: a thin "runner" image carrying nginx + node + git and a watch script.
# One container can serve many GitHub repos, each built and served on its own
# port. The site source is pulled from GitHub at runtime (see the entrypoint),
# so content changes never require rebuilding this image.
FROM node:22-alpine

RUN apk add --no-cache nginx git bash tini curl gettext jq \
    && mkdir -p /run/nginx /run/podium /srv/sites /etc/nginx/http.d /app \
    && rm -f /etc/nginx/http.d/default.conf

COPY docker/nginx.conf.template /etc/nginx/nginx.conf.template
COPY docker/site.conf.template /etc/nginx/site.conf.template
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /app

# Multi-site config (preferred): a JSON array of {repo,port,branch,build,output}.
#   SITES='[{"repo":"https://github.com/you/app.git","port":8080}, ...]'
# Legacy single-site fallback (used only when SITES is unset): set REPO_URL
# plus any of the vars below. REPO_URL / SITES have no default on purpose.
ENV REPO_BRANCH=main \
    POLL_INTERVAL=300 \
    BUILD_CMD="npm ci --no-audit --no-fund && npm run build" \
    OUTPUT_DIR=dist \
    PORT=80

# Documentation only — publish each site's port at `docker run`/compose/unraid.
EXPOSE 80

# Probe the first site's port (recorded by the entrypoint), defaulting to 80.
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
  CMD curl -fsS "http://localhost:$(cat /run/podium/health-port 2>/dev/null || echo 80)/healthz" || exit 1

# tini reaps children and forwards signals; the script spawns nginx + sleeps.
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
