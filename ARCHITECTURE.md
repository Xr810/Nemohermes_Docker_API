# NemoHermes — Architecture

How the container is built, why it is built that way, and what to do when it
misbehaves. Start with [README.md](README.md) to build and run it; this document
is the reference behind it.

**Scope: the Docker path only.** This package contains no bare-metal installer.
The Ubuntu path (`deploy.sh`, `01-infra.sh` … `05-verify.sh`, `lib.sh`,
`config.env`, `resources/`) and the in-sandbox Open WebUI install live in the
source repository, not here. Nothing in this folder reads or needs them.

Day-two operations — changing the model or provider, adding MCP servers,
reading logs — are in [OPERATIONS.md](OPERATIONS.md).

## Contents

- [What this deploys](#what-this-deploys)
- [Requirements](#requirements)
- [Configuration](#configuration)
- [How the container works](#how-the-container-works)
- [Self-healing on start](#self-healing-on-start)
- [Access points](#access-points)
- [Lifecycle](#lifecycle)
- [Rebuilding and reshipping](#rebuilding-and-reshipping)
- [Troubleshooting](#troubleshooting)
- [Package layout](#package-layout)

## What this deploys

`docker compose up -d` starts one privileged wrapper container. Inside it,
systemd runs an inner dockerd, the OpenShell gateway creates a Hermes sandbox as
a child container, and the sandbox's OpenAI-compatible API is published on the
host.

```text
Open WebUI on another device
  → http://<this-host-ip>:8642/v1     (openshell forward → sandbox 18642)
    → Hermes API server in the sandbox
      → OpenShell gateway inference layer
        → provider (OpenAI-compatible endpoint) → model
```

Open WebUI is **not** installed in the image. Point a remote Open WebUI at the
Hermes API instead.

Requests to that API always use the model name `hermes-agent`. The model in
`.env` (`INFERENCE_MODEL`) is what the gateway sends upstream, and is not
exposed as a model name on this API.

## Requirements

| Item | Requirement |
|---|---|
| Runtime | Docker Engine, Docker Desktop, or OrbStack |
| Privileges | `privileged: true` — systemd plus inner dockerd. No host `docker.sock`, no bind of the host's `/root`; see [How the container works](#how-the-container-works) |
| Commands | `docker` and `docker compose` (v2+) |
| Network, first start | `nvidia.com` for the CLI install, GHCR for the sandbox base images, plus your inference endpoint |
| Network, later starts | Your inference endpoint only |
| Inference | OpenAI-compatible base URL + model name + API key |
| MCP (optional) | Public HTTPS MCP Router URL + token |

The inference endpoint must resolve over real DNS. A local proxy in fake-ip mode
(Surge/Clash, `198.18.x.x`) makes the onboard probe fail; the entrypoint detects
this and stops with an explanation rather than failing obscurely later.

Do not point the base URL at `https://inference.local/v1`. That name exists only
inside the sandbox and the onboard probe will fail.

## Configuration

Everything lives in `.env`; the image holds none of it. Changing the key, the
model or the sandbox name is `docker compose up -d` — never a rebuild. Rebuild
only after the `Dockerfile` RUN layers or the entrypoint change.

No secret can reach an image layer: the `Dockerfile` creates every file it
needs with heredoc `COPY` and never `COPY`s from the build context, and
`.dockerignore` excludes `.env` from that context as defence in depth. So
`nemohermes:local` is safe to `docker save` and copy to another machine.

Compose **requires** `.env` to exist and refuses to start without it, rather than
failing minutes later inside onboard. It does not check that the values are
filled in, so an empty `INFERENCE_API_KEY` still fails late. There is no
fallback key in the image.

`.env.example` documents every supported variable. Summary:

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
| `NEMOCLAW_SANDBOX_GPU` | unset | Unset is correct; see [GPU passthrough](#gpu-passthrough) |
| `ONBOARD_FRESH` | `0` | `1` discards the onboard session; may re-resolve the base image |
| `DOCKER_WAIT_SECS` | `90` | Wait for the inner engine |
| `USER_MANAGER_WAIT_SECS` | `90` | Wait for `user@0.service` |
| `SANDBOX_WAIT_SECS` | `180` | Wait for the sandbox to reach Ready |
| `SANDBOX_READY_GRACE_SECS` | `8` | Grace period before deciding onboard is needed |

`IN_CONTAINER=1` and `FORWARD_BIND=0.0.0.0` are set in the compose file rather
than `.env`, so the image always knows it is the compose deployment.

## How the container works

Worth reading before deploying: this is not an ordinary sandboxed container. It
is Docker-in-Docker with systemd as PID 1, and an inner dockerd that creates the
Hermes sandbox as a *child* of the wrapper.

### systemd runs as PID 1

NemoClaw starts the OpenShell gateway as a **systemd user unit** and refuses to
attach to a gateway it cannot prove is supervised — `gateway-management.ts`
accepts only `systemd-system` and `systemd-user` as supervisor kinds, and the
"standalone fallback" it mentions on a systemd-less host aborts onboarding at
step 2/8. So the image installs systemd, runs it as PID 1, and pre-enables
lingering so root's user manager comes up without a login. The deployment itself
runs as `nemohermes.service`, whose output goes to the journal and the console.
Inner `docker.service` is enabled in the image (not masked) so dockerd starts
under the same systemd.

Because the workload is a systemd unit rather than PID 1, `docker compose logs`
is often empty. Read the journal instead:

```bash
docker exec nemohermes journalctl -u nemohermes -f
```

Consequences of systemd as PID 1: `privileged: true` (systemd and inner dockerd
need cgroups and net admin), tmpfs for `/run` and `/run/lock`, and
`STOPSIGNAL SIGRTMIN+3` with a 60 s `stop_grace_period` so the inner engine can
stop its sandbox containers first.

The cgroup namespace stays **private** — this is a cgroup v2 host, so systemd
mounts its own cgroup2 tree. The old `cgroup: host` plus a read-write bind of the
host `/sys/fs/cgroup` is a cgroup v1 recipe and would hand this systemd the
host's entire cgroup tree.

`/tmp` is deliberately **not** tmpfs. Docker's tmpfs defaults are `noexec` and
`size=64m`; the OpenShell installer unpacks there and gates installation on
`[ -x $tmpdir/openshell-gateway ]`, which `noexec` makes false — and 64 MB
cannot hold the 67 MB gateway binary anyway.

`HOME` must stay `/root`. systemd synthesizes root's home as `/root` and ignores
`/etc/passwd` for it, so `%h`, `%E`, `%S` and the unit search path stay there no
matter what `HOME` says. Point `HOME` elsewhere and the gateway unit is written
where systemd will not look, and onboard fails step 2/8 with "service identity
query returned invalid metadata".

### Sandboxes are children, not siblings

The wrapper runs its own dockerd. NemoClaw talks to `/var/run/docker.sock`
*inside* the container; that socket is not the host's. Sandbox containers
therefore show up in `docker compose exec nemohermes docker ps`, not in the
host's `docker ps`.

NemoClaw still hands dockerd absolute paths under `HOME` (the supervisor binary,
the guest TLS bundle). Because the inner daemon and those files share one
filesystem, a named volume at `/root` is enough — there is no host bind of
`/root`.

A second named volume at `/var/lib/docker` holds inner images and containers, so
overlay2 is not stacked on the wrapper's overlay filesystem, and so
`docker compose down` (without `-v`) can skip the installer and the image pull on
the next `up`.

The wrapper is still privileged. Isolation here means "does not use the host
Docker engine or the host's `/root`", not "an unprivileged sandbox".

### The gateway is reachable, not exposed

NemoClaw pins the gateway to `127.0.0.1` and rejects an override outright
(`NEMOCLAW_GATEWAY_BIND_ADDRESS=0.0.0.0 is not supported ... while gateway JWT
auth is active`). Sandbox containers, however, dial it at
`host.openshell.internal`, which Docker resolves to the `openshell-docker` bridge
gateway address — where a loopback-only listener never answers, and onboard
reports it as a host firewall problem that no firewall rule can fix.

The entrypoint installs a DNAT from that bridge address to loopback, and nothing
else:

```text
iptables -t nat -A PREROUTING -d <bridge-gw> -p tcp --dport 8080 \
  -j DNAT --to-destination 127.0.0.1:8080
```

Binding `0.0.0.0` would have put the gateway on every interface including the
LAN; this exposes it to exactly the one subnet that has to reach it.
`net.ipv4.conf.all.route_localnet=1` is what lets a DNAT target `127.0.0.1` from
an external interface. The rule lands in the wrapper's netns, next to the inner
dockerd — compose does not use host networking.

The bridge does not exist until the gateway creates it, part-way through onboard.
The entrypoint installs the rule immediately if a previous run left the network
behind, and otherwise races a watcher against onboard. If the watcher loses,
`Restart=on-failure` retries and the network is there by then.

The Hermes API and dashboard are published with `ports:`. OpenShell's own
forwards bind `127.0.0.1` inside the wrapper, so `docker-proxy` would get a
connection reset; the entrypoint DNATs those published ports onto loopback the
same way.

### GPU passthrough

Decided from the hardware. Without a usable `nvidia-smi`, the entrypoint sets
`NEMOCLAW_SANDBOX_GPU=0`, because the Docker GPU compatibility patch runs even
after preflight reports no GPU and then fails the sandbox create — leaving the
sandbox in `Error` phase, which also blocks the next run. An explicit value in
`.env` always wins.

## Self-healing on start

A run interrupted partway leaves state that wedges every later run, and NemoClaw
does not clean any of it up. The entrypoint reconciles the following on each
start. All of it is idempotent and a no-op on a healthy deployment.

| Leftover | Symptom it causes | Handling |
|---|---|---|
| Lifecycle locks from a dead container generation | `Timed out waiting for the sandbox mutation lock (owner pid N)` | Dropped when the PID namespace differs or no process owns the pid; a live owner is left alone, so two mutations can never race |
| Empty directories dockerd created for missing bind sources | `failed to read sandbox token`, `... is a directory` | `rmdir`, which only ever removes an *empty* directory — real keys and tokens cannot be touched |
| Half-written gateway PKI | `partial PKI state ... some files exist but not all` | Moved aside so the gateway regenerates |
| Sandbox stuck in `Error` phase | Next onboard aborts with `already exists as OpenClaw` | Deleted; `Ready` and `Running` sandboxes are never touched |
| `gateway.env` generated once, never revisited | Stale supervisor path or bind address forever | Reconciled against the declared values |
| Gateway unit rewritten to a non-trusted `ExecStart` | `service identity is not a trusted OpenShell gateway` | Reset to `/usr/local/bin/openshell-gateway` |
| Sandbox container stopped by `compose down` | Onboard tries to recreate and aborts on backup | Started again; removed only if it will not start, so onboard can recreate it |
| CLI installed into the writable layer, lost on recreate | `nemoclaw/openshell missing after install` | Published into `/root/bin` on the named volume, with symlinks from `/usr/local/bin` |

The NVIDIA installer, the image pull, and `nemoclaw onboard` run only when their
outputs are missing — no CLI on PATH, no Ready sandbox. A later
`compose restart`, or `down`/`up` without `-v`, skips that work and only re-binds
the API forwards.

If the MCP host resolves into `198.18.0.0/15` — a proxy in fake-ip mode —
`--trusted-private-host` is passed for that host only. MCP registration is never
fatal: it is optional, and a failure there must not leave the Hermes API
unreachable when onboard, approvals and the sandbox all succeeded.

## Access points

| Interface | Address | Notes |
|---|---|---|
| Hermes API | `http://<this-host-ip>:8642/v1` | OpenAI-compatible; health at `/health`; model name is `hermes-agent` |
| Hermes dashboard | `http://<this-host-ip>:18789/` | Agent sessions, skills, approvals |
| OpenShell TUI | `docker compose exec nemohermes openshell term` | Sandboxes, providers, live egress approvals; `q` quits |
| Hermes TUI | `docker compose exec nemohermes nemoclaw <sandbox> exec -- hermes dashboard --tui` | The dashboard without a browser |

Inside the sandbox the API binds `18642` and the dashboard binds its own port;
neither is reachable as a host address. Only the published `8642` and `18789`
are.

To restrict the API to this machine, change the compose `ports` bind, for
example `127.0.0.1:8642:8642`. Do not expose `8642` to the public internet
without TLS.

### Connect Open WebUI on another device

1. Wait until the journal shows the Hermes API URL.
2. On this machine, read the connection file (base URL + API key):

   ```bash
   docker compose exec nemohermes cat /root/hermes-openai.env
   ```

3. On the other device: Open WebUI → **Admin → Settings → Connections →
   OpenAI**. Base URL is `http://<this-host-ip>:8642/v1`, key is the
   `OPENAI_API_KEY` from that file. The Open WebUI **server** — not the browser —
   must be able to reach this host on `8642`.

The API key is the sandbox Hermes `API_SERVER_KEY`, not your inference provider
key.

## Lifecycle

```bash
docker compose up -d            # start; first run installs the CLI and onboards
docker compose restart          # re-bind forwards; skips onboard
docker compose down             # stop the wrapper; named volumes stay
docker compose down -v          # wipe nemohermes-home and nemohermes-docker
```

`down` keeps the CLI and the sandbox images, so the next `up` is fast. `down -v`
removes both volumes and the next start is a first start again, including the
installer and the image pull.

### Migrating from the old host-socket layout

If you previously ran a compose file that bound `/var/run/docker.sock` and
`/root:/root`:

1. `docker compose down`. Do **not** `rm -rf` the host's `/root`.
2. Remove leftover sandbox containers from the **host** engine:
   `docker ps -a --filter 'label=openshell.ai/sandbox-name'`, then `docker rm -f`
   those IDs.
3. Optionally delete only NemoClaw leftovers under the host's `/root`
   (`.nemoclaw`, `.local/state/nemoclaw`, `.local/state/openshell`,
   `bin/openshell-*`). Leave the rest of `/root` alone.
4. `docker compose up -d`. Named volumes start empty, so this is a first start.

## Rebuilding and reshipping

```bash
docker compose up -d --build                          # rebuild and run
docker compose build                                  # build only
docker save -o nemohermes-local.tar nemohermes:local  # reship
```

One Compose file covers both running and rebuilding, because `build:` and
`image:` together resolve the way this package needs:

| Situation | Result |
|---|---|
| Image present, `up` | Reuses it. No build, no registry pull, even when the `Dockerfile` changed since |
| Image present, `up --build` | Rebuilds and replaces the tag |
| Image missing, `up` | Builds from the `Dockerfile`. No attempt to pull `nemohermes:local`, which exists in no registry |

Loading a tar is therefore an optimisation, not a requirement — it just saves
the first build, and no tar is committed to this repository (`.gitignore`
excludes `*.tar`), so a fresh clone always builds. Avoid `--no-build`: it is the
one path that does attempt a registry pull, and it fails with `No such image:
nemohermes:local`.

Loading a tar does not make the first start offline either: the CLI install and
the sandbox base images are not in it.

The entrypoint is a heredoc inside the `Dockerfile`, so editing the bootstrap
logic means editing the `Dockerfile` and rebuilding. `.dockerignore` keeps the
image tar, `.env` and the docs out of the build context; the Dockerfile creates
every file it needs with heredoc `COPY` and reads nothing from the context.

## Troubleshooting

| Symptom | Action |
|---|---|
| `docker compose logs` is empty | Expected — the workload is a systemd unit. Use `docker exec nemohermes journalctl -u nemohermes -f` |
| Compose refuses to start, `env file ... not found` | `cp .env.example .env` and fill in the inference values |
| Dies in `need_inference` | `INFERENCE_BASE_URL`, `INFERENCE_MODEL` and `INFERENCE_API_KEY` must all be non-empty in `.env` |
| `resolves to fake-ip 198.18.x.x` | A local proxy is hijacking DNS. Disconnect it or exempt the domain |
| `does not resolve` | Wrong endpoint hostname, or no network access to it |
| `invalid SANDBOX_NAME` | 1–19 chars, lowercase letters/digits, single hyphens, must start with a letter |
| Container restarts / inner docker never ready | `docker compose exec nemohermes systemctl status docker`. Overlay errors usually mean `/var/lib/docker` is not on the named volume |
| `systemd user manager ... never became ready` | `docker compose exec nemohermes systemctl status user@0.service`. Onboard cannot start the gateway without it |
| `did not install the required Docker-driver binaries` | `/tmp` became tmpfs. It must not be in the compose `tmpfs:` list |
| `Timed out waiting for the sandbox mutation lock` | A lock from a dead generation the entrypoint judged live. Recreate the container; if it persists, `docker compose down` then `up -d` |
| `already exists as OpenClaw` | A sandbox left in `Error` phase. The entrypoint clears these; if it persists, `docker compose exec nemohermes openshell -g nemoclaw sandbox delete <name>` |
| Onboard fails at step 2/8 with a firewall warning | The gateway bridge route. Check the journal for `sandbox route:` and confirm `openshell-docker` exists in `docker compose exec nemohermes docker network ls` |
| Sandbox container restarts in a loop | Config drift — see [OPERATIONS.md](OPERATIONS.md#approval-mode). Check `docker compose exec nemohermes nemoclaw <sandbox> logs --tail 50` |
| `/health` returns 200 but chat fails | The forward is up and the chain is not. Run the `chat/completions` check in [README.md](README.md#verify-it-is-actually-serving) |
| API returns a model error | Send `hermes-agent`, not the `INFERENCE_MODEL` value |
| Other device cannot reach `:8642` | Use this machine's LAN IP, not `127.0.0.1`; published ports need the process to listen on `0.0.0.0` (compose sets `FORWARD_BIND`); allow the port on the host firewall |
| MCP registration failed | Non-fatal by design. See [OPERATIONS.md](OPERATIONS.md#mcp-servers) |
| First start seems stuck | It builds an 84-layer sandbox image. The healthcheck allows 15 minutes; watch the journal before concluding it hung |

## Package layout

| Path | Contents |
|---|---|
| `Dockerfile` | Packages, systemd as PID 1, inner dockerd, and the bootstrap script it runs (onboard, approvals, MCP, forwards, and the reconciliation above). No configuration, no secrets, no Open WebUI |
| `docker-compose.yml` | The only Compose file: runs the image and rebuilds it with `--build`. Carries the full rationale for every runtime setting |
| `.env.example` | Configuration template with every supported variable. Shareable |
| `.env` | Live configuration for this machine. Contains credentials; not in the repository, and keep it off shared drives |
| `.dockerignore` | Build context exclusions: any image tar, `.env`, the docs |
| `.gitignore` | Excludes `.env`, `*.tar` and editor/OS noise from git |
| `README.md` | Entry point: build, run, verify |
| `ARCHITECTURE.md` | This file |
| `OPERATIONS.md` | Day-two operations |

The built image is `nemohermes:local` (~190 MB as a tar). It is produced by
`docker compose build`, never committed here — see
[Rebuilding and reshipping](#rebuilding-and-reshipping).
