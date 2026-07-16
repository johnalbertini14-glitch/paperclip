# feed-backlog-outbox-consumer

Company-root control-plane consumer for the durable feed-backlog outbox
(`gtm_backlog_outbox` in RevCortex's MongoDB), produced by
[REVA-27714](/REVA/issues/REVA-27714) and consumed here per
[REVA-27715](/REVA/issues/REVA-27715) / [REVA-27685](/REVA/issues/REVA-27685).

## Why this lives here, not in RevCortex

The Control-Plane Drift Guard (REVA-19780/REVA-20349) forbids the Signatiq
product repo from holding any Paperclip API/credential coupling. REVA-27714
removed the last such coupling from `feed_product_backlog_service.py` and
replaced it with a durable, credential-free outbox write. This package is
the other half of that split: it owns the *only* `PAPERCLIP_API_KEY`
reference in the pipeline, reads the outbox via a direct MongoDB
connection, and renders intents to real Paperclip issues.

The two repos share a **data contract** (collection name, document schema,
state machine), not a code dependency — this module does not import
anything from RevCortex.

## Contract summary (matches `backend/core/services/feed_backlog_outbox.py`
at RevCortex SHA `685e9188b5664a8fc0186651cd38d438e111c3a1`)

- Collection: `gtm_backlog_outbox`, unique-indexed on `id` and on
  `(workspaceId, idempotencyKey)`.
- `intentKind`: `create` | `update` | `supersession` | `escalation`.
- `deliveryState`: `pending` -> `acknowledged` (terminal) or `pending` ->
  `failed` -> `pending` (requeue) -> ... Every transition is scoped by
  `(id, workspaceId)` and to the allowed prior state(s).
- `payload` is a neutral, Paperclip-shaped dict (`title`, `body`, `priority`,
  `assigneeAgentId`, `parentId`, plus feed-specific metadata fields) built by
  `build_issue_payload` — this consumer maps it onto
  `POST/PATCH /api/.../issues`.
- `lastError` must only ever contain output from `safe_error_summary`
  (independently ported here — see `consumer.safe_error_summary`), bounded
  to 512 chars, PII/credential-redacted.

## Replay safety (remote-success / local-write failure)

Every issue created or commented carries an HTML-comment idempotency
marker (`<!-- outbox-intent:{idempotencyKey} -->`) in its description or
comment body. Before creating an issue or posting a comment, the consumer
searches Paperclip for that exact marker first. If a retry runs after the
remote call already succeeded but the local `deliveryState` write did not
land, the marker search finds the existing issue/comment and the consumer
only re-applies the acknowledgement — it never creates a duplicate.

## Required environment variables (names only)

| Variable | Purpose |
| --- | --- |
| `MONGO_URL` | RevCortex MongoDB connection string |
| `DB_NAME` | RevCortex MongoDB database name |
| `PAPERCLIP_API_URL` | Paperclip control-plane base URL |
| `PAPERCLIP_API_KEY` | Paperclip control-plane bearer credential |
| `PAPERCLIP_COMPANY_ID` | Paperclip company id issues are created under |

## Optional environment variables

| Variable | Purpose |
| --- | --- |
| `FEED_BACKLOG_CONSUMER_PROJECT_ID` | `projectId` applied to created issues |
| `FEED_BACKLOG_CONSUMER_CTO_AGENT_ID` | Agent id the `local-board` symbolic assignee (CTO escalation routing) resolves to. If unset, escalation intents are created unassigned rather than guessing an id. |
| `FEED_BACKLOG_CONSUMER_BATCH_LIMIT` | Max pending intents processed per cycle (default 25) |
| `PAPERCLIP_RUN_ID` | Forwarded as `X-Paperclip-Run-Id` on mutating calls, if set |

No new credential is requested or bound by this change. Binding
`MONGO_URL`/`PAPERCLIP_API_KEY` into whatever process actually runs this
consumer in production is a separate CTO-owned secrets-registry action.

## Running

```bash
pip install -r requirements.txt
python3 consumer.py   # one-shot: processes up to FEED_BACKLOG_CONSUMER_BATCH_LIMIT pending intents and exits
```

This is intentionally a one-shot batch process, not a long-running daemon —
no Paperclip/Hermes runtime restart or new service process is authorized by
board approval `e95d6c05` for this change; it is meant to be invoked on a
schedule (cron / Paperclip routine) by whichever team owns that binding.

## Tests

```bash
pip install -r requirements.txt
python3 -m unittest test_consumer.py -v
```

Tests exercise the dispatch/redaction/idempotency logic against mocked
Paperclip and Mongo collections — no real network or database is touched.
