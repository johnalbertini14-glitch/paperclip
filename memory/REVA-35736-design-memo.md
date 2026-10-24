# REVA-35736 Design Memo: Signal Breadth & Learning-Loop Productization
## V2 Roadmap §14.11 — Build-or-Kill

**Author:** Internal Researcher  
**Date:** 2026-09-11  
**Status:** Research deliverable — awaiting CEO/CTO ruling  
**Sources read:** `backend/models/gtm.py` lines 295–596, `backend/routes/learning.py` lines 1–951, `backend/routes/email_send.py`, `backend/core/services/reply_lifecycle_service.py`, `backend/core/services/revops_signal_orchestration_service.py`, `backend/routes/enrichment_byo_providers.py`, `backend/core/services/signal_engine.py`, `backend/core/services/priority_scoring_service.py`, `backend/core/services/override_learning_service.py`  
**Canonical source:** GitHub main `1c4b55c0971914e317ddf6749f732ea8a13caf69`

---

## 1. What This Roadmap Area Means

V2 §14.11 (sig-v1-plan-20260826, REVA-32897, section 14 item 11) is titled "Signal breadth and learning-loop productization." The plan defines the learning loop as using **outcome/audit signal** — opens, replies, CRM activity, enrichment results — to **improve play/sequence/motion prioritization**.

The product question: should Signatiq automate the feedback path from what happens after a motion executes (outcomes) back into what motions get proposed and in what order?

---

## 2. Existing Signal-Producing Surfaces (Cited Sources)

### 2a. Mailbox/Gmail Lane — Email Opens/Replies

**Source:** `backend/routes/google_integration.py` (inbound grouping by `threadId`), `backend/routes/email_webhooks_templates.py`

- Gmail send via `/api/google/gmail/send` records a provider message ID.
- Inbound processing groups by `threadId` and records correlated inbound activity.
- Reply lifecycle: `backend/core/services/reply_lifecycle_service.py` (`process_inbound_reply_lifecycle`, line 409) persists `reply_lifecycle_receipt` documents with idempotency keys. Receipts carry a `rollback` block mirroring the `ActionExecutionReceipt` canonical pattern.
- Unsubscribe handling in `backend/routes/email_send.py` — one-click GET unsubscribe and POST unsubscribe endpoints; unsubscribe events suppress sequence enrollment.
- **Signal model:** `GtmSignal` (models/gtm.py:517) with `sourceConnector="google"` or `"resend"`, `signalClass` tracking open/reply/unsubscribe, `occurredAt` for recency.

### 2b. TwentyCRM Governed Sync — CRM Activity

**Source:** `backend/core/services/revops_signal_orchestration_service.py` (lines 1–1001)

- TwentyCRM is the internal source-of-record CRM (confirmed sig-v1-plan-20260826 §14, board correction REVA-18258).
- Governed sync writes produce `GtmOutcome` records with `outcomeType`, `connector="twenty"`, and provider-object tracking.
- `connector_kernel.py` enforces `crm_mutation` action class → approval-gated per workspace policy.
- RevOps Signal Orchestration service fetches Apollo/Clearbit/Crunchbase/Public Web signals, scores accounts against ICP, and emits Salesforce + HubSpot approval artifacts. **Not used for TwentyCRM mutations** — TwentyCRM is SoR only.
- **Signal model:** `GtmOutcome` (models/gtm.py:490) with `outcomeType` from a controlled vocabulary, `connector` identifying the CRM, `evidence` carrying provider-object metadata.

### 2c. Gated CRM Write Actions — Action Execution Receipts

**Source:** `backend/models/gtm.py` lines 451–488 (`ActionExecutionReceipt`)

- Every governed action produces an `ActionExecutionReceipt` with `idempotencyKey`, `status` (proposed/approved/executed/rolled_back), `executedAt`, `audit` dict, and `metadata`.
- Receipt is the authoritative proof that a provider call succeeded or was suppressed.
- **Signal model:** `GtmOutcome` with `subjectType="action"`, `sourceType="runtime_execution"`, `status` differentiating executed vs denied outcomes.

### 2d. Sequence-Engine + Reply-Lifecycle (V2 Leaf2)

**Source:** `backend/core/services/reply_lifecycle_service.py` (lines 1–450+)

