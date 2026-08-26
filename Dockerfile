# syntax=docker/dockerfile:1
#
# Wrapper image for the Hermes sandbox: Ubuntu, systemd as PID 1, an inner
# dockerd, and the bootstrap script that runs onboard, approvals, MCP and the
# port forwards.
#
# This file holds no secrets and no per-deployment configuration. Compose
# injects all of that from .env at container start (env_file), so the image is
# byte-identical on every machine, changing a key never triggers a rebuild, and
# nothing sensitive lands in an image layer. The ENV below is runtime constants
# only.
#
# A normal deploy does not build this file: it loads the prebuilt tar, and
# Compose reuses that image rather than building. Rebuild only after changing
# the RUN layers or the entrypoint below:
#
#   docker compose up -d --build
#
# To reship the result as a tar, see README.md.

FROM ubuntu:24.04

# HOME stays /root. systemd carries a synthesized user record for root with
# the home directory hardcoded to /root and ignores /etc/passwd for it, so the
# user manager resolves %h, %E and %S -- and its unit search path -- under
# /root no matter what HOME says. Point HOME elsewhere and the gateway unit is
# written where systemd will not look, and onboard fails step 2/8 with
# "service identity query returned invalid metadata".
#
# Compose mounts a named volume at /root (not the host's /root) and another at
# /var/lib/docker. NemoClaw hands absolute paths under HOME to *this*
# container's dockerd, which resolves them in the same filesystem, so the old
# Docker-out-of-Docker empty-directory bind-mount failure does not apply.
#
# NOTE: do NOT set NEMOCLAW_GATEWAY_BIND_ADDRESS=0.0.0.0 here. It looks like
# the fix for "sandbox containers cannot reach the gateway", but NemoClaw
# rejects it outright: "not supported for the OpenShell Docker-driver gateway
# while gateway JWT auth is active". The gateway is loopback-only by design.
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    IN_CONTAINER=1 \
    FORWARD_BIND=0.0.0.0 \
    HERMES_API_PORT=8642 \
    HERMES_DASHBOARD_PORT=18789 \
    HOME=/root \
    PATH="/root/bin:/root/.local/bin:/usr/local/bin:${PATH}"

# ---- packages (the NVIDIA CLI is installed at first run instead: it needs a
# live Docker engine, which does not exist at build time) ----
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      binutils \
      zstd \
      lsof \
      python3 \
      sudo \
      systemd \
      systemd-sysv \
      dbus \
      dbus-user-session \
      docker.io \
      docker-buildx \
      iptables \
      nftables \
      procps \
      gawk \
      openssl \
      openssh-client \
      xz-utils \
      iproute2 \
 && rm -rf /var/lib/apt/lists/* \
 && echo 'root ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/root \
 && chmod 440 /etc/sudoers.d/root

# ---- systemd as PID 1 ----
# NemoClaw starts the OpenShell gateway as a systemd *user* unit and refuses to
# attach to a gateway it cannot prove is supervised: see
# SUPPORTED_GATEWAY_SUPERVISOR_KINDS in the nemoclaw source, which accepts only
# systemd-system and systemd-user. Onboard therefore cannot complete without a
# real init. Mask the units that want hardware or a tty, enable inner docker
# (do not mask docker.service / docker.socket: Ubuntu's docker.service
# Requires=docker.socket), and pre-enable lingering so root's user manager
# (user@0.service) starts at boot instead of waiting for a login that never
# happens in a container. containerd is a dependency of docker.service and is
# left unmasked.
COPY <<'DAEMONJSON' /etc/docker/daemon.json
{
  "storage-driver": "overlay2",
  "exec-opts": ["native.cgroupdriver=systemd"],
  "iptables": true,
  "ip-forward": true
}
DAEMONJSON
RUN systemctl mask \
      systemd-udevd.service \
      systemd-udevd-kernel.socket \
      systemd-udevd-control.socket \
      systemd-modules-load.service \
      systemd-journald-audit.socket \
      sys-kernel-config.mount \
      sys-kernel-debug.mount \
      sys-kernel-tracing.mount \
      getty.target \
      console-getty.service \
      getty@tty1.service \
 && systemctl set-default multi-user.target \
 && systemctl enable docker.service docker.socket \
 && mkdir -p /var/lib/systemd/linger \
 && touch /var/lib/systemd/linger/root

# ---- bootstrap script: onboard, approvals, MCP, Hermes API/dashboard ----
COPY <<'ENTRY' /usr/local/sbin/nemohermes
#!/usr/bin/env bash
set -euo pipefail

# systemd hands services a clean environment, so nothing compose put in
# `env_file` reaches this script -- those values live only in PID 1's
# environment. Read them back from there, whitelisted, before anything else
# runs. Without this the script sees no INFERENCE_API_KEY and dies in
# need_inference even though .env was correct.
if [ -r /proc/1/environ ]; then
  while IFS= read -r -d '' kv; do
    case "$kv" in
      INFERENCE_*|SANDBOX_NAME=*|APPROVALS_MODE=*|MCP_*|FORWARD_BIND=*|\
      HERMES_*|IN_CONTAINER=*|AGENT=*|ONBOARD_FRESH=*|SANDBOX_WAIT_SECS=*|\
      DOCKER_WAIT_SECS=*|USER_MANAGER_WAIT_SECS=*|NEMOCLAW_*)
        export "$kv"
        ;;
    esac
  done < /proc/1/environ
fi

export HOME="${HOME:-/root}"
export PATH="${HOME}/bin:${HOME}/.local/bin:/usr/local/bin:${PATH}"
for nvmbin in "${HOME}"/.nvm/versions/node/*/bin; do
  [ -d "$nvmbin" ] && export PATH="${nvmbin}:${PATH}"
