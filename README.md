# Podium

A thin, self-updating **static-site runner** in a Docker container. Point it at
one or more GitHub repos and it will clone, build, and serve each one — then
poll every branch and rebuild itself whenever you push. No image rebuilds, no
manual deploys.

- **Runner, not content:** the image bakes in nginx + node + git + a watch
  script. The site source is pulled from GitHub at runtime.
- **Many sites, one container:** each site is served on its own port, with its
  own repo, branch, build command, and output directory.
- **Any repo:** serves Node/Vite apps, plain static sites, or anything that
  produces a folder of files.
- **Self-updating:** push to a tracked branch and that site updates within
  `POLL_INTERVAL` seconds. A failed build is logged and the **previous version
  stays live** — and never affects the other sites.

## How it works

On startup [`docker/entrypoint.sh`](docker/entrypoint.sh) reads `SITES` (a JSON
array) and, for each site:

1. Clones `repo` at `branch`.
2. Runs `build` and publishes `output` to that site's web root.
3. Generates an nginx `server` block listening on the site's `port` (with a
   `/healthz` endpoint and SPA fallback).
4. Starts a background poll loop: every `POLL_INTERVAL` seconds it `git
   fetch`es; if the remote HEAD moved, it pulls, rebuilds, and atomically swaps
   just that site's live files.

nginx then runs in the foreground as the container's main process, serving
every site's port.

## Configuration

Set **`SITES`** to a JSON array of site objects:

```json
[
  {
    "repo": "https://github.com/you/vite-app.git",
    "port": 8080,
    "branch": "main",
    "build": "npm ci --no-audit --no-fund && npm run build",
    "output": "dist"
  },
  {
    "repo": "https://github.com/you/static-site.git",
    "port": 8081,
    "build": "",
    "output": "."
  }
]
```

| Field    | Default                                        | Purpose                                                       |
| -------- | ---------------------------------------------- | ------------------------------------------------------------- |
| `repo`   | — (**required**)                               | GitHub repo to deploy. Private? See note below.               |
| `port`   | — (**required**)                               | Container port to listen on. Must be unique across sites.     |
| `branch` | `main`                                         | Branch to track.                                              |
| `build`  | `npm ci --no-audit --no-fund && npm run build` | Shell command to build the site. Set to `""` to skip building.|
| `output` | `dist`                                          | Directory (relative to repo root) published to the web root.  |

Plus one container-wide var:

| Env var         | Default | Purpose                                             |
| --------------- | ------- | --------------------------------------------------- |
| `POLL_INTERVAL` | `300`   | Seconds between update checks (applies to all sites)|

> **Legacy single-site mode:** if `SITES` is unset, Podium synthesizes one site
> from the old `REPO_URL` / `REPO_BRANCH` / `PORT` / `BUILD_CMD` / `OUTPUT_DIR`
> vars, so existing single-repo deployments keep working unchanged.

> **Private repo:** use a token in the URL, e.g.
> `https://<user>:<token>@github.com/you/repo.git` (a fine-grained PAT with
> read-only Contents scope). Prefer injecting it via an unraid/compose variable
> rather than committing it.

## Usage

### Build the image

```bash
docker build -t podium:latest .
```

### Run two sites on two ports

```bash
docker run -d --name podium --restart unless-stopped \
  -p 8080:8080 -p 8081:8081 \
  -e SITES='[
    {"repo":"https://github.com/you/vite-app.git","port":8080},
    {"repo":"https://github.com/you/static-site.git","port":8081,"build":"","output":"."}
  ]' \
  podium:latest
# vite app:     http://localhost:8080
# static site:  http://localhost:8081
```

### Run a single site (legacy env vars still work)

```bash
docker run -d --name mysite -p 8080:80 --restart unless-stopped \
  -e REPO_URL=https://github.com/you/your-vite-app.git \
  podium:latest
```

### docker compose

See [`docker-compose.yml`](docker-compose.yml) for a template — edit `SITES`
and add one published port per site.

```bash
docker compose up -d --build
```

## Deploying on unraid

1. Build the image (or push it to a registry / GHCR and pull it on unraid).
2. **Add Container** → set:
   - **Repository:** `podium:latest` (or your registry path)
   - **Variable:** `SITES` → the JSON array on a single line (unraid stores and
     passes it verbatim). For the portfolio site:

     ```json
     [{"repo":"https://github.com/ggardenhire/portfolio.git","port":8080}]
     ```

     For a single site you may instead set the legacy `REPO_URL` variable.
   - **Ports:** add one mapping per site — container `8080` → host `8080`,
     container `8081` → host `8081`, matching the `port` values in `SITES`.
   - **Restart policy:** `unless-stopped`
3. No bind mounts are required — every site is pulled from GitHub on each boot
   and kept current while running.

### Reverse proxy

Point your reverse proxy (Nginx Proxy Manager, SWAG, Traefik, Caddy, …) at each
site's host port:

- Upstream: `http://<unraid-ip>:8080`, `http://<unraid-ip>:8081`, …
- Health check path: `/healthz`
- Terminate TLS at the proxy; the container speaks plain HTTP.

## Structure

```
docker/
  entrypoint.sh         # read SITES → per-site clone → build → serve → poll-and-redeploy
  nginx.conf.template   # http wrapper; includes the generated per-site blocks
  site.conf.template    # one server block (static serving + SPA fallback + /healthz)
Dockerfile              # thin runner image
docker-compose.yml      # example multi-site configuration
```

## License

[MIT](LICENSE) © 2026 Garret Gardenhire