- Reply-lifecycle service (`process_inbound_reply_lifecycle`, line 409) classifies inbound replies, records `reply_lifecycle_receipt` documents, and suppresses sequence re-enrollment on unsubscribe.
- Sequence steps: `GtmSequenceStep` (models/gtm.py:303) backed by `gtm_motion_steps` — one ordered step in a sequence execution.
- Sequence state evidence lives in `gtm_signals` / `gtm_intent_events` (models/gtm.py:300 comment).
- **Signal model:** `IntentEvent` (models/gtm.py:539) with `connector`, `eventType`, `score`, `confidence`, `occurredAt`.

### 2e. BYO Enrichment Waterfall (V2 Leaf3, REVA-35349)

**Source:** `backend/routes/enrichment_byo_providers.py`

- Customer-registered BYO enrichment provider framework with SSRF protection, IDN validation, DNS-rebinding TOCTOU closure.
- Canonical enrichment field set defined in `BYO_PROVIDER_FIELDS` (line 67+).
- Enrichment results written back to `gtm_signals` / `gtm_outcomes` via `routes/enrichment_jobs.py`.
- **Signal model:** `GtmSignal` with `sourceConnector="byo_provider"`, `signalType` indicating enrichment source, `score` and `confidence` from provider response.

### 2f. Audit/Outcome Event Models

**Source:** `backend/models/gtm.py` — `GtmOutcome` (490), `GtmSignal` (517), `IntentEvent` (539), `GtmShareAuditEvent` (2405), `GtmAuditTimelineEvent` (2466)

- `GtmOutcome` records: `id`, `userId`, `workspaceId`, `goalId`, `motionId`, `actionId`, `accountId`, `connector`, `subjectType`, `subjectId`, `outcomeType`, `status`, `title`, `summary`, `sentiment`, `sourceType`, `evidence`, `metadata`, `dedupeKey`, `createdAt`, `updatedAt`, `recordedAt`.
- `GtmSignal` records: `id`, `sourceConnector`, `sourceType`, `objectFamily`, `signalType`, `signalClass`, `score`, `confidence`, `occurredAt`.
- `IntentEvent` records: `connector`, `eventType`, `title`, `accountId`, `contactId`, `score`, `confidence`, `sourceId`, `occurredAt`.

---

## 3. What Already Exists for the Learning Loop

### 3a. Outcome Recording (Closed Loop Head — WRITE side)

`GtmOutcome` is already populated:
- Via `override_learning_service.py` `record_outcome_feedback` (line 1184+): records `OutcomeFeedback` docs, emits `outcome_feedback` events, writes to `gtm_outcome_feedback` collection, creates `MemoryRecord` with `entityType="outcome_feedback"`, attaches `learningLoopAttribution` signal metadata.
- Via `reply_lifecycle_service.py`: reply lifecycle receipts classified as positive/negative outcomes.
- Via `revops_signal_orchestration_service.py`: signal-origin outcomes written with `signal_origin=revops_signal`.

`POSITIVE_OUTCOMES` constant (override_learning_service.py:25):
`{"meeting_booked", "opportunity_progressed", "positive_reply", "qualified_intent", "won"}`

`NEGATIVE_OUTCOMES` constant (override_learning_service.py:26):
`{"lost", "no_response", "manual_override", "noisy_signal", "false_positive"}`

### 3b. Outcome Reading (Closed Loop Tail — READ side)

`backend/routes/learning.py` (lines 1–951) implements:
- `GET /api/learning/performance/plays` — per-play reply/meeting/conversion rates, execution counts, 30-day trend deltas vs prior period.
- `GET /api/learning/performance/plays/{id}` — per-play stats with `review_recommended` flag when any metric drops >10% vs prior period.
- `GET /api/learning/performance/plays/{id}/step-funnel` — sent/reply counts per motion step.
- Minimum 30 executions before stats (below: `"warming_up"` flag).

### 3c. Priority/Scoring Substrate

- `signal_engine.py` (lines 1–281): `_signal_weighted_score` combining `score × confidence × decay_multiplier`; `_signal_freshness_state` ("fresh" ≤24h, "warning" ≤72h, "stale" >72h); `_signal_decay_multiplier` (1.0 fresh → 0.2 stale); `_signal_pressure` from signal mix counts.
- `priority_scoring_service.py` (lines 1–893): `PRIORITY_FACTOR_LABELS` keys (`baseFit`, `signalScore`, `researchDiscoveryBoost`, `recencyBoost`, `adaptationBoost`, `connectorTrustBoost`); `summarize_priority_factors`; `_goal_prediction_score` (deterministic keyword scoring — not learning-based).