done

log() { echo "[nemohermes] $*"; }
die() { echo "[nemohermes] ERROR: $*" >&2; exit 1; }
log_warn_mcp() { echo "[nemohermes] WARN: $*" >&2; }

sandbox_name_valid() {
  local name="${1:-}"
  local n=${#name}
  [ "$n" -ge 1 ] && [ "$n" -le 19 ] || return 1
  case "$name" in *--*) return 1 ;; esac
  [[ "$name" =~ ^[a-z]([a-z0-9-]*[a-z0-9])?$ ]]
}

check_inference_dns() {
  local host ip
  host="$(printf '%s' "${INFERENCE_BASE_URL}" | sed -E 's#^[a-z][a-z0-9+.-]*://([^/:]+).*#\1#')"
  [ -n "${host}" ] || return 0
  case "${host}" in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*) return 0 ;;
  esac
  ip="$(getent ahostsv4 "${host}" 2>/dev/null | awk 'NR==1{print $1}')"
  case "${ip}" in
    198.18.*|198.19.*)
      die "Inference host ${host} resolves to fake-ip ${ip} (proxy fake-ip). Exempt the domain or disable the proxy."
      ;;
    "")
      die "Inference host ${host} does not resolve."
      ;;
  esac
  log "inference host ${host} -> ${ip}"
}

cid() {
  docker ps -a --filter "label=openshell.ai/sandbox-name=${SANDBOX_NAME}" --format '{{.ID}}' | awk 'NR==1{print}'
}

sandbox_is_ready() {
  timeout 5 openshell -g nemoclaw sandbox list 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g' \
    | grep -q "${SANDBOX_NAME}[[:space:]].*Ready" && return 0
  return 1
}

first_ready_sandbox() {
  timeout 5 openshell -g nemoclaw sandbox list 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g' \
    | awk 'NR > 1 && $NF == "Ready" { print $1; exit }' || true
  return 0
}

# Gateway and the recovered container can take a few seconds to answer
# GetSandbox. Treat "list failed" as not-ready rather than jumping into
# onboard, which would otherwise run on every compose restart.
wait_sandbox_listed_ready() {
  local secs="${SANDBOX_READY_GRACE_SECS:-8}" waited=0
  while [ "$waited" -lt "$secs" ]; do
    sandbox_is_ready && return 0
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

wait_sandbox_ready() {
  local secs="${SANDBOX_WAIT_SECS:-180}" waited=0
  log "waiting for sandbox '${SANDBOX_NAME}' Ready (max ${secs}s)"
  while [ "$waited" -lt "$secs" ]; do
    sandbox_is_ready && return 0
    sleep 5
    waited=$((waited + 5))
  done
  return 1
}

sync_config_hash() {
  local id="$1" new_hash
  docker cp "${id}:/sandbox/.hermes/config.yaml" /tmp/hm-config.yaml
  docker cp "${id}:/sandbox/.hermes/.config-hash" /tmp/hm-config-hash
  new_hash="$(sha256sum /tmp/hm-config.yaml | awk '{print $1}')"
  awk -v h="$new_hash" 'NR==1{print h "  /sandbox/.hermes/config.yaml"; next} {print}' \
    /tmp/hm-config-hash > /tmp/hm-config-hash.new
  docker cp /tmp/hm-config-hash.new "${id}:/sandbox/.hermes/.config-hash"
}

lan_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}'
}

write_openai_env() {
  local id="$1" key host_hint=""
  docker cp "${id}:/sandbox/.hermes/.env" /tmp/hermes.env
  key="$(awk -F= '/^API_SERVER_KEY=/{print substr($0, index($0,"=")+1); exit}' /tmp/hermes.env | tr -d '"' | tr -d "'")"
  [ -n "$key" ] || die "sandbox /sandbox/.hermes/.env has no API_SERVER_KEY"
  # Published ports land on the host. This container's eth0 is a compose-network
  # address other devices cannot route to, so do not put it in the hint file.
  if [ -z "${IN_CONTAINER:-}" ]; then
    host_hint="$(lan_ip || true)"
  fi
  umask 077
  cat > "${HOME}/hermes-openai.env" <<EOF
# Point another device's Open WebUI at this (Admin → Connections → OpenAI).
# Use this machine's LAN IP, not 127.0.0.1, from the other device.
OPENAI_API_BASE_URL=http://${host_hint:-<this-host-ip>}:${HERMES_API_PORT}/v1
OPENAI_API_KEY=${key}
EOF
}

