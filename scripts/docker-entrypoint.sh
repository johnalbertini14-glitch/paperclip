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
# Read the stage marker under its public name. The previous build
# exported the bare `ENTRYPOINT_STAGE` here, which meant the non-root
# fallback at the top of stage 1 never re-entered stage 2: re-execs
# still saw `PAPERCLIP_ENTRYPOINT_STAGE` unset (defaulting to `root`)
# and looped forever. Keeping the canonical PAPERCLIP_ prefix on
# both the read AND the export is what makes the two-stage contract
# actually terminate.
PAPERCLIP_ENTRYPOINT_STAGE=${PAPERCLIP_ENTRYPOINT_STAGE:-root}

run_boot_patch() {
    script_path="$1"
    if [ -x "$script_path" ]; then
        log "boot patch: $(basename "$script_path")"
        bash "$script_path" 2>&1 | sed 's/^/  /' >&2 \
            || warn "$(basename "$script_path") exited non-zero (non-fatal)"
    fi
}

# Stage 1: UID/GID remap (must run as root).
if [ "$PAPERCLIP_ENTRYPOINT_STAGE" = "root" ]; then
    if [ "$(id -u)" -ne 0 ]; then
        # Non-root container (restricted PodSecurity / OpenShift
        # arbitrary UIDs). Neither the remap nor gosu can work here,
        # so skip stage 1 entirely and fall through to stage 2. We
        # intentionally do NOT re-exec: re-execing with the stage
        # marker unchanged would just hit this same branch and loop
        # forever (the previous build's bug).
        warn "root stage requested but id -u is $(id -u); skipping remap, falling through to unprivileged stage"
    else
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
        exec setpriv --reuid node --regid node --groups "$(id -G node)" "$0" "$@"
    fi
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
# them as process env vars here.
#
# Precedence contract: process env (including --env-file delivery from
# the orchestrator) wins over .env-file values. The .env file is only
# consulted for keys the process env does not already define. This
# matches the inline `override=false` semantics claimed in the
# previous build and prevents the runtime env delivery path from
# being silently clobbered by stale on-disk .env content.
#
# Implementation note: we deliberately do NOT use `set -a; . "$ENV_FILE";
# set +a` because that auto-exports every variable read from .env and
# therefore unconditionally overrides the calling process env.
#
# We also avoid `awk ... | while read` because in POSIX sh that pipe
# runs the loop in a subshell, so any export inside the loop is lost
# to the parent. Instead we read the parsed lines into a here-string
# and `eval` them in the current shell, guarded by a ${KEY+x} check.
ENV_FILE="$PAPERCLIP_HOME/instances/$PAPERCLIP_INSTANCE_ID/.env"
if [ -r "$ENV_FILE" ]; then
    log "loading per-instance env (process-env wins): $ENV_FILE"
    # Why no `awk | while read` pipe: in POSIX sh that pipe runs
    # the while loop in a subshell, so any `export` inside the loop
    # is lost to the parent shell - which is exactly the bug that
    # made the previous build's "override=false" claim a lie.
    #
    # We instead parse with awk into a variable, then iterate with
    # a here-string (`done <<EOF`) which runs in the current shell,
    # so `export` persists to the parent.
    #
    # We use the ASCII Unit Separator (0x1F) as the record delimiter
    # so values may contain `=`, spaces, or newlines without
    # confusing the split. The separator byte is built via `printf
    # '\037'` (POSIX-portable) rather than `$'\x1f'` (bash-only)
    # because this script is intended to run under dash inside the
    # production container.
    _env_sep=$(printf '\037_'); _env_sep=${_env_sep%_}
    _env_blob=$(awk -v sep="$_env_sep" -F= '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        {
            key = $1
            sub(/^[[:space:]]+/, "", key)
            sub(/[[:space:]]+$/, "", key)
            if (key == "") next

            rest = $0
            sub(/^[^=]*=/, "", rest)

            # Strip surrounding single or double quotes from the value.
            if (substr(rest, 1, 1) == "\"" && substr(rest, length(rest), 1) == "\"") {
                rest = substr(rest, 2, length(rest) - 2)
            } else if (substr(rest, 1, 1) == "\x27" && substr(rest, length(rest), 1) == "\x27") {
                rest = substr(rest, 2, length(rest) - 2)
            }

            gsub(/[\r\n]/, "", rest)
            printf "%s%s%s\n", key, sep, rest
        }
    ' "$ENV_FILE")
    if [ -n "$_env_blob" ]; then
        while IFS= read -r _env_line; do
            [ -z "$_env_line" ] && continue
            # Split on the first occurrence of the Unit Separator.
            # Use a case pattern (POSIX-safe) rather than the
            # bash-only ${var%%$'\x1f'*} expansion, since this
            # script runs under dash inside the production image.
            case "$_env_line" in
                *"$_env_sep"*)
                    _env_key=${_env_line%%"$_env_sep"*}
                    _env_val=${_env_line#*"$_env_sep"}
                    ;;
                *)
                    continue
                    ;;
            esac
            case "$_env_key" in
                "") continue ;;
                # POSIX shell variable names: must start with a letter
                # or underscore, not a digit. Without the leading-char
                # gate below, a key like `1BAD=value` would pass the
                # charset check, then crash the `eval` below under
                # `set -eu` with `Bad substitution`.
                [!A-Za-z_]*) continue ;;
                *[!A-Za-z0-9_]*) continue ;;
            esac
            # Process env wins: only assign if not already set.
            # ${KEY+x} expands to "x" if KEY is defined, "" otherwise.
            if eval "[ -z \"\${$_env_key+x}\" ]"; then
                export "$_env_key=$_env_val"
            fi
        done <<EOF
$_env_blob
EOF
    fi
    unset _env_blob _env_line _env_key _env_val _env_sep
fi

exec "$@"
