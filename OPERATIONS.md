# Operations Guide

Day-two operations for a deployment created by `docker compose up -d`: changing
the model or provider, managing MCP servers, and reading logs. Installation is
covered in [README.md](README.md); the architecture and its constraints are in
[ARCHITECTURE.md](ARCHITECTURE.md).

**Scope: the Docker path only.** This package has no bare-metal installer, no
`deploy.sh`, no `config.env`, and no in-sandbox Open WebUI. Connect a remote
Open WebUI to the Hermes API instead.

**The OpenShell gateway is the source of truth.** Hermes inside the sandbox only
executes what the gateway hands it. Change configuration through `openshell` /
`nemoclaw`, not by editing files inside the sandbox — gateway updates overwrite
sandbox-side edits, and editing Hermes `config.yaml` breaks the integrity anchor
(see [Approval mode](#approval-mode)).

## Contents

- [Conventions](#conventions)
- [Architecture](#architecture)
- [Consoles and endpoints](#consoles-and-endpoints)
- [Container and service management](#container-and-service-management)
- [Provider and model](#provider-and-model)
- [MCP servers](#mcp-servers)
- [Approval mode](#approval-mode)
- [Diagnostics](#diagnostics)
- [Troubleshooting](#troubleshooting)
- [Escape hatch](#escape-hatch)

## Conventions

Two kinds of commands appear below.

Host commands run in this folder, next to `docker-compose.yml`:

```bash
cd /path/to/Nemohermes_Docker_Deployment
```

Container commands are the `openshell` / `nemoclaw` CLI, which exists only
*inside* the wrapper. Either prefix each one:

```bash
docker compose exec nemohermes openshell inference get
```

…or open a shell once and drop the prefix for the rest of the session:

```bash
docker compose exec nemohermes bash
```

`<sandbox>` is your `SANDBOX_NAME` from `.env`:

```bash
grep '^SANDBOX_NAME=' .env
```

Examples below use the prefix form so each one is copy-pasteable on its own.

## Architecture

```text
Open WebUI on another device
  → http://<this-host-ip>:8642/v1     (openshell forward → sandbox 18642)
    → Hermes API server in the sandbox
      → OpenShell gateway inference layer
        → provider (OpenAI-compatible endpoint) → model
```

Open WebUI shows a single Hermes agent model. Its base URL points at the Hermes
API server, not at your provider, so **switching models is a gateway change, not
an Open WebUI setting**. Requests to the API always use the model name
`hermes-agent`.

| Concern | Where you change it |
|---|---|
| Inference endpoint, model, key at deploy time | `.env`, then `docker compose up -d` |
| Provider and model at runtime | `openshell provider …` / `openshell inference …` |
| MCP over HTTPS | `nemoclaw <sandbox> mcp …` |
| MCP over local stdio | `hermes mcp …` inside the sandbox (the gateway has no local-process transport) |
| Approval mode | `APPROVALS_MODE` in `.env`, then `docker compose up -d` |
| Published ports, volumes, restart policy | `docker-compose.yml` |
| Bootstrap logic | The entrypoint heredoc in `Dockerfile`; requires a rebuild |

## Consoles and endpoints

The OpenShell gateway is a process with no web interface; its console is a TUI.
Hermes ships a browser dashboard of its own, separate from Open WebUI.

| Surface | Open it | Use it for |
|---|---|---|
| Hermes API | `http://<host>:8642/v1` | OpenAI-compatible access for a remote Open WebUI; health at `/health` |
| Hermes dashboard | `http://<host>:18789/` | Agent sessions, skills, approvals |
| OpenShell TUI | `docker compose exec nemohermes openshell term` | Sandboxes, providers, live egress and network approvals; `q` quits |
| Hermes TUI | `docker compose exec nemohermes nemoclaw <sandbox> exec -- hermes dashboard --tui` | The dashboard without a browser |
| Open WebUI | Not installed. Point a remote instance at the Hermes API | Chat UI |

Inside the sandbox the API binds `18642` and the dashboard binds its own port.
Neither is a host address; only the published `8642` and `18789` are. The
entrypoint recreates these forwards on every start, and skips one when the local
port is already listening.

```bash
docker compose exec nemohermes openshell -g nemoclaw forward list
```

Connection file for a remote Open WebUI (base URL + API key):

```bash
docker compose exec nemohermes cat /root/hermes-openai.env
```

## Container and service management

```bash
docker compose ps
docker compose restart                 # re-binds forwards; skips onboard
docker compose down                    # stop; named volumes stay
docker compose up -d                   # apply an .env change
```

Inside the container the workload is a systemd unit, not PID 1, so
`docker compose logs` is usually empty:

```bash
docker exec nemohermes journalctl -u nemohermes -f      # bootstrap log
docker compose exec nemohermes systemctl status nemohermes.service
docker compose exec nemohermes systemctl status docker.service
docker compose exec nemohermes systemctl --user status nemoclaw-openshell-gateway.service
```

Sandboxes are created by the **inner** dockerd, so they never appear in the
host's `docker ps`:

```bash
docker compose exec nemohermes docker ps
docker compose exec nemohermes docker ps -a \
  --filter 'label=openshell.ai/sandbox-name=<sandbox>'
```

The gateway runs as a systemd **user** unit that onboard registered. Do not start
a second copy by hand — NemoClaw refuses to attach to a listener it cannot prove
that unit owns, and a second copy is a bind conflict. Restart it instead:

```bash
docker compose exec nemohermes systemctl --user restart nemoclaw-openshell-gateway.service
```

## Provider and model

For a permanent change, edit `INFERENCE_MODEL` (or the base URL and key) in
`.env` and run `docker compose up -d`. The commands below change the live
gateway state without a restart, which is what you want when experimenting.

Inspect the current state before changing anything:

```bash
docker compose exec nemohermes openshell inference get           # active provider + model
docker compose exec nemohermes openshell provider list           # registered providers
docker compose exec nemohermes openshell provider list-profiles  # built-in profiles
```

Switch model within the same provider — the common case:

```bash
docker compose exec nemohermes openshell inference set \
  --provider <provider> --model <model>
# optional: --timeout <seconds>, --no-verify to skip validation
```

Rotate a key or change the endpoint:

```bash
docker compose exec nemohermes openshell provider update <provider> \
  --credential <KEY>=<new-value> \
  --config <KEY>=<new-value>
# expiring credentials: --credential-expires-at <KEY>=<timestamp>
```

Add a provider:

```bash
docker compose exec nemohermes openshell provider list-profiles
docker compose exec nemohermes openshell provider profile import <file-or-dir>
docker compose exec nemohermes openshell provider update <provider> \
  --credential KEY=VALUE --config KEY=VALUE
docker compose exec nemohermes openshell inference set \
  --provider <provider> --model <model>
```

Remove one with `openshell provider delete <provider>`.

Changes take effect on the next request, so send a message to confirm. If the
sandbox still behaves as before, restart the gateway:

```bash
docker compose exec nemohermes systemctl --user restart nemoclaw-openshell-gateway.service
```

A live change made this way is lost if you later recreate the container with a
different `.env`, because the entrypoint onboards from `.env`. Keep anything
permanent in `.env`.

## MCP servers

### Gateway-managed (HTTPS)

This is the path the entrypoint uses. The URL must be public HTTPS.

```bash
docker compose exec nemohermes nemoclaw <sandbox> mcp add <name> \
  --url https://<host>/mcp --env <KEY>
docker compose exec nemohermes nemoclaw <sandbox> mcp list
docker compose exec nemohermes nemoclaw <sandbox> mcp status <name> --probe   # credentials
docker compose exec nemohermes nemoclaw <sandbox> mcp status <name> --tools   # discovery
docker compose exec nemohermes nemoclaw <sandbox> mcp remove <name>
```

`--env <KEY>` names a credential registered with OpenShell; it is not the token
itself. The sandbox only ever sees an `openshell:resolve:env:<KEY>` placeholder,
which the gateway resolves on egress while enforcing the MCP policy.

The deployment registers the configured router as `mcp-router`. To add it after
the fact, set `MCP_URL` and `MCP_ROUTER_TOKEN` in `.env` and recreate — the
entrypoint registers it on start and skips it when it is already present:

```bash
docker compose up -d
```

Registration failure is logged as a warning and never fatal: MCP is optional,
and a failure there must not leave the Hermes API unreachable when onboard,
approvals and the sandbox all succeeded. Check the journal for
`mcp add failed` if a server is missing.

If the MCP host resolves into `198.18.0.0/15` — a proxy in fake-ip mode — the
entrypoint passes `--trusted-private-host` for that host only, because NemoClaw
otherwise refuses to register what looks like a private address.

### Local stdio

Local process MCP servers bypass the gateway and are configured inside the
sandbox:

```bash
docker compose exec nemohermes nemoclaw <sandbox> exec -- hermes mcp add <name> \
  --command npx --args -y @modelcontextprotocol/server-filesystem /sandbox/data
docker compose exec nemohermes nemoclaw <sandbox> exec -- hermes mcp list
docker compose exec nemohermes nemoclaw <sandbox> exec -- hermes mcp test <name>
docker compose exec nemohermes nemoclaw <sandbox> exec -- hermes mcp remove <name>
```

`hermes mcp` maintains its own state alongside the config anchor, so these
commands are safe — unlike hand-editing `config.yaml`. New servers apply from
the next agent request.

## Approval mode

Change it through `.env` rather than by hand:

```bash
# edit APPROVALS_MODE in .env to off | smart | manual
docker compose up -d
```

NemoClaw pins the SHA-256 of `/sandbox/.hermes/config.yaml` in
`/sandbox/.hermes/.config-hash`. Writing the config without updating that anchor
makes the container fail with `HERMES_MCP_CONFIG_DRIFT` and restart in a loop.
The entrypoint does the whole sequence: back up config and anchor, set the mode,
rewrite the anchor, restart the sandbox, verify, and roll back if it comes up
unhealthy.

Leaving `APPROVALS_MODE` empty skips the step entirely and leaves whatever the
sandbox already has.

Check the current value at any time:

```bash
docker compose exec nemohermes nemoclaw <sandbox> exec -- hermes config get approvals.mode
```

## Diagnostics

```bash
docker exec nemohermes journalctl -u nemohermes -f              # bootstrap log
docker compose exec nemohermes openshell -g nemoclaw sandbox list
docker compose exec nemohermes nemoclaw <sandbox> doctor        # sandbox + gateway health
docker compose exec nemohermes nemoclaw <sandbox> logs --tail 50
docker compose exec nemohermes docker ps -a \
  --filter 'label=openshell.ai/sandbox-name=<sandbox>'
docker compose exec nemohermes openshell -g nemoclaw forward list
```

End-to-end check — `/health` returning 200 only proves the forward is up:

```bash
KEY=$(docker compose exec -T nemohermes \
        sed -n 's/^OPENAI_API_KEY=//p' /root/hermes-openai.env | tr -d '\r')

curl -s -X POST http://127.0.0.1:8642/v1/chat/completions \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"hermes-agent","messages":[{"role":"user","content":"ping"}]}'
```

A sandbox container in `restarting` state almost always means config drift.

## Troubleshooting

| Symptom | Action |
|---|---|
| Model change had no effect | Confirm with `openshell inference get`, send a new message, then restart the gateway unit |
| Model change lost after recreate | Live gateway changes are not written back to `.env`. Put permanent values in `.env` |
| Wanted provider not listed | `openshell provider list-profiles`; import a custom profile if it is not built in |
| API rejects the model name | Send `hermes-agent`, not the `INFERENCE_MODEL` value |
| Need a local (npx) MCP server | The gateway only supports HTTPS; use `hermes mcp add --command` |
| MCP server missing after start | Non-fatal by design. Check the journal for `mcp add failed`, then re-add manually |
| MCP credential resolution fails | `nemoclaw <sandbox> mcp status <name> --probe`; verify the `--env` key is registered as an OpenShell credential |
| Sandbox container restarts in a loop | Config drift. Re-apply `APPROVALS_MODE` via `docker compose up -d`, and check `nemoclaw <sandbox> logs --tail 50` |
| Edited Hermes config by hand | Re-apply through `docker compose up -d` (or `openshell inference set`) to restore a consistent, anchored state |
| Dashboard or API port not answering | Check `openshell -g nemoclaw forward list` first — the app is usually running and only the tunnel died. `docker compose restart` recreates them |
| Other device cannot reach `:8642` | Use this machine's LAN IP, not `127.0.0.1`; allow the port on the host firewall |
| `docker compose logs` empty | Expected. Use `docker exec nemohermes journalctl -u nemohermes -f` |

For start-up and onboard failures — inner dockerd, the user manager, the gateway
bridge route, stale locks — see
[ARCHITECTURE.md](ARCHITECTURE.md#troubleshooting).

## Escape hatch

Editing Hermes configuration inside the sandbox works, but it is overwritten by
the next gateway `inference set` and requires an anchor resync afterwards:

```bash
docker compose exec nemohermes nemoclaw <sandbox> exec -- hermes config set model.default <model>
docker compose exec nemohermes nemoclaw <sandbox> exec -- hermes config edit
```

Use this for temporary debugging only. For anything you want to keep, go through
`.env` or the gateway commands above.