[ -z "${INFERENCE_BASE_URL:-}" ] && unset INFERENCE_BASE_URL || true
[ -z "${INFERENCE_MODEL:-}" ] && unset INFERENCE_MODEL || true
[ -z "${INFERENCE_API_KEY:-}" ] && unset INFERENCE_API_KEY || true
SANDBOX_NAME="${SANDBOX_NAME:-main}"

sandbox_name_valid "${SANDBOX_NAME}" \
  || die "invalid SANDBOX_NAME '${SANDBOX_NAME}' (1-19 lowercase letters/digits, start with a letter, single hyphens)"

need_inference() {
  [ -n "${INFERENCE_BASE_URL:-}" ] && [ -n "${INFERENCE_MODEL:-}" ] && [ -n "${INFERENCE_API_KEY:-}" ] \
    || die "Set INFERENCE_BASE_URL, INFERENCE_MODEL and INFERENCE_API_KEY in .env (cp .env.example .env), then: docker compose up -d"
}

AGENT="${AGENT:-hermes}"
APPROVALS_MODE="${APPROVALS_MODE:-manual}"
BIND="${FORWARD_BIND:-0.0.0.0}"
HERMES_API_PORT="${HERMES_API_PORT:-8642}"
HERMES_DASHBOARD_PORT="${HERMES_DASHBOARD_PORT:-18789}"
LOG_DIR=/var/log
mkdir -p "$LOG_DIR" /var/run/nemohermes

# ---- gateway bind address reconciliation ----
# NemoClaw writes OPENSHELL_BIND_ADDRESS into gateway.env once, at first
# onboard, and never revisits it. That file lives in the persisted /root
# volume, so a container that was first started before this setting existed
# keeps a loopback-only gateway forever and every later onboard fails step 2/8
# with a firewall warning. Reconcile the file with the declared value and
# restart the unit when they disagree.
reconcile_gateway_bind() {
  local want="${NEMOCLAW_GATEWAY_BIND_ADDRESS:-}" f="${HOME}/.config/openshell/gateway.env" have
  [ -n "$want" ] || return 0
  [ -f "$f" ] || return 0
  have="$(awk -F= '/^OPENSHELL_BIND_ADDRESS=/{print $2; exit}' "$f")"
  [ -n "$have" ] || return 0
  [ "$have" = "$want" ] && return 0
  log "gateway bind ${have} -> ${want} (rewriting $(basename "$f"))"
  sed -i "s|^OPENSHELL_BIND_ADDRESS=.*|OPENSHELL_BIND_ADDRESS=${want}|" "$f"
  systemctl --user restart nemoclaw-openshell-gateway.service 2>/dev/null || true
  sleep 5
}

# Inner dockerd is a systemd unit, not a bind-mounted host socket. It can lag
# a few seconds behind PID 1 even with After=docker.service.
wait_docker() {
  local secs="${DOCKER_WAIT_SECS:-90}" waited=0
  while [ "$waited" -lt "$secs" ]; do
    if [ -S /var/run/docker.sock ] && docker info >/dev/null 2>&1; then
      log "inner docker engine ready"
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done
  return 1
}
wait_docker || die "inner docker engine never became ready; check: systemctl status docker.service"

# ---- systemd user manager ----
# Onboard drives the gateway through `systemctl --user`, which needs root's
# user bus to be live. Lingering is baked into the image, so user@0.service
# comes up on its own; this only waits for it and fails loudly if it does not,
# because the alternative is onboard aborting at step 2/8 with a message that
# blames systemctl rather than the missing bus.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/0}"
wait_user_manager() {
  local secs="${USER_MANAGER_WAIT_SECS:-90}" waited=0
  systemctl start user@0.service >/dev/null 2>&1 || true
  while [ "$waited" -lt "$secs" ]; do
    if systemctl --user is-system-running >/dev/null 2>&1 \
       || [ "$(systemctl --user is-system-running 2>/dev/null)" = "degraded" ]; then
      log "systemd user manager ready (XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR})"
      return 0
    fi
    sleep 3
    waited=$((waited + 3))
  done
  return 1
}
wait_user_manager || die "systemd user manager (user@0.service) never became ready; onboard cannot start the gateway. Check: systemctl status user@0.service"
reconcile_gateway_bind

# ---- sandbox -> gateway route ----
# NemoClaw pins the gateway to 127.0.0.1 and rejects an override outright
# ("NEMOCLAW_GATEWAY_BIND_ADDRESS=0.0.0.0 is not supported ... while gateway
# JWT auth is active"). Sandbox containers, though, dial it at
# host.openshell.internal, which Docker resolves to the openshell-docker bridge
# gateway address -- where a loopback-only listener never answers. Onboard
# reports that as a host firewall problem and no firewall rule can fix it.
#
# Publish loopback onto the bridge address only. Binding 0.0.0.0 would have put
# the gateway on every interface including the LAN; this exposes it to exactly
# the one subnet that has to reach it. route_localnet is what lets a DNAT
# target 127.0.0.1 from an external interface.
install_gateway_bridge_route() {
  local net="${OPENSHELL_DOCKER_NETWORK_NAME:-openshell-docker}" gwip
  gwip="$(docker network inspect "$net" --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || true)"
  [ -n "$gwip" ] || return 1
  sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null 2>&1 || true
  iptables -t nat -C PREROUTING -d "$gwip" -p tcp --dport 8080 \
    -j DNAT --to-destination 127.0.0.1:8080 2>/dev/null && return 0
  iptables -t nat -A PREROUTING -d "$gwip" -p tcp --dport 8080 \
    -j DNAT --to-destination 127.0.0.1:8080 2>/dev/null || return 1
  log "sandbox route: ${gwip}:8080 -> 127.0.0.1:8080"
}

