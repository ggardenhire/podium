# Podium: a thin "runner" image carrying nginx + node + git and a watch script.
# The actual site source is pulled from a GitHub repo at runtime (see the
# entrypoint), so content changes never require rebuilding this image.
FROM node:22-alpine

RUN apk add --no-cache nginx git bash tini curl gettext \
    && mkdir -p /run/nginx /usr/share/nginx/html /app \
    && rm -f /etc/nginx/http.d/default.conf

COPY docker/nginx.conf.template /etc/nginx/nginx.conf.template
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /app

# Generic defaults — set REPO_URL (required) and override any of these in
# docker-compose / unraid. REPO_URL has no default on purpose.
ENV REPO_BRANCH=main \
    POLL_INTERVAL=300 \
    BUILD_CMD="npm ci --no-audit --no-fund && npm run build" \
    OUTPUT_DIR=dist \
    PORT=80

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
  CMD curl -fsS "http://localhost:${PORT}/healthz" || exit 1

# tini reaps children and forwards signals; the script spawns nginx + sleeps.
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
