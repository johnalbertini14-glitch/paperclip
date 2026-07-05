# Adapter Patch Persistence Runbook

## Overview

Paperclip adapter model lists and server-side fixes live in npm-installed dist files under `/usr/local/lib/node_modules/paperclipai/`. These are overwritten by `npm i -g paperclipai` upgrades. Idempotent patch scripts in `/paperclip/services/` re-apply the fixes.

## Boot Flow

`/entrypoint.sh` runs all `apply-*.sh` scripts before `paperclipai run`. Patches are idempotent (grep-guarded) and non-fatal on skip.

### Patch Ordering

`apply-wake-payload-patch.sh` **must** run before `apply-memory-v1-psmm-patch.sh` (memory-v1 anchors on shapes introduced by wake-payload).

## Patch Inventory

| Script | Ticket | Target | What it does |
|--------|--------|--------|-------------|
| `apply-adapter-patch.sh` | REVA-172 | adapter-claude-local/dist/index.js | Adds `claude-opus-4-7` to model list |
| `apply-codex-adapter-patch.sh` | — | adapter-codex-local/dist/index.js | Adds gpt-5.5 family + fast-mode |
| `apply-opencode-models-patch.sh` | REVA-1419 | adapter-opencode-local/dist/server/models.js | Stale-cache retry on model discovery |
| `apply-hermes-models-patch.sh` | REVA-2594 | hermes-paperclip-adapter/dist/index.js | Populates Hermes model list from OpenRouter discovery |
| `apply-agent-error-surface-patch.sh` | REVA-1704 | server/dist/services/heartbeat.js, agents.js | Surface adapter exitCode/lastError |
| `apply-created-by-agent-filter-patch.sh` | REVA-2214 | server/dist/routes/issues.js, services/issues.js | createdByAgentId filter |
| `apply-routine-trigger-uuid-patch.sh` | REVA-1664 | server/dist/routes/routines.js | UUID validation on trigger routes |
| `apply-routine-open-execution-patch.sh` | REVA-2580 | server/dist/services/routines.js, db schema/migration dist | Routine concurrency checks any open execution issue |
| `apply-hermes-local-api-key-patch.sh` | REVA-2594 | hermes-paperclip-adapter/dist/server/execute.js | Injects local run JWT as `PAPERCLIP_API_KEY` unless explicitly configured |
| `apply-hermes-context-recovery-patch.sh` | REVA-2641 | hermes-paperclip-adapter/dist/server/execute.js, dist/server/index.js | Uses resolved runtime config, injects Paperclip task context, prefers resolved workspace cwd, and persists session cwd |
| `apply-wake-payload-patch.sh` | REVA-915 | server/dist/services/heartbeat.js, adapter-utils | documentFetchPaths in wake payload |
| `apply-memory-v1-psmm-patch.sh` | REVA-1912 | server/dist/services/heartbeat.js | sessionContinuity in wake payload |
| `apply-issue-document-claim-guardrail.sh` | REVA-4045 | server/dist/services/documents.js | Blocks stale `117+` signal/source/connector claims in issue document upserts/restores while allowing corrective audit references |
| `apply-agents-redaction-reva2655.sh` | REVA-2655 | `server/dist/redaction.js, dist/routes/agents.js` | Unconditional plain-binding redaction + 10 adapterConfig/runtimeConfig call sites |

## After `npm i -g paperclipai` Upgrade

1. All dist files are replaced by the new version.
2. On next container restart, `/entrypoint.sh` re-applies all patches.
3. If running without restart, manually run:

```bash
PATCH_DIR=/paperclip/services
for patch in \
  "$PATCH_DIR/apply-adapter-patch.sh" \
  "$PATCH_DIR/apply-codex-adapter-patch.sh" \
  "$PATCH_DIR/apply-opencode-models-patch.sh" \
  "$PATCH_DIR/apply-hermes-models-patch.sh" \
  "$PATCH_DIR/apply-agent-error-surface-patch.sh" \
  "$PATCH_DIR/apply-created-by-agent-filter-patch.sh" \
  "$PATCH_DIR/apply-routine-trigger-uuid-patch.sh" \
  "$PATCH_DIR/apply-routine-open-execution-patch.sh" \
  "$PATCH_DIR/apply-hermes-local-api-key-patch.sh" \
  "$PATCH_DIR/apply-hermes-context-recovery-patch.sh" \
  "$PATCH_DIR/apply-wake-payload-patch.sh" \
  "$PATCH_DIR/apply-memory-v1-psmm-patch.sh" \
  "$PATCH_DIR/apply-issue-document-claim-guardrail.sh" \
  "$PATCH_DIR/apply-agents-redaction-reva2655.sh" \
 ; do
  [ -f "$patch" ] && bash "$patch"
done
```

4. Restart the Paperclip server process to load patched modules.

## Adapter Model State