**Critical gap:** `_goal_prediction_score` is a static heuristic (lines 71–77). It returns 0.81 for "25%" goals, 0.76 for "expand/revenue", 0.68 default. This is **not** a learned function. It does not use `GtmOutcome` history to update scores.

### 3d. The Actual Gap: No Feedback Path

The loop has a head (write `GtmOutcome`) and a tail (read via `learning.py`). What is missing is the **middle**: a service function that reads recent `GtmOutcome` data for a play/sequence and writes priority adjustments back to `GtmPlay.priority` or `GtmSequenceStep.order`.

`GtmPlay` (models/gtm.py:353) has a `priority: int = 50` field. This field is settable but **nothing currently writes to it based on outcome history**.

`GtmSequenceStep` (models/gtm.py:303) has an `order: int` field and `status`. Sequence step ordering is set at creation; nothing reorders based on step-level reply rates tracked in `learning.py` step-funnel data.

---

## 4. Options Analysis

### Option A — Full Learning Loop (Recommended: Phase)

**What:** Automated feedback from `GtmOutcome` history → `GtmPlay.priority` adjustments and `GtmSequenceStep` reordering.

**Data model additions:**
- New collection `gtm_learning_config`: `{workspaceId, playId, outcomeTypes[], weightPositive, weightNegative, enabled, updatedAt}`
- Extend `GtmPlay.priority` with an `overrideSource: "learning" | null` annotation (backward-compatible — added to metadata dict, not new column)

**API surface additions:**
- `GET /api/learning/config/{playId}` — read current learning config
- `PATCH /api/learning/config/{playId}` — update outcome type weights
- `POST /api/learning/refresh-play-priorities` — run priority recomputation (called by scheduled job or after outcome threshold)
- `GET /api/learning/accounts/{accountId}/signal-summary` — aggregate signal history per account for prioritization (supports Phase 2)

**Phase 1 (GO, no new paid data):**
Build `learning_loop_service.py` with:
1. `compute_play_priority_adjustment(db, playId)` — reads `GtmOutcome` grouped by `motionId` (which backs the play), applies `POSITIVE_OUTCOMES`/`NEGATIVE_OUTCOMES` weights, outputs a signed adjustment delta.
2. `apply_sequence_step_reorder(db, motionId)` — reads step-funnel data from `learning.py` aggregation, updates `gtm_motion_steps.order` for steps with reply_rate below threshold.
3. Attach as a scheduled job (cadence: after each `outcome_feedback_recorded` event, debounced to hourly max).
4. `review_recommended` flag already exists in `learning.py`; wire it to `GtmPlay.status = "review_requested"` when adjustment is large.

**Phase 2 (DEFER, blocked on Phase 1 runtime evidence):**
Account-level signal aggregation: compute `account_signal_pressure` per `GtmSignal` group-by `accountId`, feed into `priority_scoring_service.list_accounts_prioritized` as a learning-derived boost. Requires `signal_engine._signal_pressure` to be called per-account in a batch job. Not built yet; defer until Phase 1 has production data.

**Credential/data gate check:**
- No new `ENABLE_*` flags required.
- No new API keys required (Apollo/Clearbit/ZoomInfo signals are already consumed by `revops_signal_orchestration_service.py`).
- BYO enrichment uses `db.byo_provider_credentials` — customer-supplied URLs, no new paid account.
- **Stop condition not triggered.**

### Option B — Learning Stats Dashboard Only (Alternative Kill)

**What:** Stop at reading `GtmOutcome` for the existing `learning.py` stats API; do not write back priority adjustments.

**Verdict:** This is essentially the current state (the gap is the write-back). Killing this option means accepting that the learning loop is permanently half-open. Given that `GtmPlay.priority` and `GtmSequenceStep.order` are both already modeled and settable, building only the read side leaves clear product value on the table.

### Option C — Kill / Do Not Productize

**What:** Remove the learning loop from V2 scope entirely.