# The bridge does not exist until the gateway creates it, which happens inside
# onboard step 2 -- moments before the probe that needs the route. Install it
# now if a previous run left the network behind, and otherwise race a watcher
# against onboard so the first run usually succeeds too. If the watcher loses,
# Restart=on-failure retries and the network is there by then.
watch_gateway_bridge_route() {
  (
    n=0
    while [ "$n" -lt 80 ]; do
      install_gateway_bridge_route && break
      sleep 2
      n=$((n + 1))
    done
  ) &
}

install_gateway_bridge_route || watch_gateway_bridge_route

# Compose publishes 8642/18789 onto this container's eth0. OpenShell's own
# forwards bind 127.0.0.1, so docker-proxy would otherwise get connection
# reset. Same route_localnet trick as the gateway DNAT.
install_published_port_routes() {
  local p
  sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null 2>&1 || true
  for p in "${HERMES_API_PORT}" "${HERMES_DASHBOARD_PORT}"; do
    [ -n "$p" ] || continue
    iptables -t nat -C PREROUTING -p tcp --dport "$p" \
      -j DNAT --to-destination "127.0.0.1:${p}" 2>/dev/null && continue
    iptables -t nat -A PREROUTING -p tcp --dport "$p" \
      -j DNAT --to-destination "127.0.0.1:${p}" 2>/dev/null || return 1
    log "published port ${p} -> 127.0.0.1:${p}"
  done
}
install_published_port_routes || log "could not DNAT published API/dashboard ports to loopback"