| Adapter | Model Source | Notes |
|---------|------------|-------|
| `claude_local` | Static list in dist/index.js | Patched to include `claude-opus-4-7` |
| `codex_local` | Static list in dist/index.js | Patched to include gpt-5.5 family |
| `opencode_local` | Dynamic discovery via `opencode models` CLI | ~147 models at runtime, 60s cache with stale-retry |
| `hermes_local` | Empty list + runtime `detectModel()` | Models resolved from `~/.hermes/config.yaml` and provider |

## Adapter Model Approval Gate

Board rule: no opencode/OpenRouter Claude without explicit board approval. Do not patch adapters, change `opencode_local` model routing, or switch any agent to a Claude model through OpenRouter/opencode unless the issue links the board approval id. Preserve current configs by default. Any approved adapter/model change must close with current adapter/model readback, target adapter/model readback, approval id, UI Checker board-updated note when applicable, credential safety note using env var names only, and a switchback follow-up when the change is temporary.

## Closeout Gate

Do not mark adapter or runtime persistence work `done` until the live runtime has proved the final state. Static file greps, patch-script success, or "restart needed" notes are not enough.

Close evidence must include:

- Live adapter endpoint readback after the final hot patch or restart, with evidence path and the specific model booleans required by the ticket.
- Runbook and closeout alignment on whether restart is required. If restart is still required, keep the issue `blocked` or `in_review` with owner/action.
- Current and target adapter/model readback, approval id or unchanged-routing proof, and credential safety note using env var names only.
- All verifier blockers resolved, including dependent smoke issues. Cite issue ids, status readback, and PASS comment ids or evidence paths.
- Scraper/runtime evidence when the ticket touches Docker, Lightpanda, Hermes execution, or boot hooks.
- For Hermes recovery or adapter-execution failures, actual Paperclip adapter run evidence. CLI-only Hermes success proves the binary path, not the Paperclip adapter path.

Reviewers must send the issue back to `in_progress` when any close evidence above is missing or contradicted by a live endpoint check.

## Hermes / Code Worker Configuration

Code Workers A, B, C use `hermes_local` adapter with:
- Model: `deepseek/deepseek-v4-flash` via OpenRouter
- Provider auto-detected from model prefix
- Auth: `OPENROUTER_API_KEY` env var (from adapter config)

The global Hermes fallback config at `/paperclip/.hermes/config.yaml` must also use:

```yaml
model:
  provider: openrouter
  default: deepseek/deepseek-v4-flash
```

Do not set the fallback, `opencode_local`, or any agent adapter config to an OpenRouter Claude model without a linked board approval id.

## Scraper Runtime

- **Lightpanda** (default, unprotected sites): started by `start-lightpanda.sh` when `/usr/local/bin/lightpanda` is installed, CDP at `ws://127.0.0.1:9222`
- **Docker daemon** (Hermes scraper container): started by `start-dockerd.sh`, rootless vfs driver

Both are started by `/entrypoint.sh` at boot.

## Verification Commands

```bash
# Check claude_local has opus-4-7
grep 'claude-opus-4-7' /usr/local/lib/node_modules/paperclipai/node_modules/@paperclipai/adapter-claude-local/dist/index.js

# Check opencode stale-cache patch
grep 'REVA-1419' /usr/local/lib/node_modules/paperclipai/node_modules/@paperclipai/adapter-opencode-local/dist/server/models.js

# Check codex gpt-5.5
grep '"gpt-5.5"' /usr/local/lib/node_modules/paperclipai/node_modules/@paperclipai/adapter-codex-local/dist/index.js

# Check memory v1 PSMM
grep 'sessionContinuity,' /usr/local/lib/node_modules/paperclipai/node_modules/@paperclipai/server/dist/services/heartbeat.js

# Check issue document claim guardrail
grep 'REVA-4045-issue-document-claim-guardrail' /usr/local/lib/node_modules/paperclipai/node_modules/@paperclipai/server/dist/services/documents.js

# Check REVA-4045 guardrail regression coverage in the canonical mirror
node tests/reva4045-issue-document-claim-guardrail.test.mjs

# Check hermes CLI
hermes --version

# Check Hermes task-context recovery patch
grep 'REVA-2641-hermes-context-recovery' /usr/local/lib/node_modules/paperclipai/node_modules/hermes-paperclip-adapter/dist/server/execute.js
grep 'REVA-2641-hermes-session-cwd' /usr/local/lib/node_modules/paperclipai/node_modules/hermes-paperclip-adapter/dist/server/index.js
```

## Credential Safety

Never hard-code API keys in patches or configs. Reference by env var name:
- `OPENROUTER_API_KEY` (injected from opencode-auth.json at boot)
- `OPENAI_API_KEY` / `CODEX_API_KEY` (from container env)
- `PAPERCLIP_API_KEY` (auto-injected per run)
