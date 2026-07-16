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

The marker is embedded via `embed_marker_bounded`, which truncates body
content *before* appending the marker rather than embedding then
truncating — this guarantees the marker survives even when the rendered
body exceeds `MAX_DESCRIPTION_CHARS` (20,000), so replay can always find
the prior issue/comment regardless of payload size.

## Concurrency safety (two scheduled runs racing the same intent)

Before dispatching any remote mutation, the consumer atomically claims the
intent via a single Mongo `find_one_and_update` (`claim_intent`), matching
only if the intent is still `pending` and either unclaimed or its previous
claim's lease (`claimLeaseExpiresAt`, default 5 minutes) has expired. A
worker that loses the race gets `None` back and skips the intent for this
cycle without touching the Paperclip API. The claim is released
(`release_claim`) on every exit path — deferred, failed, or acknowledged —
so a legitimate retry isn't blocked waiting out the full lease.

Every terminal write (`release_claim`, `mark_acknowledged`, `mark_failed`)
additionally filters on `claimOwner: <this worker's owner token>`. This
matters for the case where a worker's lease has already expired and a
newer worker has legitimately reclaimed the same intent while the first
worker is still stuck mid-dispatch (e.g. a hung remote call): without the
owner scope, the stale worker's eventual return could wipe or overwrite
the newer worker's live claim/state. With it, a stale worker's write
matches zero documents and is a no-op — the newer worker's claim and any
state it produces are left untouched.

### Closing the marker-search -> remote-call gap

`claim_intent` only protects the intent up to the point a worker starts
dispatching. Each `dispatch_*` function still does a non-atomic
search-then-mutate: search Paperclip for the idempotency marker, then (if
absent) call the remote API. If a worker stalls in that exact gap long
enough for its claim lease to expire, a second worker could legitimately
reclaim, also see no marker, and also call the remote API — producing a
real duplicate issue/comment/patch that no local Mongo state prevents.

Two mechanisms close this together:

1. **Pre-dispatch fencing.** Immediately before the remote mutation (never
   before), every dispatch function calls `mark_dispatch_started`, which
   atomically re-verifies `claimOwner == owner` one more time and records
   `dispatchStartedAt`. If this worker's claim was superseded in the
   meantime, the write matches nothing, `mark_dispatch_started` returns
   `False`, and the caller raises `LostClaimError` — the remote mutation is
   never attempted. `process_intent` reports this as a distinct
   `lost_claim` outcome.
2. **Dispatch-aware reclaim grace period.** Once `dispatchStartedAt` is
   set, `claim_intent` will not let another worker reclaim on an expired
   ordinary lease alone — it additionally requires
   `DISPATCH_RECLAIM_GRACE_SECONDS` (30 minutes, far longer than any single
   HTTP call) to have elapsed since dispatch began. This means a worker
   whose lease merely expires *while* an in-flight remote call is still
   running cannot be preempted mid-call; only a worker that is genuinely
   dead eventually frees the intent for reclaim.

`process_intent` also no longer reports a bare `mark_acknowledged` failure
as `"acknowledged"`. If the remote call succeeds but this worker's claim
was lost before the local ack write lands, that write matches zero
documents and the outcome is `lost_claim`, not a fabricated success — run
statistics must not silently over-report acknowledged intents that a
different worker actually owns.

### Post-fence resume race: reconciliation instead of prevention

Mechanism 2 above only bounds the *probability* of a stalled worker
resuming and issuing its remote mutation anyway — a fixed grace period,
however large, cannot make that probability zero. The gap between
`mark_dispatch_started` returning and the following line's actual HTTP
call can itself be stalled by a process pause of unbounded length, and
there is no way for a single Python process to make a check-then-act
sequence atomic with an external side effect unless the remote side
verifies a fencing token as part of the same write. The Paperclip issues
API was checked and exposes no client-supplied idempotency/dedupe key on
create; adding one is a platform-code change outside this ops-only
consumer script's scope.

Rather than keep shrinking that window, `reconcile_created_issue` makes
the *outcome* deterministic: immediately after `create_issue` succeeds in
`dispatch_create`/`dispatch_escalation`, it re-searches Paperclip for every
issue carrying the exact idempotency marker. If a race actually produced
more than one, the earliest-created issue is canonical and every other one
is closed (`status: done`) with a comment pointing at the canonical id.
This guarantees at most one *live* issue for a given idempotency key
survives a dispatch cycle no matter how the physical race interleaved —
the practically achievable form of "a reclaimed worker cannot leave a
lasting duplicate" when true zero-probability prevention isn't available.

`dispatch_update`/`dispatch_supersession` mutate an *existing* target issue
rather than creating a new one, so the same race can produce at worst a
duplicate informational comment on that target — not a duplicate issue,
and not the HIGH risk this ticket's risk section names. No comment-level
reconciliation was added for those two kinds; the existing `claimOwner`-
scoped `mark_acknowledged` already guarantees the accounting stays correct
(never double-acknowledged) even when the stale worker's own remote call
still fires.

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