# ---- stale lifecycle locks ----
# NemoClaw guards sandbox mutations with lock files under ~/.nemoclaw/state,
# recording the owner pid and PID namespace. Those live in the persisted /root
# volume, so a container that is recreated while a lock is held leaves the lock
# behind forever: every later onboard then dies with "Timed out waiting for the
# sandbox mutation lock (owner pid N)" naming a process from a container
# generation that no longer exists. NemoClaw does not reclaim them itself.
#
# Drop only locks that provably cannot be live: a different PID namespace, or a
# pid with nothing running under it. A lock whose owner is alive in this
# namespace is left alone -- removing that would let two mutations race.
clear_stale_lifecycle_locks() {
  local dir="${HOME}/.nemoclaw/state/mcp-lifecycle-locks" cur f ns pid name
  [ -d "$dir" ] || return 0
  cur="$(readlink /proc/self/ns/pid 2>/dev/null || true)"
  for f in "$dir"/*.lock; do
    [ -f "$f" ] || continue
    ns="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pidNamespaceIdentity",""))' "$f" 2>/dev/null || true)"
    pid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pid",""))' "$f" 2>/dev/null || true)"
    name="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("sandboxName",""))' "$f" 2>/dev/null || true)"
    if [ -n "$cur" ] && [ -n "$ns" ] && [ "$ns" != "$cur" ]; then
      log "clearing lock from a dead container generation: ${name:-?} (ns ${ns})"
    elif [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      log "clearing lock with no live owner: ${name:-?} (pid ${pid})"
    else
      continue
    fi
    rm -f "$f" "${f}.containment" "${f}".candidate-* 2>/dev/null || true
  done
}

clear_stale_lifecycle_locks

# ---- GPU passthrough ----
# Preflight already reports "Sandbox GPU: disabled (no NVIDIA GPU detected)",
# but sandbox creation still runs a Docker GPU compatibility patch. On a
# GPU-less host that patch fails, the create stream exits 1, and the sandbox is
# left in Error phase -- which then also blocks the next run as a name/agent
# conflict. Decide from the hardware rather than hardcoding either way: a real
# NVIDIA host must keep passthrough, and an explicit value in .env always wins.
if [ -z "${NEMOCLAW_SANDBOX_GPU:-}" ]; then
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L 2>/dev/null | grep -q '^GPU'; then
    log "NVIDIA GPU present; leaving sandbox GPU passthrough enabled"
  else
    export NEMOCLAW_SANDBOX_GPU=0
    log "no NVIDIA GPU; setting NEMOCLAW_SANDBOX_GPU=0 to skip the Docker GPU patch"
  fi
fi

# ---- errored sandbox from a failed create ----
# A create that dies partway leaves the sandbox in Error phase, and the next
# onboard refuses it as "already exists as OpenClaw" -- a misleading message
# that has nothing to do with agent choice. An Error-phase sandbox holds no
# state worth keeping, so clear it; anything Ready or Running is left alone.
clear_errored_sandbox() {
  local row phase
  # `|| true`: the script runs under `set -o pipefail`, and openshell exits
  # non-zero whenever the gateway is not up yet. Without the guard the failing
  # pipeline propagates through the assignment and set -e kills the script here,
  # before onboard ever runs.
  row="$(timeout 5 openshell -g nemoclaw sandbox list 2>/dev/null | awk -v n="${SANDBOX_NAME}" '$1 == n {print}' | head -1 || true)"
  [ -n "$row" ] || return 0
  phase="$(printf '%s' "$row" | sed 's/\x1b\[[0-9;]*m//g' | awk '{print $NF}')"
  [ "$phase" = "Error" ] || return 0
  log "sandbox '${SANDBOX_NAME}' is in Error phase from a failed create; deleting it"
  openshell -g nemoclaw sandbox delete "${SANDBOX_NAME}" >/dev/null 2>&1 || true
  sleep 3
}

# compose down stops inner containers. Restart them if the bind sources still
# exist; otherwise remove so onboard can recreate with paths under HOME/bin.
# Match any OpenShell sandbox label — the NVIDIA installer may have created
# one named after the agent rather than SANDBOX_NAME. Policy fetch needs the
# gateway; callers must start it first.
recover_stopped_sandbox() {
  local id status n=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    status="$(docker inspect -f '{{.State.Status}}' "$id" 2>/dev/null || true)"
    case "$status" in
      running|restarting|"") continue ;;
    esac
    log "sandbox container ${id} is ${status}; attempting start"
    docker start "$id" >/dev/null 2>&1 || true
    n=0
    while [ "$n" -lt 20 ]; do
      status="$(docker inspect -f '{{.State.Status}}' "$id" 2>/dev/null || true)"
      [ "$status" = "running" ] && break
      sleep 1
      n=$((n + 1))
    done
    if [ "$status" != "running" ]; then
      log "sandbox container ${id} would not start (status ${status:-missing}); removing so onboard can recreate"
      docker rm "$id" >/dev/null 2>&1 || true
    fi
  done <<EOF
$(docker ps -aq --filter "label=openshell.ai/sandbox-name" 2>/dev/null)
EOF
}

# ---- CLI and supervisor on a stable HOME path ----
# The NVIDIA installer often drops `openshell` in /usr/local/bin (wrapper
# writable layer). That vanishes on `compose down`. Copy it, plus the
# supervisor binaries, into HOME/bin (the named volume) so the next start
# finds them on PATH without re-running the installer.
publish_shared_binaries() {
  local dst="${HOME}/bin" name src
  mkdir -p "$dst" /usr/local/bin
  for name in openshell openshell-sandbox openshell-gateway; do
    src="$(command -v "$name" 2>/dev/null || true)"
    [ -n "$src" ] || continue
    case "$src" in "$dst"/*) ;; *)
      if [ ! -e "$dst/$name" ] || ! cmp -s "$src" "$dst/$name" 2>/dev/null; then
        # Volume copy; skip if src is already the symlink we are about to write.
        if [ ! -L "$src" ]; then
          install -m 755 "$src" "$dst/$name" || return 1
          log "published $name to $dst"
        fi
      fi
      ;;
    esac
    rmdir "/usr/local/bin/$name" 2>/dev/null || true
    if [ -x "$dst/$name" ]; then
      ln -sfn "$dst/$name" "/usr/local/bin/$name"
    fi
  done
  [ -x "$dst/openshell-sandbox" ] || return 1
  export NEMOCLAW_OPENSHELL_SANDBOX_BIN="/usr/local/bin/openshell-sandbox"
}

# gateway.env is generated once and keeps whatever supervisor path was current
# then. Reconcile it the same way the bind address is reconciled.
reconcile_supervisor_bin() {
  local want="${NEMOCLAW_OPENSHELL_SANDBOX_BIN:-}" f="${HOME}/.config/openshell/gateway.env" have
  [ -n "$want" ] || return 0
  [ -f "$f" ] || return 0
  have="$(awk -F= '/^OPENSHELL_DOCKER_SUPERVISOR_BIN=/{print $2; exit}' "$f")"
  [ "$have" = "$want" ] && return 0
  log "supervisor bin ${have:-unset} -> ${want}"
  if [ -n "$have" ]; then
    sed -i "s|^OPENSHELL_DOCKER_SUPERVISOR_BIN=.*|OPENSHELL_DOCKER_SUPERVISOR_BIN=${want}|" "$f"
  else
    printf 'OPENSHELL_DOCKER_SUPERVISOR_BIN=%s\n' "$want" >> "$f"
  fi
}

# The installer writes ExecStart=/usr/local/bin/openshell-gateway and NemoClaw
# refuses any other path ("service identity is not a trusted OpenShell
# gateway"). An earlier revision rewrote that to HOME/bin; put it back. The
# file at /usr/local/bin is a symlink onto the volume (see publish_shared_binaries).
reconcile_gateway_unit_bin() {
  local unit="${HOME}/.config/systemd/user/nemoclaw-openshell-gateway.service"
  [ -f "$unit" ] || return 0
  grep -q '/root/bin/openshell-gateway' "$unit" || return 0
  log "gateway unit ExecStart /root/bin/openshell-gateway -> /usr/local/bin/openshell-gateway"
  sed -i "s|/root/bin/openshell-gateway|/usr/local/bin/openshell-gateway|g" "$unit"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
}

# Start the unit onboard already registered — not a second copy. Sandbox
# recover needs :8080 before docker start, or policy fetch fails and the
# container exits; onboard then tries to recreate and aborts on backup.
ensure_managed_gateway() {
  local n=0
  systemctl --user reset-failed nemoclaw-openshell-gateway.service >/dev/null 2>&1 || true
  systemctl --user start nemoclaw-openshell-gateway.service >/dev/null 2>&1 || true
  while [ "$n" -lt 25 ]; do
    if ss -lnt 2>/dev/null | grep -Eq ':8080[[:space:]]'; then
      return 0
    fi
    sleep 1
    n=$((n + 1))
  done
  return 0
}



# Local image first; docker pull only when the ref is missing.
# Onboard also does this for the managed Hermes image (exact digest).
ensure_image() {
  local ref="$1"
  [ -n "$ref" ] || return 0
  if docker image inspect "$ref" >/dev/null 2>&1; then
    log "using local image ${ref}"
    return 0
  fi
  log "image not local, pulling ${ref}"
  docker pull "$ref" || log "pull failed for ${ref} (onboard may still resolve another candidate)"
}

ensure_sandbox_images() {
  local ref
  for ref in ghcr.io/nvidia/nemoclaw/hermes-sandbox-base:latest \
             ghcr.io/nvidia/nemoclaw/sandbox-base:latest \
             ${SANDBOX_PULL_IMAGES:-}; do
    ensure_image "$ref"
  done
}

# ---- NVIDIA CLI (binaries only) + onboard (the gateway creates the sandbox) ----
if ! command -v nemoclaw >/dev/null || ! command -v openshell >/dev/null; then
  need_inference
  check_inference_dns
  log "installing OpenShell/NemoClaw CLI"
  curl -fsSL https://www.nvidia.com/nemoclaw.sh | \
    NEMOCLAW_AGENT="${AGENT}" \
    NEMOCLAW_SANDBOX_NAME="${SANDBOX_NAME}" \
    NEMOCLAW_PROVIDER=custom \
    NEMOCLAW_ENDPOINT_URL="${INFERENCE_BASE_URL}" \
    NEMOCLAW_MODEL="${INFERENCE_MODEL}" \
    COMPATIBLE_API_KEY="${INFERENCE_API_KEY}" \
    NEMOCLAW_PREFERRED_API=openai-completions \
    bash -s -- --yes-i-accept-third-party-software \
    || log "installer returned non-zero; continuing if CLI is on PATH"
  export PATH="${HOME}/bin:${HOME}/.local/bin:${PATH}"
  for nvmbin in "${HOME}"/.nvm/versions/node/*/bin; do
    [ -d "$nvmbin" ] && export PATH="${nvmbin}:${PATH}"
  done
fi
command -v nemoclaw >/dev/null && command -v openshell >/dev/null \
  || die "nemoclaw/openshell missing after install"

# These need the OpenShell CLI, so they run only once it is installed.
clear_errored_sandbox
publish_shared_binaries || die "could not publish openshell-sandbox to ${HOME}/bin"
reconcile_supervisor_bin

# ---- partial gateway PKI ----
# The gateway refuses to start on a half-written TLS tree ("partial PKI state
# ... some files exist but not all") and never cleans it up, so a run
# interrupted during certificate generation wedges every later start.
#
# A truncated write, or a leftover empty DIRECTORY from the old host-daemon
# bind-mount behaviour, can leave ca.crt and the client/server leaves as
# directories, which no amount of regeneration fixes. Move the tree aside
# (rather than delete it) whenever it is not intact and let the gateway rebuild.
clear_partial_gateway_pki() {
  local dir="${HOME}/.local/state/nemoclaw/openshell-docker-gateway/tls" f intact=1
  [ -d "$dir" ] || return 0
  for f in ca.crt server/tls.crt server/tls.key client/tls.crt client/tls.key; do
    [ -f "$dir/$f" ] || { intact=0; break; }
  done
  [ "$intact" = "1" ] && return 0
  log "gateway PKI at ${dir} is incomplete; moving it aside so the gateway regenerates"
  mv "$dir" "${dir}.broken-$(date +%s)" 2>/dev/null || true
}
clear_partial_gateway_pki

# ---- empty-directory bind-mount debris ----
# Told to bind-mount a file that does not exist, dockerd does not fail: it
# creates an empty DIRECTORY at that path. Each one then poisons the real file
# -- the gateway cannot write sandbox.jwt because a directory already occupies
# the path. Keep this for leftover state (including an old DooD volume).
#
# rmdir is deliberate: it removes a path only when it is an empty directory, so
# a real key, certificate or token is never at risk.
clear_dood_debris() {
  local d n=0
  for d in $(find "${HOME}/.local/state/openshell" "${HOME}/.local/state/nemoclaw" \
               -type d \( -name '*.jwt' -o -name '*.crt' -o -name '*.key' -o -name '*.pem' \) \
               2>/dev/null); do
    rmdir "$d" 2>/dev/null && n=$((n + 1))
  done
  [ "$n" -gt 0 ] && log "removed ${n} empty directories left in place of mount sources"
  # Failed bind of a missing supervisor binary leaves a directory at this path.
  for d in /usr/local/bin/openshell-sandbox /usr/local/bin/openshell-gateway; do
    rmdir "$d" 2>/dev/null || true
  done
  return 0
}
clear_dood_debris
reconcile_gateway_unit_bin
ensure_managed_gateway
recover_stopped_sandbox

if ! wait_sandbox_listed_ready; then
  existing="$(first_ready_sandbox)"
  if [ -n "$existing" ] && [ "$existing" != "$SANDBOX_NAME" ]; then
    log "SANDBOX_NAME=${SANDBOX_NAME} is not Ready; using existing Ready sandbox '${existing}'"
    SANDBOX_NAME="$existing"
  fi
fi
if ! sandbox_is_ready; then
  need_inference
  check_inference_dns
  ensure_sandbox_images
  log "onboard: starting gateway and creating sandbox '${SANDBOX_NAME}' (local image if present, pull if missing)"
  onboard_cmd=(nemoclaw onboard --non-interactive --agent "${AGENT}" --name "${SANDBOX_NAME}" --yes)
  if [ "${ONBOARD_FRESH:-0}" = "1" ]; then
    log "ONBOARD_FRESH=1: discarding the onboard session (may re-resolve the base image)"
    onboard_cmd+=(--fresh)
  fi
  NEMOCLAW_PROVIDER=custom \
    NEMOCLAW_ENDPOINT_URL="${INFERENCE_BASE_URL}" \
    NEMOCLAW_MODEL="${INFERENCE_MODEL}" \
    COMPATIBLE_API_KEY="${INFERENCE_API_KEY}" \
    NEMOCLAW_PREFERRED_API=openai-completions \
    "${onboard_cmd[@]}" \
    || {
      if sandbox_is_ready; then
        log "onboard exited non-zero but sandbox '${SANDBOX_NAME}' is Ready; continuing"
      else
        die "onboard failed"
      fi
    }
fi
wait_sandbox_ready || die "sandbox not Ready"

CID="$(cid)"
[ -n "$CID" ] || die "sandbox container not found"

# ---- approvals.mode + config-hash anchor (skipped if APPROVALS_MODE is empty) ----
if [ -n "${APPROVALS_MODE}" ]; then
  case "$APPROVALS_MODE" in
    off|smart|manual) ;;
    *) die "APPROVALS_MODE must be off, smart, or manual" ;;
  esac
  current="$(nemoclaw "${SANDBOX_NAME}" exec -- hermes config get approvals.mode 2>/dev/null \
    | tail -1 | tr -d "'\" " || true)"
  if [ "$current" = "$APPROVALS_MODE" ]; then
    log "approvals.mode already ${APPROVALS_MODE}"
  else
    log "setting approvals.mode=${APPROVALS_MODE}"
    docker cp "${CID}:/sandbox/.hermes/config.yaml" /tmp/hm-config.bak 2>/dev/null || true
    docker cp "${CID}:/sandbox/.hermes/.config-hash" /tmp/hm-hash.bak 2>/dev/null || true
    nemoclaw "${SANDBOX_NAME}" exec -- hermes config set approvals.mode "${APPROVALS_MODE}" \
      || die "hermes config set failed"
    sync_config_hash "$CID"
    docker restart "$CID" >/dev/null
    sleep 8
    if docker ps -a --filter "id=${CID}" --format '{{.Status}}' | grep restarting >/dev/null; then
      log "sandbox restarting after approvals change; rolling back"
      docker cp /tmp/hm-config.bak "${CID}:/sandbox/.hermes/config.yaml" 2>/dev/null || true
      docker cp /tmp/hm-hash.bak "${CID}:/sandbox/.hermes/.config-hash" 2>/dev/null || true
      docker restart "$CID" >/dev/null || true
      die "approvals change triggered config drift"
    fi
    wait_sandbox_ready || die "sandbox not Ready after approvals restart"
    CID="$(cid)"
  fi