**Verdict:** V2 roadmap item 11 explicitly names "Signal breadth and learning-loop productization." Killing it requires a board-level V2 roadmap revision. This is a legitimate option if the board determines that the priority/scoring infrastructure is not mature enough to trust with automated adjustments. However, the **design** can still be built and held for a later V2.x.

---

## 5. Recommendation

**Verdict: DEFER Phase 2; CONDITIONALLY GO Phase 1**

**Phase 1 is a GO** because:
1. The signal-producing surfaces already exist and are already populating `GtmOutcome`, `GtmSignal`, and `IntentEvent`.
2. The read side (`learning.py`) already exists and computes per-play stats.
3. The gap is precisely one new service (`learning_loop_service.py`) plus four new API endpoints — bounded, testable, no new paid data sources.
4. `GtmPlay.priority` and `GtmSequenceStep.order` are already modeled; writing to them is additive.
5. The `review_recommended` flag in `learning.py` already has the human-in-the-loop hook; Phase 1 just automates the draft adjustment and defers to human approval by default.

**Phase 2 is DEFERRED** because:
1. Account-level signal aggregation (`signal_engine._signal_pressure` per account) is not currently called in batch; it would need a new job and a new `signal_mix` per-account materialized view.
2. Phase 2's value depends on Phase 1 producing enough outcome data to train or tune the aggregation.
3. The account prioritization path (`priority_scoring_service.list_accounts_prioritized`) already exists; Phase 2 just injects a new boost factor. Defer until the boost factor has enough history to be meaningful.

**Kill path:** If CEO/CTO determines that automated `GtmPlay.priority` write-backs are premature before V1 Customer Zero is closed, the correct move is to **DEFER Phase 1 to a post-V1-CZ milestone**, not to design it away. The design remains available; only the implementation is held.

---

## 6. Open Gating Questions (for CEO/CTO Ruling)

1. Should Phase 1 `GtmPlay.priority` adjustments go live automatically, or require human approval before applying?
2. Should the learning loop be workspace-isolated (each workspace's outcomes affect only that workspace's plays), or should cross-workspace aggregation inform a global model?
3. Is the 30-execution minimum in `learning.py` (line 36) the right threshold for Phase 1 activation, or should it be higher?

---

## 7. Files/Models Referenced

| File | Lines | What it provides |
|---|---|---|
| `backend/models/gtm.py` | 490–514 | `GtmOutcome` model |
| `backend/models/gtm.py` | 517–537 | `GtmSignal` model |
| `backend/models/gtm.py` | 539–556 | `IntentEvent` model |
| `backend/models/gtm.py` | 303–343 | `GtmSequenceStep` model |
| `backend/models/gtm.py` | 353–388 | `GtmPlay` model (priority field at 368) |
| `backend/routes/learning.py` | 1–951 | Learning performance stats API |
| `backend/routes/email_send.py` | 1–200+ | Unsubscribe / reply handling |
| `backend/core/services/reply_lifecycle_service.py` | 1–450+ | Reply lifecycle receipts |
| `backend/core/services/revops_signal_orchestration_service.py` | 1–1001 | RevOps signal → CRM pipeline |
| `backend/routes/enrichment_byo_providers.py` | 1–400+ | BYO enrichment framework |
| `backend/core/services/signal_engine.py` | 1–281 | Signal scoring, freshness, decay |
| `backend/core/services/priority_scoring_service.py` | 1–893 | Priority factor labels, scoring |
| `backend/core/services/override_learning_service.py` | 1–100+, 1184–1450 | Outcome feedback, outcome sets |
| `backend/core/services/connector_kernel.py` | — | CRM mutation governance |

---

## 8. Credential/Paid-Data Gate Check

**Stop condition (per issue description):** if productizing this requires a new paid data source, account, or credential, name the gate and stop.

**Result: Stop condition NOT triggered.**
- Phase 1 reads existing `GtmOutcome` / `GtmSignal` / `GtmSequenceStep` records — no new provider calls.
- Phase 1 writes back to `gtm_motion_steps` and `gtm_motions` — existing collections.
- No new `ENABLE_*` flags required.
- BYO enrichment waterfall uses customer-supplied URLs; no new Signatiq-paid account.
- Apollo/Clearbit/Crunchbase/ZoomInfo signals are already consumed by `revops_signal_orchestration_service.py` — no new credential for learning loop.
