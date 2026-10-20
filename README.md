# Podium

A thin, self-updating **static-site runner** in a Docker container. Point it at
any GitHub repo and it will clone, build, and serve that repo — then poll the
branch and rebuild itself whenever you push. No image rebuilds, no manual
deploys.

- **Runner, not content:** the image bakes in nginx + node + git + a watch
  script. The site source is pulled from GitHub at runtime.
- **Any repo:** the build command and output directory are configurable, so it
  serves Node/Vite apps, plain static sites, or anything that produces a folder
  of files.
- **Self-updating:** push to the tracked branch and the live site updates within
  `POLL_INTERVAL` seconds. A failed build is logged and the **previous version
  stays live**.

## How it works

On startup [`docker/entrypoint.sh`](docker/entrypoint.sh):

1. Clones `REPO_URL` at branch `REPO_BRANCH`.
2. Runs `BUILD_CMD` and publishes `OUTPUT_DIR` to nginx's web root.
3. Renders the nginx config for `PORT` and starts nginx (with a `/healthz`
   endpoint and SPA fallback).
4. Loops forever: every `POLL_INTERVAL` seconds it `git fetch`es; if the remote
   HEAD moved, it pulls, rebuilds, and atomically swaps the live site.

## Configuration

| Env var         | Default                                      | Purpose                                                        |
| --------------- | -------------------------------------------- | -------------------------------------------------------------- |
| `REPO_URL`      | — (**required**)                             | GitHub repo to deploy. Private? See note below.                |
| `REPO_BRANCH`   | `main`                                       | Branch to track.                                               |
| `POLL_INTERVAL` | `300`                                        | Seconds between update checks.                                 |
| `BUILD_CMD`     | `npm ci --no-audit --no-fund && npm run build` | Shell command to build the site. Set to `""` to skip building. |
| `OUTPUT_DIR`    | `dist`                                       | Directory (relative to repo root) published to the web root.   |
| `PORT`          | `80`                                         | Container listen port.                                         |

> **Private repo:** use a token in the URL, e.g.
> `https://<user>:<token>@github.com/you/repo.git` (a fine-grained PAT with
> read-only Contents scope). Prefer injecting it via an unraid/compose variable
> rather than committing it.

## Usage

### Build the image

```bash
docker build -t podium:latest .
```

### Run a Node/Vite repo (defaults)

```bash
docker run -d --name mysite -p 8080:80 --restart unless-stopped \
  -e REPO_URL=https://github.com/you/your-vite-app.git \
  podium:latest
# site: http://localhost:8080   (host 8080 -> container 80)
```

### Run a plain static repo (no build step)

```bash
docker run -d --name static -p 8081:80 --restart unless-stopped \
  -e REPO_URL=https://github.com/you/static-site.git \
  -e BUILD_CMD="" \
  -e OUTPUT_DIR="." \
  podium:latest
```

### docker compose

See [`docker-compose.yml`](docker-compose.yml) for a template — set `REPO_URL`
and adjust the port mapping.

```bash
docker compose up -d --build
```

## Deploying on unraid

1. Build the image (or push it to a registry / GHCR and pull it on unraid).
2. **Add Container** → set:
   - **Repository:** `podium:latest` (or your registry path)
   - **Port:** container `80` (or your `PORT`) → a host port, e.g. `8080`
   - **Variables:** at minimum `REPO_URL`; plus `REPO_BRANCH`, `POLL_INTERVAL`,
     `BUILD_CMD`, `OUTPUT_DIR`, `PORT` as needed
   - **Restart policy:** `unless-stopped`
3. No bind mounts are required — the site is pulled from GitHub on each boot and
   kept current while running.

### Reverse proxy

Point your reverse proxy (Nginx Proxy Manager, SWAG, Traefik, Caddy, …) at the
container's host port:

- Upstream: `http://<unraid-ip>:8080`
- Health check path: `/healthz`
- Terminate TLS at the proxy; the container speaks plain HTTP.

## Structure

```
docker/
  entrypoint.sh         # clone → build → serve → poll-and-redeploy loop
  nginx.conf.template   # static serving + SPA fallback + /healthz (PORT templated)
Dockerfile              # thin runner image
docker-compose.yml      # example configuration
```