fi

# ---- MCP router registration (skipped if MCP_URL is empty) ----
if [ -n "${MCP_URL:-}" ]; then
  [ -n "${MCP_ROUTER_TOKEN:-}" ] || die "MCP_URL is set but MCP_ROUTER_TOKEN is empty"
  if nemoclaw "${SANDBOX_NAME}" mcp list --json 2>/dev/null | grep mcp-router >/dev/null; then
    log "mcp-router already registered"
  else
    log "registering MCP router"
    export MCP_ROUTER_TOKEN
    mcp_add=(nemoclaw "${SANDBOX_NAME}" mcp add mcp-router --url "${MCP_URL}"
             --env "${MCP_ENV_VAR:-MCP_ROUTER_TOKEN}")

    # A proxy in fake-ip mode (Surge/Clash) answers every DNS query from
    # 198.18.0.0/15, so the MCP host looks like a private address and NemoClaw
    # refuses to register it. The tool's own remedy is to name the host as
    # trusted; pass it only when the address really is in that range, so a
    # genuinely private endpoint elsewhere is still rejected.
    mcp_host="$(printf '%s' "${MCP_URL}" | sed -E 's#^[a-z][a-z0-9+.-]*://([^/:]+).*#\1#')"
    mcp_ip="$(getent ahostsv4 "${mcp_host}" 2>/dev/null | awk 'NR==1{print $1}')"
    case "${mcp_ip}" in
      198.18.*|198.19.*)
        log "MCP host ${mcp_host} resolves to fake-ip ${mcp_ip}; passing --trusted-private-host"
        mcp_add+=(--trusted-private-host "${mcp_host}")
        ;;
    esac

    # Not fatal. MCP is optional, and letting a registration failure kill this
    # service would leave the Hermes API unreachable even though onboard,
    # approvals and the sandbox all succeeded.
    "${mcp_add[@]}" || log_warn_mcp "mcp add failed; continuing without the MCP router"
    unset MCP_ROUTER_TOKEN
  fi
