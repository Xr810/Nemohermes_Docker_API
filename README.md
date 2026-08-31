# NemoHermes — Docker Release Package

Runs the **Hermes agent sandbox** (NVIDIA OpenShell + NemoClaw) inside a single
Docker container and publishes its OpenAI-compatible API on the host, so any
OpenAI-compatible client — Open WebUI, a script, `curl` — can talk to it.

**Scope: the Docker path only.** The bare-metal Ubuntu installer (`deploy.sh`,
`01-infra.sh` … `05-verify.sh`, `config.env`, `resources/`) lives in the source
repository, not here. Nothing in this folder reads or needs it.

This package does not install Open WebUI either — it publishes an API and
expects you to bring a client. The companion package `nemohermes-chat` is the
same wrapper with Open WebUI bundled and installed for you.

| Document | Read it for |
|---|---|
| `README.md` (this file) | Build it, run it, verify it, what you actually get |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Why the container is built this way, self-healing, start-up troubleshooting |
| [OPERATIONS.md](OPERATIONS.md) | Day-two work: switching model/provider, MCP servers, logs |

---

## Contents

- [What you get](#what-you-get)
- [Requirements](#requirements)
- [Build from source](#build-from-source)
- [Configure](#configure)
- [Run](#run)
- [Verify it is actually serving](#verify-it-is-actually-serving)
- [Connect Open WebUI on another device](#connect-open-webui-on-another-device)
- [Inside the container](#inside-the-container)
- [Configuration reference](#configuration-reference)
- [Rebuilding and shipping a tar](#rebuilding-and-shipping-a-tar)
- [Common commands](#common-commands)
- [Repository layout](#repository-layout)
- [Security](#security)

---

## What you get

One image, `nemohermes-api:local`, roughly **190 MB** compressed as a tar. It
contains Ubuntu 24.04, systemd, a Docker engine, and a bootstrap script — and
deliberately **no configuration, no credentials, and no Hermes sandbox**.

What is in the image, and what only appears at run time, is the single most
confusing thing about this package, so it is worth being explicit:

| | Baked into the image at build time | Created on first `up`, kept in a volume |
|---|---|---|
| Base OS | Ubuntu 24.04 | — |
| Init | systemd as PID 1, unit files, masks | — |
| Inner engine | `docker.io` + `docker-buildx` packages | `/var/lib/docker` contents |
| Bootstrap | `/usr/local/sbin/nemohermes` + its systemd unit | — |
| OpenShell / NemoClaw CLI | ✗ — needs a live Docker engine, which does not exist during build | Downloaded from `nvidia.com`, installed into `/root/bin` |
| Hermes sandbox | ✗ | Built by the gateway as a **child container** |
| Sandbox base images | ✗ | Pulled from GHCR |
| Your API key, model, endpoint | ✗ **never** | Injected from `.env` at container start |

The consequences follow from that table:

- **The image is byte-identical on every machine.** It holds nothing
  machine-specific, so it is safe to `docker save` and hand to someone else.
- **Changing the key, model, endpoint or sandbox name is not a rebuild.** It is
  an `.env` edit plus `docker compose up -d`.
- **The first start needs network and takes a while** — it installs the CLI,
  pulls two base images, and builds an 84-layer sandbox image. Later starts skip
  all of it.

### Request path

```text
Open WebUI / curl on another device
  └─ http://<this-host-ip>:8642/v1          published by compose
     └─ openshell forward → sandbox :18642
        └─ Hermes API server (in the sandbox container)
           └─ OpenShell gateway inference layer
              └─ your provider (OpenAI-compatible endpoint) → your model
```

> **Always send the model name `hermes-agent`.** The `INFERENCE_MODEL` value
> from `.env` is what the gateway forwards upstream; it is not a model name this
> API exposes.

---

## Requirements

| Item | Requirement |
|---|---|
| Runtime | Docker Engine, Docker Desktop, or OrbStack. Must allow `privileged` containers |
| Commands | `docker` and `docker compose` (v2+) |
| Disk | ~2 GB after the first start (wrapper image + sandbox images + inner engine state) |
| Network, first start | `nvidia.com` (CLI install), `ghcr.io` (sandbox base images), plus your inference endpoint |
| Network, later starts | Your inference endpoint only |
| Inference | An OpenAI-compatible base URL + model name + API key |
| MCP (optional) | A public HTTPS MCP Router URL + token |

`privileged: true` is not optional here: systemd as PID 1 and the inner Docker
engine both need cgroup and network-admin capabilities. See
[ARCHITECTURE.md](ARCHITECTURE.md#how-the-container-works) for why there is no
unprivileged variant.

The inference endpoint must resolve over **real DNS**. A local proxy in fake-ip
mode (Surge/Clash, `198.18.x.x`) makes the onboard probe fail; the bootstrap
detects this and stops with an explanation rather than failing obscurely later.

Do not point the base URL at `https://inference.local/v1`. That name exists only
inside the sandbox and the onboard probe will fail.

> `.env`, `.env.example`, `.dockerignore` and `.gitignore` start with a dot and
> are hidden by default. Use `ls -la` in a terminal, or press `Cmd + Shift + .`
> in Finder.

---

## Build from source

This repository ships **source only** — there is no image tar in it. Build the
image first:

```bash
docker compose build
```

That takes a few minutes and produces `nemohermes-api:local`. It needs network
for the Ubuntu base image and the `apt` packages, and nothing else — no
credentials are involved, and `.env` does not have to exist yet.

You can skip this step entirely: `docker compose up -d` builds the image
automatically when it is missing. Building first just separates "did the image
build?" from "did the deployment come up?", which makes the first run far easier
to debug.

If someone handed you a prebuilt `nemohermes-api-local.tar`, load it instead of
building — see [Rebuilding and shipping a tar](#rebuilding-and-shipping-a-tar).

---

## Configure

```bash
cp .env.example .env
```

Then edit `.env` and fill in at least these three:

```bash
INFERENCE_BASE_URL=https://your-endpoint/v1
INFERENCE_MODEL=your-model-name
INFERENCE_API_KEY=your-key
```

Compose **requires** `.env` to exist and refuses to start without it. It does
**not** check that the values are filled in, so an empty `INFERENCE_API_KEY`
lets the container start and then fail minutes later inside onboard. There is no
fallback key in the image.

`.env.example` documents every supported variable; the
[configuration reference](#configuration-reference) below summarises the ones
that matter.

---

## Run

```bash
docker compose up -d
```

Then watch the bootstrap:

```bash
docker compose logs -f
```

This works because compose sets `tty: true`: the workload runs as a systemd unit
rather than PID 1, and systemd's console output — its own boot messages plus
everything the bootstrap service prints — only reaches the Docker log driver
through the pty that a TTY provides. Without one, `/dev/console` is a plain file
inside the container and `docker compose logs` stays empty. For scrollback,
filtering, or `systemctl status`-style detail, read the journal instead:

```bash
docker exec nemohermes-api journalctl -u nemohermes -f
```

Expect the first start to take a while: it installs the CLI, pulls two base
images, and builds an 84-layer sandbox image. The healthcheck allows **15
minutes** before reporting `unhealthy`. Watch the logs before concluding that
it hung.

A healthy first start ends with lines like:

```text
[nemohermes] Hermes API  http://0.0.0.0:8642/v1
[nemohermes] dashboard   http://0.0.0.0:18789/
```

---

## Verify it is actually serving

`/health` returning 200 only proves the port forward is up. Send a real request
to exercise the whole chain — forward, gateway, sandbox, inference endpoint:

```bash
KEY=$(docker compose exec -T nemohermes \
        sed -n 's/^OPENAI_API_KEY=//p' /root/hermes-openai.env | tr -d '\r')

curl -s -X POST http://127.0.0.1:8642/v1/chat/completions \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"hermes-agent","messages":[{"role":"user","content":"ping"}]}'
```

A reply from `hermes-agent` means everything works.

| Interface | Address |
|---|---|
| Hermes API | `http://127.0.0.1:8642/v1` (health at `/health`) |
| Hermes dashboard | `http://127.0.0.1:18789/` |

---

## Connect Open WebUI on another device

Open WebUI is **not** installed in this image. Point a remote instance at the
Hermes API.

Read the generated connection file (base URL + API key):

```bash
docker compose exec nemohermes cat /root/hermes-openai.env
```

On the other device, open Open WebUI → **Admin → Settings → Connections →
OpenAI**. Set the base URL to `http://<this-host-ip>:8642/v1` — this machine's
LAN IP, **not** `127.0.0.1` — and paste the `OPENAI_API_KEY`. The Open WebUI
**server**, not the browser, must be able to reach this host on `8642`.

That key is the sandbox's Hermes `API_SERVER_KEY`, not your inference provider
key. Do not expose `8642` to the public internet without TLS.

---

## Inside the container

Useful to know before you debug anything, because almost nothing is where a
single-process container would put it.

```text
nemohermes  (privileged wrapper container)
│
├─ PID 1  /lib/systemd/systemd
│  ├─ docker.service ................ inner dockerd (the "child" engine)
│  ├─ user@0.service ................ root's systemd user manager
│  │  └─ nemoclaw-openshell-gateway.service   ← the gateway, loopback-only
│  └─ nemohermes.service ............ /usr/local/sbin/nemohermes  (bootstrap)
│
├─ inner dockerd owns:
│  └─ the Hermes sandbox container    ← `docker compose exec nemohermes docker ps`
│                                       never the host's `docker ps`
│
├─ /root ............................ volume `nemohermes-home`
│  ├─ bin/ .......................... openshell, openshell-sandbox, openshell-gateway
│  ├─ .nemoclaw/ .................... NemoClaw state, lifecycle locks
│  ├─ .config/openshell/gateway.env . gateway bind address + supervisor path
│  ├─ .local/state/nemoclaw/ ........ gateway TLS/PKI
│  └─ hermes-openai.env ............. generated base URL + API key
│
├─ /var/lib/docker .................. volume `nemohermes-docker` (inner images)
├─ /usr/local/sbin/nemohermes ....... bootstrap script (baked into the image)
└─ /run, /run/lock .................. tmpfs.  /tmp deliberately is NOT
```

Two things trip people up constantly:

1. **Sandboxes are children, not siblings.** They are created by the *inner*
   dockerd, so they appear in `docker compose exec nemohermes docker ps` and
   never in the host's `docker ps`.
2. **The workload is a systemd unit, not PID 1.** Its output goes to the
   journal; compose sets `tty: true` so the console half also reaches
   `docker compose logs`, but `journalctl -u nemohermes` is still the place for
   scrollback and filtering.

The bootstrap script does far more than start things — on every boot it
reconciles the state NemoClaw leaves behind after an interrupted run (stale
locks, half-written PKI, errored sandboxes, drifted unit paths). That is
documented in [ARCHITECTURE.md](ARCHITECTURE.md#self-healing-on-start).

---

## Configuration reference

Everything runtime lives in `.env`. Apply any change with `docker compose up -d`.

| Variable | Default | Purpose |
|---|---|---|
| `INFERENCE_BASE_URL` | — | Required. OpenAI-compatible endpoint |
| `INFERENCE_MODEL` | — | Required. Model the gateway sends upstream |
| `INFERENCE_API_KEY` | — | Required. Provider key |
| `SANDBOX_NAME` | `main` | Sandbox onboard creates. 1–19 chars, lowercase letters/digits/single hyphens, must start with a letter |
| `APPROVALS_MODE` | `manual` | `off` / `smart` / `manual`; empty skips the approvals step |
| `MCP_URL` | empty | Public HTTPS MCP Router; empty skips MCP |
| `MCP_ROUTER_TOKEN` | empty | Required when `MCP_URL` is set |
| `MCP_ENV_VAR` | `MCP_ROUTER_TOKEN` | Name of the OpenShell credential, not the token |
| `AGENT` | `hermes` | Agent runtime; keep as is |
| `HERMES_API_PORT` | `8642` | Same number inside and out |
| `HERMES_DASHBOARD_PORT` | `18789` | Same number inside and out |
| `FORWARD_BIND` | `0.0.0.0` (set by compose) | Address the in-container forwards bind |
| `SANDBOX_PULL_IMAGES` | empty | Extra images to pull if missing, space-separated |
| `NEMOCLAW_SANDBOX_GPU` | unset | Unset is correct; see [GPU passthrough](ARCHITECTURE.md#gpu-passthrough) |
| `ONBOARD_FRESH` | `0` | `1` discards the onboard session; may re-resolve the base image |
| `DOCKER_WAIT_SECS` | `90` | Wait for the inner engine |
| `USER_MANAGER_WAIT_SECS` | `90` | Wait for `user@0.service` |
| `SANDBOX_WAIT_SECS` | `180` | Wait for the sandbox to reach Ready |
| `SANDBOX_READY_GRACE_SECS` | `8` | Grace period before deciding onboard is needed |

`.env.example` carries the same list with inline comments. Why none of it is
baked into the image is in
[ARCHITECTURE.md](ARCHITECTURE.md#configuration-never-enters-the-image).

---

## Rebuilding and shipping a tar

Rebuild only after editing the `Dockerfile` — its `RUN` layers or the embedded
bootstrap script. Changing the key, model or sandbox name is a config change:

```bash
docker compose up -d --build
```

There is one Compose file and it handles every case, because `build:` and
`image:` together resolve the way this package needs:

| Situation | Result |
|---|---|
| Image present, `up` | Reuses it. No build, no registry pull, even if the `Dockerfile` changed since |
| Image present, `up --build` | Rebuilds and replaces the tag |
| Image missing, `up` | Builds from this `Dockerfile`. No attempt to pull `nemohermes-api:local` |

Avoid `--no-build`: it is the one path that *does* attempt a registry pull, and
it fails with `No such image: nemohermes-api:local` — that tag exists in no
registry.

To ship the built image to a machine that cannot build:

```bash
docker compose build
docker save -o nemohermes-api-local.tar nemohermes-api:local     # ~190 MB
```

On the target machine, put the tar next to this folder and load it before
starting:

```bash
docker load -i nemohermes-api-local.tar
docker compose up -d
```

The tar is an optimisation, not a requirement — without it the first `up` builds
the same image locally. It is also **not committed to this repository**
(`.gitignore` excludes `*.tar`), so a fresh clone always builds.

Note that loading the tar does not make the first start offline: the CLI install
and the sandbox base images are not in it.

---

## Common commands

```bash
docker compose ps
docker exec nemohermes-api journalctl -u nemohermes -f    # bootstrap log
docker compose restart                                # re-bind forwards, skip onboard
docker compose down                                   # stop; named volumes stay
docker compose down -v                                # wipe volumes; next start is a first start
docker compose exec nemohermes docker ps              # inner sandbox containers
docker compose exec nemohermes bash                   # shell inside the wrapper
```

---

## Repository layout

| Path | Purpose |
|---|---|
| `Dockerfile` | The whole image: packages, systemd as PID 1, inner dockerd, and the bootstrap script embedded as a heredoc. No configuration, no secrets |
| `docker-compose.yml` | The only Compose file — it both runs the image and rebuilds it. Carries the rationale for every runtime setting |
| `.env.example` | Configuration template documenting every supported variable. Shareable |
| `.env` | Your live configuration. **Contains credentials — never commit or share.** Not in the repository |
| `.dockerignore` | Keeps the build context near-empty (see below). Not shipped inside the image |
| `.gitignore` | Excludes `.env`, `*.tar` and editor/OS noise from git |
| `README.md` | This file: build, run, verify |
| `ARCHITECTURE.md` | How the container works and why; self-healing; start-up troubleshooting |
| `OPERATIONS.md` | Day-two operations |

**What `.dockerignore` is for.** When you run `docker compose build`, Docker
tars up this folder and ships it to the daemon as the *build context* — before
reading a single instruction. The `Dockerfile` here creates every file it needs
with heredoc `COPY`, and reads nothing from disk, so that upload is pure waste.
`.dockerignore` shrinks it to almost nothing, which matters most when a ~190 MB
`nemohermes-api-local.tar` is sitting in the folder: without it, that tar is
re-uploaded to the daemon on every build.

It also excludes `.env` as defence in depth. Note that this is *not* what keeps
your key out of the image — nothing is ever `COPY`d from the context, so no
context file can reach a layer regardless. Add an exception to `.dockerignore`
only if you ever introduce a real `COPY <path>` from disk.

---

## Security

- `.env` holds your inference API key and MCP token. It is excluded from git
  (`.gitignore`) and from the build context (`.dockerignore`), and no `COPY`
  reads from the context, so **no secret can reach an image layer** —
  `nemohermes-api-local.tar` is safe to distribute.
- Do not hand out the *folder* with a filled-in `.env` in it, and keep it off
  shared drives. Share `.env.example` instead.
- The container is **privileged**. It does not use the host Docker engine and
  does not bind the host's `/root`, but "isolated from the host engine" is not
  "an unprivileged sandbox". Run it on a host you trust.
- The Hermes API on `8642` is protected only by the sandbox's `API_SERVER_KEY`.
  Do not expose it to the public internet without TLS. To restrict it to this
  machine, change the compose `ports` bind to `127.0.0.1:8642:8642`.
- The OpenShell gateway is deliberately **not** exposed. It listens on loopback
  only, reachable from sandbox containers through a single DNAT rule — see
  [ARCHITECTURE.md](ARCHITECTURE.md#the-gateway-is-reachable-not-exposed).
