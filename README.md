# NemoHermes — Release Package

Docker release package for the Hermes agent sandbox (NVIDIA OpenShell +
NemoClaw). The container exposes the OpenAI-compatible Hermes API, so an Open
WebUI running on another device can connect to it.

**This package is the Docker path only.** The bare-metal Ubuntu installer
(`deploy.sh`, `01-infra.sh` and friends) lives in the source repository, not
here.

All configuration is in `.env`. The image holds no configuration and no secret,
so changing the key or the model never requires a rebuild.

> `.env`, `.env.example` and `.dockerignore` start with a dot and are hidden by
> default. Use `ls -la` in a terminal, or press `Cmd + Shift + .` in Finder.

## Requirements

| Item | Requirement |
|---|---|
| Runtime | Docker Engine, Docker Desktop, or OrbStack. Needs `privileged` (systemd + inner dockerd) |
| Commands | `docker` and `docker compose` (v2+) |
| Network, first start | `nvidia.com` for the CLI install, GHCR for the sandbox base images, plus your inference endpoint |
| Inference | OpenAI-compatible base URL + model name + API key |
| MCP (optional) | Public HTTPS MCP Router URL + token |

The inference endpoint must resolve over real DNS. A local proxy in fake-ip mode
(Surge/Clash, `198.18.x.x`) makes the onboard probe fail; the entrypoint detects
this and stops with an explanation instead of failing obscurely later.

## Quick start

```bash
cd /path/to/Nemohermes_Docker_Deployment
docker load -i nemohermes-local.tar
cp .env.example .env
# edit .env: at minimum INFERENCE_BASE_URL, INFERENCE_MODEL, INFERENCE_API_KEY
docker compose up -d
```

Loading the tar is an optimisation, not a requirement. Compose reuses that image
if it is present and builds the same image from the `Dockerfile` if it is not —
see [Rebuilding](#rebuilding).

The first start still needs network: the container installs the OpenShell /
NemoClaw CLI and its inner dockerd pulls the sandbox base images. Neither is in
the tar. Later starts skip both.

Watch the bootstrap. The workload is a systemd unit rather than PID 1, so
`docker compose logs` is usually empty:

```bash
docker exec nemohermes journalctl -u nemohermes -f
```

Expect the first start to take a while: it installs the CLI, pulls two base
images and builds an 84-layer sandbox image. The healthcheck allows 15 minutes
before reporting unhealthy.

## Verify it is actually serving

`/health` returning 200 only proves the port forward is up. Send a real request
to confirm the whole chain — forward, gateway, sandbox, inference endpoint:

```bash
KEY=$(docker compose exec -T nemohermes \
        awk -F= '/^OPENAI_API_KEY=/{print $2}' /root/hermes-openai.env)

curl -s -X POST http://127.0.0.1:8642/v1/chat/completions \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"hermes-agent","messages":[{"role":"user","content":"ping"}]}'
```

A reply from `hermes-agent` means everything works.

> Always send the model name **`hermes-agent`**, not the `INFERENCE_MODEL` value
> from `.env`. The latter is what the gateway sends upstream; it is not a model
> name this API exposes.

| Interface | Address |
|---|---|
| Hermes API | `http://127.0.0.1:8642/v1` (health at `/health`) |
| Hermes dashboard | `http://127.0.0.1:18789/` |

## Connect Open WebUI on another device

Read the connection file (base URL + API key):

```bash
docker compose exec nemohermes cat /root/hermes-openai.env
```

On the other device, open Open WebUI → **Admin → Settings → Connections →
OpenAI**. Set the base URL to `http://<this-host-ip>:8642/v1` — this machine's
LAN IP, not `127.0.0.1` — and paste the `OPENAI_API_KEY`. The Open WebUI
**server**, not the browser, must be able to reach this host on `8642`.

That key is the sandbox Hermes `API_SERVER_KEY`, not your inference provider
key. Do not expose `8642` to the public internet without TLS.

## Configuration

Everything runtime lives in `.env`. Apply a change with:

```bash
docker compose up -d
```

`.env.example` documents every supported variable. The common ones:

| Variable | Purpose |
|---|---|
| `INFERENCE_BASE_URL` / `INFERENCE_MODEL` / `INFERENCE_API_KEY` | Required. Upstream inference endpoint |
| `SANDBOX_NAME` | Sandbox onboard creates. 1–19 chars, lowercase letters/digits/single hyphens, must start with a letter |
| `APPROVALS_MODE` | `off` / `smart` / `manual`; empty skips the approvals step |
| `MCP_URL` / `MCP_ROUTER_TOKEN` | Optional public HTTPS MCP Router; empty `MCP_URL` skips MCP |
| `HERMES_API_PORT` / `HERMES_DASHBOARD_PORT` | Same port number inside and outside the container |

Compose requires `.env` to exist and refuses to start without it. It does **not**
check that the values are filled in, so an empty `INFERENCE_API_KEY` lets the
container start and then fails minutes later inside onboard. There is no
fallback key in the image.

## Rebuilding

Only needed after editing the `Dockerfile` — its RUN layers or the entrypoint
script. Changing the key, model or sandbox name is a config change, not a
rebuild.

```bash
docker compose up -d --build
```

There is one Compose file and it handles both cases:

| Situation | Result |
|---|---|
| Image present, `up` | Reuses it. No build, no registry pull, even if the `Dockerfile` changed |
| Image present, `up --build` | Rebuilds and replaces the tag |
| Image missing, `up` | Builds from this `Dockerfile`. No attempt to pull `nemohermes:local` |

Avoid `--no-build`: it is the one path that tries a registry pull and then fails
with `No such image: nemohermes:local`.

To reship the result to another machine:

```bash
docker compose build
docker save -o nemohermes-local.tar nemohermes:local
```

## Common commands

```bash
docker compose ps
docker exec nemohermes journalctl -u nemohermes -f    # bootstrap log
docker compose restart
docker compose down          # stop; named volumes (CLI, sandbox images) stay
docker compose down -v       # wipe the volumes; next start is a first start
docker compose exec nemohermes docker ps              # inner sandbox containers
docker compose exec nemohermes bash                   # shell inside the wrapper
```

Sandboxes are created by the **inner** dockerd and never appear in the host's
`docker ps`.

## Files

| File | Purpose |
|---|---|
| `nemohermes-local.tar` | Prebuilt wrapper image, ~190 MB, tagged `nemohermes:local`. No secrets |
| `docker-compose.yml` | The only Compose file: runs the image and rebuilds it. Carries the rationale for every runtime setting |
| `Dockerfile` | Image definition: systemd, inner dockerd, and the embedded bootstrap script |
| `.dockerignore` | Build context exclusions, including the image tar and `.env` |
| `.env.example` | Configuration template. Shareable |
| `.env` | Live configuration for this machine. **Contains credentials — do not share or commit** |
| `README.md` | This file, the entry point |
| `README-full.md` | Full reference: container architecture, self-healing, troubleshooting |
| `OPERATIONS.md` | Day-two operations: changing model/provider, managing MCP, reading logs |

## Security

`.env` holds your inference API key and MCP token. `.dockerignore` keeps it out
of the build context, so no secret reaches an image layer and
`nemohermes-local.tar` is safe to distribute. Do not hand out the folder itself
with `.env` in it, and keep it off shared drives — share `.env.example` instead.

If you ever run `git init` here, add `.env` and `*.tar` to `.gitignore` first.