fi

write_openai_env "$CID"

port_is_listening() {
  local p="$1"
  ss -lnt 2>/dev/null | grep -Eq ":${p}[[:space:]]" && return 0
  lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1
}

ensure() {
  local name="$1" pattern="$2"
  shift 2
  if pgrep -f "$pattern" >/dev/null 2>&1; then
    return 0
  fi
  log "start ${name}"
  nohup setsid "$@" >>"${LOG_DIR}/${name}.log" 2>&1 &
}

# The gateway is NOT started here. Onboard registers it as a systemd user unit
# (nemoclaw-openshell-gateway.service) and NemoClaw refuses to attach to a
# listener it cannot prove that unit owns; a second copy started from this
# script is the bind conflict its source explicitly warns about.
#
# OpenShell's own onboard forwards bind 127.0.0.1 and occupy 8642/18789, so
# `--local 0.0.0.0:…` cannot bind. Those tunnels target the same ports inside
# the sandbox (8642 for the API, 18789 for the dashboard). Skip creating a
# second forward when the local port is already listening; run the dashboard
# on 18789 so the existing tunnel actually hits it.
start_all() {
  local openshell
  openshell="$(command -v openshell || true)"
  [ -n "$openshell" ] || return 1
  ensure dashboard "hermes dashboard --no-open --port ${HERMES_DASHBOARD_PORT}" \
    "$openshell" -g nemoclaw sandbox exec -n "${SANDBOX_NAME}" --no-tty -- hermes dashboard --no-open --port "${HERMES_DASHBOARD_PORT}" --skip-build
  if ! port_is_listening "${HERMES_DASHBOARD_PORT}"; then
    ensure dashboard-forward "forward service ${SANDBOX_NAME} --target-port ${HERMES_DASHBOARD_PORT}" \
      "$openshell" -g nemoclaw forward service "${SANDBOX_NAME}" --target-port "${HERMES_DASHBOARD_PORT}" --local "${BIND}:${HERMES_DASHBOARD_PORT}"
  fi
  if ! port_is_listening "${HERMES_API_PORT}"; then
    ensure api-forward "forward service ${SANDBOX_NAME} --target-port 18642" \
      "$openshell" -g nemoclaw forward service "${SANDBOX_NAME}" --target-port 18642 --local "${BIND}:${HERMES_API_PORT}"
  fi
}

