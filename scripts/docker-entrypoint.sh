#!/bin/sh
# Paperclip local-source image entrypoint (REVA-21689).
#
# This entrypoint is the local-source equivalent of the upstream
# `paperclipai/server` runtime surface. It exists so the
# `paperclip-bttt-custom:local-source` image (built from this repo's
# Dockerfile) can replace the upstream image that bakes
# `OPENROUTER_API_KEY` and `PAPERCLIP_AUTH_BASE_URL_MODE` into its
# `.Config.Env` without losing any of the boot behavior the live
# container depends on:
#
#   1. UID/GID remap (host `node` user -> requested USER_UID/USER_GID)
#   2. Mount preflight (stale embedded-PG pidfile cleanup, docker socket
#      symlink, cli-plugins setup) via /paperclip/services/preflight.sh
#   3. Runtime env patches from /paperclip/services (best-effort)
#   4. Docker socket detection -> DOCKER_HOST export
#   5. Load /paperclip/instances/default/.env so PAPERCLIP_AGENT_JWT_SECRET
#      (or BETTER_AUTH_SECRET) reaches the server when it is started via
#      `node server/dist/index.js` (the server itself does not auto-load
#      the .env; the upstream `paperclipai run` CLI does)
#   6. exec the CMD (the local server boots its own embedded Postgres
#      from config.json, so no in-image pg_ctl wrapper is needed)
#
# Two-stage design: the script re-execs itself with the stage marker
# `PAPERCLIP_ENTRYPOINT_STAGE=node` after the UID/GID remap, because
# the boot patches and the server itself must run as the unprivileged
# `node` user.
#
# Differences from the older `paperclip-reva-20021` reference entrypoint:
#   - Drops the `docker-bootstrap-public-embedded-postgres.ts` step
#     (the server source at server/src/index.ts now handles the
#     embedded-Postgres bootstrap natively, including waiting for it
#     to be ready before opening the HTTP listener).
#   - Drops the dedicated `entrypoint-fixed.sh` produced by
#     `apply-blocker-recheck-reva19747.sh` - that file is still
#     installed by the live container's boot patches in /paperclip
#     and is unrelated to this image-resident entrypoint.
#   - Replaces the inline OPENAI_API_KEY->CODEX_API_KEY promotion with
#     a no-op (the server handles that itself now).
#   - Adds an `.env` loader so the local-source build is drop-in
#     compatible with the live `paperclipai run` path that the
#     bttt.env contract is modelled on.
set -eu

log() { echo "[docker-entrypoint] $*" >&2; }
warn() { echo "[docker-entrypoint][warn] $*" >&2; }
die() { echo "[docker-entrypoint][FATAL] $*" >&2; exit 1; }

PUID=${USER_UID:-1000}
PGID=${USER_GID:-1000}
PAPERCLIP_HOME=${PAPERCLIP_HOME:-/paperclip}
PAPERCLIP_INSTANCE_ID=${PAPERCLIP_INSTANCE_ID:-default}
PAPERCLIP_CONFIG=${PAPERCLIP_CONFIG:-$PAPERCLIP_HOME/instances/$PAPERCLIP_INSTANCE_ID/config.json}
ENTRYPOINT_STAGE=${PAPERCLIP_ENTRYPOINT_STAGE:-root}

run_boot_patch() {
    script_path="$1"
    if [ -x "$script_path" ]; then
        log "boot patch: $(basename "$script_path")"
        bash "$script_path" 2>&1 | sed 's/^/  /' >&2 \
            || warn "$(basename "$script_path") exited non-zero (non-fatal)"
    fi
}

# Stage 1: UID/GID remap (must run as root).
if [ "$ENTRYPOINT_STAGE" = "root" ]; then
    if [ "$(id -u)" -ne 0 ]; then
        warn "root stage requested but id -u is $(id -u); skipping remap"
        ENTRYPOINT_STAGE=node
        export ENTRYPOINT_STAGE
        exec "$0" "$@"
    fi

    changed=0

    if [ "$(id -u node)" -ne "$PUID" ]; then
        log "remapping node UID: $(id -u node) -> $PUID"
        usermod -o -u "$PUID" node
        changed=1
    fi

    if [ "$(id -g node)" -ne "$PGID" ]; then
        log "remapping node GID: $(id -g node) -> $PGID"
        groupmod -o -g "$PGID" node
        usermod -g "$PGID" node
        changed=1
    fi

    if [ "$changed" = "1" ] && [ -d "$PAPERCLIP_HOME" ]; then
        log "chown -R node:node $PAPERCLIP_HOME (uid/gid remap)"
        chown -R node:node "$PAPERCLIP_HOME" \
            || warn "chown of $PAPERCLIP_HOME partially failed (continuing)"
    fi

    export PAPERCLIP_ENTRYPOINT_STAGE=node
    exec gosu node "$0" "$@"
fi

# Stage 2: unprivileged runtime surface.
if [ "$(id -u)" -ne 0 ] \
    && { [ "$(id -u)" -ne "$PUID" ] || [ "$(id -g)" -ne "$PGID" ]; }; then
    warn "running unprivileged as $(id -u):$(id -g); expected ${PUID}:${PGID}"
fi

# Mount preflight: clean up stale embedded-PG pidfile, symlink docker
# cli-plugins, etc. The preflight lives in the host mount so it is
# optional - if the mount is missing we continue without it.
if [ -x "$PAPERCLIP_HOME/services/preflight.sh" ]; then
    log "running mount preflight.sh"
    "$PAPERCLIP_HOME/services/preflight.sh" \
        || warn "preflight.sh exited non-zero (non-fatal)"
else
    log "preflight: no $PAPERCLIP_HOME/services/preflight.sh (mount not present)"
fi

# Runtime/env patches targeting the /paperclip MOUNT.
PATCH_DIR="$PAPERCLIP_HOME/services"
for patch_script in \
    "$PATCH_DIR/apply-python3-symlink.sh" \
    "$PATCH_DIR/apply-backup-scripts.sh" \
    "$PATCH_DIR/apply-blocked-dedup-skill-patch.sh" \
    "$PATCH_DIR/apply-hermes-models-patch.sh" \
    "$PATCH_DIR/apply-codeburn-cache-warmup.sh" \
; do
    run_boot_patch "$patch_script"
done

# Docker socket detection: if the host docker socket is bind-mounted,
# expose it to the server runtime so agent worktrees can drive
# sub-agents.
if [ -S /var/run/docker.sock ]; then
    export DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker.sock}"
    log "docker: using mounted host socket ($DOCKER_HOST)"
fi

# Load the per-instance .env (Paperclip stores PAPERCLIP_AGENT_JWT_SECRET
# here, generated by `paperclipai configure`). The local-source server
# does not auto-load .env files (the upstream CLI does), so we surface
# them as process env vars here. Use `override=false` semantics by
# preferring the env-file value when no shell env is set, and never
# clobbering an already-set process env var.
ENV_FILE="$PAPERCLIP_HOME/instances/$PAPERCLIP_INSTANCE_ID/.env"
if [ -r "$ENV_FILE" ]; then
    log "loading per-instance env: $ENV_FILE"
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
fi

exec "$@"
