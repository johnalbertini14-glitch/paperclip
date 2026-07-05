#!/bin/bash

PAPERCLIP_HOME="${PAPERCLIP_HOME:-/paperclip}"

if [ -x "$PAPERCLIP_HOME/services/preflight.sh" ]; then
  "$PAPERCLIP_HOME/services/preflight.sh"
fi

echo "Fixing permissions"
sudo chown node:node "$PAPERCLIP_HOME" "$PAPERCLIP_HOME/instances" "$PAPERCLIP_HOME/services" 2>/dev/null || true

[ -n "$OPENAI_API_KEY" ] && export CODEX_API_KEY="$OPENAI_API_KEY"

if [ -x "$PAPERCLIP_HOME/services/ensure-latest-cli-packages.sh" ]; then
  "$PAPERCLIP_HOME/services/ensure-latest-cli-packages.sh" || echo "warn: CLI package update check failed (non-fatal)"
fi

if [ -x "$PAPERCLIP_HOME/services/ensure-hermes-latest.sh" ]; then
  "$PAPERCLIP_HOME/services/ensure-hermes-latest.sh" || echo "warn: Hermes update check failed (non-fatal)"
fi

HERMES_BIN="$PAPERCLIP_HOME/repos/hermes-agent/venv/bin/hermes"
if [ -x "$HERMES_BIN" ]; then
  sudo ln -sfn "$HERMES_BIN" /usr/local/bin/hermes 2>/dev/null || \
    echo "warn: failed to update /usr/local/bin/hermes symlink" >&2
fi

CONFIG="${PAPERCLIP_HOME}/instances/default/config.json"
[ ! -f "$CONFIG" ] && BOOTSTRAP_REQUIRED=1 || BOOTSTRAP_REQUIRED=0
COOKIE_JAR="$(mktemp)"
trap "rm -f $COOKIE_JAR" EXIT

post_json_with_cookies() {
  local url="$1"
  local body="$2"
  local response http_code

  response="$(curl -sS \
    -w "\n%{http_code}" \
    -c "$COOKIE_JAR" \
    -b "$COOKIE_JAR" \
    -H "Content-Type: application/json" \
    -H "Origin: http://localhost:$PORT" \
    -H "Host: localhost:$PORT" \
    -X POST \
    "http://localhost:$PORT/$url" \
    --data "$body")"

  http_code="$(echo "$response" | tail -n1)"
  echo "$response" | head -n -1
  return $(( http_code >= 200 && http_code < 300 ? 0 : 1 ))
}

bootstrap_user() {
  local response

  echo "    Signing up admin user $ADMIN_EMAIL..."
  if ! response="$(post_json_with_cookies \
    "api/auth/sign-up/email" \
    "{\"name\":\"$ADMIN_NAME\",\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}")"; then
    echo "    Sign-up failed: $response"
    return 1
  fi
  echo "    Created admin user $ADMIN_EMAIL"

  echo "    Signing in admin user $ADMIN_EMAIL..."
  if ! response="$(post_json_with_cookies \
    "api/auth/sign-in/email" \
    "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}")"; then
    echo "    Sign-in failed: $response"
    return 1
  fi
  echo "    Signed in admin user $ADMIN_EMAIL"

  echo "    Bootstrapping CEO role..."
  local invite
  invite="$(paperclipai auth bootstrap-ceo --force | grep 'Invite URL' | awk -F'/invite/' '{print $2}')"
  if ! response="$(post_json_with_cookies \
    "api/invites/$invite/accept" \
    "{\"requestType\":\"human\"}")"; then
    echo "    Invite accept failed: $response"
    return 1
  fi
  echo "    Accepted invite $invite"
}

if [ "$BOOTSTRAP_REQUIRED" -eq 1 ]; then
  echo "    Bootstrapping fresh install"
  PAPERCLIP_PUBLIC_URL="http://localhost:$PORT" PAPERCLIP_ALLOWED_HOSTNAMES="localhost:$PORT,$PAPERCLIP_ALLOWED_HOSTNAMES" paperclipai onboard --yes --bind lan --run &
  ONBOARD_PID=$!
  echo "    Waiting for service to be online..."
  until curl -sf "http://localhost:${PORT}/api/health" > /dev/null 2>&1; do
    sleep 2
  done

  echo "    Bootstrapping admin user"
  bootstrap_user

  sed -i 's/"disableSignUp": false/"disableSignUp": true/' "$CONFIG"
  echo "    Restarting paperclipai with production config..."
  kill "$ONBOARD_PID"
  wait "$ONBOARD_PID" 2>/dev/null
fi

INDEX=/usr/local/lib/node_modules/paperclipai/node_modules/@paperclipai/server/ui-dist/index.html
STYLE='<style id="paperclip-hide-signup">.mt-5.text-sm.text-muted-foreground{display:none}</style>'

sudo sed -i 's|<style id="paperclip-hide-signup">[^<]*</style>||' "$INDEX" 2>/dev/null || \
  echo "warn: failed to strip existing style tag" >&2

disabled=$(jq -r '.auth.disableSignUp // false' "$CONFIG" 2>/dev/null || echo "false")
if [ "$disabled" = "true" ]; then
  if sudo sed -i "s|</head>|${STYLE}</head>|" "$INDEX" 2>/dev/null; then
    echo "signup hidden (auth.disableSignUp=true)"
  fi
else
  echo "signup visible (auth.disableSignUp=false)"
fi

PATCH_DIR="$PAPERCLIP_HOME/services"
echo "patches: applying persistent dist patches from $PATCH_DIR ..."
for patch in \
  "$PATCH_DIR/apply-adapter-patch.sh" \
  "$PATCH_DIR/apply-codex-adapter-patch.sh" \
  "$PATCH_DIR/apply-opencode-models-patch.sh" \
  "$PATCH_DIR/apply-hermes-models-patch.sh" \
  "$PATCH_DIR/apply-agent-error-surface-patch.sh" \
  "$PATCH_DIR/apply-created-by-agent-filter-patch.sh" \
  "$PATCH_DIR/apply-board-queue-resolved-filter-patch.sh" \
  "$PATCH_DIR/apply-routine-trigger-uuid-patch.sh" \
  "$PATCH_DIR/apply-routine-open-execution-patch.sh" \
  "$PATCH_DIR/apply-hermes-local-api-key-patch.sh" \
  "$PATCH_DIR/apply-hermes-context-recovery-patch.sh" \
  "$PATCH_DIR/apply-wake-payload-patch.sh" \
  "$PATCH_DIR/apply-memory-v1-psmm-patch.sh" \
  "$PATCH_DIR/apply-issue-document-claim-guardrail.sh" \
  "$PATCH_DIR/apply-agents-redaction-reva2655.sh" \
  "$PATCH_DIR/apply-backup-scripts.sh" \
; do
  if [ -f "$patch" ]; then
    bash "$patch" 2>&1 | sed 's/^/  /' || echo "  warn: $patch exited non-zero (non-fatal)"
  fi
done
echo "patches: done"

if [ -x "$PATCH_DIR/start-dockerd.sh" ]; then
  "$PATCH_DIR/start-dockerd.sh" || echo "warn: Docker runtime startup failed (non-fatal)"
fi

if [ -x "$PATCH_DIR/start-lightpanda.sh" ]; then
  "$PATCH_DIR/start-lightpanda.sh" || echo "warn: Lightpanda startup failed (non-fatal)"
fi

exec paperclipai run