log "Hermes API  http://${BIND}:${HERMES_API_PORT}/v1"
log "dashboard   http://${BIND}:${HERMES_DASHBOARD_PORT}/"
log "Open WebUI on another device: Admin → Connections → OpenAI"
log "  base URL + key: docker compose exec nemohermes cat /root/hermes-openai.env"
trap 'pkill -P $$ || true; exit 0' TERM INT
while true; do
  start_all || true
  sleep 5
done
ENTRY
RUN chmod +x /usr/local/sbin/nemohermes

# The workload runs as a system unit, not as PID 1: journal+console puts its
# output in `docker logs`. After=docker.service user@0.service means it starts
# only once inner dockerd and the user manager that will own the gateway are up.
COPY <<'UNIT' /etc/systemd/system/nemohermes.service
[Unit]
Description=NemoHermes bootstrap (onboard, approvals, MCP, forwards)
After=network-online.target docker.service user@0.service
Wants=network-online.target docker.service user@0.service

[Service]
Type=simple
Environment=HOME=/root
Environment=USER=root
Environment=XDG_RUNTIME_DIR=/run/user/0
Environment=PATH=/root/bin:/root/.local/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/usr/local/sbin/nemohermes
Restart=on-failure
# Sandbox creation holds a mutation lock and can run for tens of minutes. A
# short restart interval makes the next attempt collide with the previous
# process's lock and fail with "Timed out waiting for the sandbox mutation
# lock", which looks like a NemoClaw bug but is self-inflicted.
RestartSec=90
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
UNIT
RUN systemctl enable nemohermes.service

EXPOSE 8642 18789
STOPSIGNAL SIGRTMIN+3
ENTRYPOINT ["/lib/systemd/systemd"]
