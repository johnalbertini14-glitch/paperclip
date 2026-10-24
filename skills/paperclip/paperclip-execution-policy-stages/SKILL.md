---
name: paperclip-execution-policy-stages
description: How a Paperclip issue's typed execution-policy review/approval stage is selected, advanced, and assigned to a specific participant agent. Covers the fact that executionState is server-owned and NOT a settable PATCH field, that the engine always starts at the FIRST non-completed stage, how a participant approval auto-advances to the next stage, the 422 catalogue, and how to re-arm or reorder stages. Use when a Paperclip issue has executionPolicy.stages / executionState and you need to route, advance, skip, or delegate a review/approval gate — or when you need to prove a claim about Paperclip server behaviour instead of guessing.
---

# Paperclip execution-policy review/approval stages

Typed execution stages are Paperclip's native cross-agent review gate. A stage is
a row in `executionPolicy.stages[]`; the **server** decides which stage is live and
which participant owns it, and writes that to `executionState` on the issue.

This skill answers the class of question: *"how do I get this issue's review stage
assigned to <specific agent> / advance it / skip it / re-arm it?"*

## The one rule that governs everything

> **`executionState` is server-owned. You cannot set it. `executionPolicy`,
> `status`, `assigneeAgentId`/`assigneeUserId`, `comment`, and `reviewRequest` are
> the only agent-callable inputs, and the engine derives the stage state from them.**

Concretely:

- `executionState` is **stripped** from `PATCH /api/issues/:id` bodies by Zod
  (the update schema is not `.strict()`, so unknown keys are dropped silently).
  Sending `executionState: {currentParticipant: ...}` is a **silent no-op**, not
  a 400. Verified empirically — see `references/engine-source-map.md`.
- There is **no** dedicated execution-policy / execution-decision / stage-advance
  route. The only mutating route is `PATCH /api/issues/:id`.
- Therefore the only way to change who owns the current stage is to change the
  *inputs* and let the engine recompute.

## Stage selection algorithm (verified)

The engine lives in `server/src/services/issue-execution-policy.ts`
(`applyIssueExecutionStageTransition`). Two paths matter:

**No live stage yet** (`executionState.status = "idle"`, `currentStageId = null`):

1. The workflow only starts if the PATCH requests `status: "done"` **or**
   `status: "in_review"`.
2. The stage chosen is `nextPendingStage()` = **the FIRST stage whose id is not
   in `completedStageIds`**. Order is the array order in `executionPolicy.stages`.
3. The participant is `selectStageParticipant()` = the **first** participant of
   that stage, preferring an explicitly requested `assigneeAgentId`/`assigneeUserId`,
   and excluding the original executor (no self-review).
4. Result: `status = "in_review"`, issue reassigned to the participant,
   `executionState = {status: "pending", currentStageId, currentStageIndex,
   currentStageType, currentParticipant, returnAssignee, ...}`, and the participant
   is woken with reason `execution_review_requested` / `execution_approval_requested`.

**Live stage pending** (`executionState.status = "pending"`):

- Only the **current participant** may act. Anyone else gets
  `422 "Only the active reviewer or approver can advance the current execution stage"`.
- Participant sends `{"status":"done","comment":"..."}` → **approved** decision.
  If another stage remains, the engine **auto-advances**: `currentStageId` moves to
  the next non-completed stage, `currentParticipant` is recomputed for it, the
  issue is reassigned to that participant and **stays `in_review`**. A decision row
  is written to `issue_execution_decisions`.
- Participant sends any non-`in_review` status (normally `in_progress`) with a
  comment → **changes_requested** decision. The issue goes back to `returnAssignee`
  and **keeps the same stage id** (a loop, not an advance).
- The executor resubmits with `{"status":"done","comment":"..."}` → returns to the
  **same** stage, same reviewer.

### Things that do NOT advance a stage

- A `changes_requested` decision never advances the stage id.
- There is **no round/attempt limit on review stages** and no multi-approval —
  `approvalsNeeded` is hard-locked to `1`. (`maxAttempts` in the schema belongs to
  the **monitor** subsystem, not review stages.)
- The **only** auto-skip is `canAutoSkipPendingStage()`: if a `review` stage's
  *only* participant is the executor itself, submitting `status: "done"` auto-skips
  it and lands on the next stage.
- An explicit `assigneeAgentId` on the PATCH is only a *"preferred participant"*
  hint **within the already-selected stage**. It can never select a different stage.

## How to reach a specific participant

Given stages `[S1: CodeChecker, S2: CTO]` and a want to land on CTO:

| Goal | Mechanism | Trade-off |
|---|---|---|
| Canonical two-gate audit trail | Executor PATCHes `status:"in_review"` → Code Checker PATCHes `status:"done"` with a comment → engine auto-advances to CTO | Full audit trail: `approved` decision on S1, then CTO owns S2. **Recommended.** |
| Land on CTO directly | Reorder `executionPolicy.stages` so CTO's stage is first, then PATCH `status:"in_review"` | **Only works while the issue is not already `in_review` with a pending stage.** A policy edit on an `in_review` issue is a no-op for stage state (no `executionState`, no assignee change, no wake). Also reorders the durable policy, so S1 now runs *after* CTO. |
| Have the Code Checker approve for you | Only the current participant (or a board user) can approve. A non-participant gets `422`. | You cannot approve on another agent's behalf. |
| Skip a stage | No API. Only: reorder the policy, or set `executionPolicy: null` (destroys the workflow, returns the issue to `returnAssignee` and clears `executionState`). | Not audit-clean. |

## Re-arming / resumption

There is no re-arm route. Available levers, all via `PATCH /api/issues/:id`:

| Lever | Body | Semantics |
|---|---|---|
| Resubmit after changes requested | `{"status":"done","comment":"..."}` (executor) | Returns to the **same** stage and reviewer. |
| Clear the policy | `{"executionPolicy": null}` | `executionState = null`, issue → `in_progress`, reassigned to `returnAssignee`. Workflow is gone. |
| Reorder the policy | `{"executionPolicy": {"stages":[...]}}` | New order takes effect for the *next* workflow start. No-op for stage state if the issue is already `in_review` with a pending stage. |
| Comment auto-approval | `POST /api/issues/:id/comments` with `kind: review` + `decision: approved` | Same engine, same auto-advance. Accepts `## Review: APPROVED` heading or the two consecutive `kind:`/`decision:` lines. |

`reopen` / `resume` are **issue-level**, not stage-level: they move the issue to
`todo` and do not re-arm a stage.

## The `in_review` review-path guard

Moving an issue to `in_review` as an **agent** requires a real review path, else
`422` with `error` containing `invalid_issue_disposition` and
`details = {code: "invalid_issue_disposition", missing: "review_path", validReviewPaths: [...]}`.

Valid paths (exactly these 5): `pending_issue_thread_interaction`,
`linked_pending_approval`, `human_assignee_user_id`,
`typed_execution_state_current_participant`, `scheduled_issue_monitor`.

The guard is skipped when the issue is **already** `in_review`, and for **board**
actors. `typed_execution_state_current_participant` is satisfied automatically
once the engine has assigned a participant — i.e. it is the *result* of starting
the workflow, not a prerequisite you set by hand.

See the companion skill `paperclip-in-review-patch-rejection` for the full
Code-Worker-side handling of a rejected `in_review` PATCH.

## Pitfalls

- **Do not send `executionState` in a PATCH body.** It is silently stripped, and
  you will get a `200` while believing you re-pointed the stage. Verify by reading
  `executionState` back with `GET /api/issues/:id` instead.
- **Do not assume a policy edit re-arms a live stage.** On an `in_review` issue it
  changes the stored policy only.
- **Do not try to "hand the issue to" the next reviewer by setting
  `assigneeAgentId`.** The engine overwrites the assignee from the selected stage's
  participant, and a mismatched assignee on a pending stage is treated as an
  attempted stage advance → `422`.
- **`changes_requested` is a loop, not an advance.** Read `currentStageId` — it
  does not move.
- **Workflow-controlled assignment bypasses task-assignment authz.** When the
  engine reassigns to a stage participant it sets `workflowControlledAssignment`,
  which skips `assertCanAssignTasks`. The assignee does **not** need permission to
  assign work to the reviewer.
- **Agent ownership still applies to the triggering PATCH.** An agent can only
  mutate an issue assigned to it (else `403 "Agent cannot mutate another agent's issue"`),
  and on `in_progress` it must own the checkout (else `409 "Issue is checked out by another agent"`).
- **Approval and change-request both require a non-empty comment.** Whitespace-only
  is rejected with `422`.

## 422 catalogue from the engine

| Message | Trigger |
|---|---|
| `Only the active reviewer or approver can advance the current execution stage` | Non-participant tried to advance, or tried to re-point the assignee on a pending stage. |
| `Approving a review or approval stage requires a comment` | `status:"done"` on a pending stage with empty/whitespace comment. |
| `Requesting changes requires a comment` | Non-`done` status on a pending stage with empty/whitespace comment. |
| `This execution stage has no return assignee` | Change-request on a stage with no `returnAssignee`. |
| `No eligible <review\|approval> participant is configured for this issue` | The selected stage's participants are all excluded (e.g. all are the executor). |
| `Cannot start a new review cycle without a current executor` | Resubmission with no current agent/user executor. |
| `Invalid execution policy` (+ Zod flatten) | `executionPolicy` failed schema validation. |
| `reviewRequest requires an active review or approval stage` | `reviewRequest` sent when state is not `pending`. |

## Proving a claim about Paperclip server behaviour (do not guess)

When you need to state how the server *actually* behaves, execute the real source
rather than reasoning from a code read. Two techniques that work well in the
Paperclip repo:

1. **`git grep -n` beats the file-search tool for big files.** `server/src/routes/issues.ts`
   is ~8.7k lines and structured-search output truncates on it. `git grep -n '<pattern>'
   -- server/src/routes/issues.ts` returns clean, complete, line-numbered matches.
   Use `git grep -n -A N '<pattern>' -- <path>` for context.

2. **Run the real service with a `tsx` probe harness.** The repo bundles `tsx` at
   `cli/node_modules/tsx/dist/cli.mjs`. Write a small TS harness in `/tmp` that
   imports the real service and prints the patch the engine produces, then:
   ```bash
   cd /paperclip/repos/paperclip
   node cli/node_modules/tsx/dist/cli.mjs /tmp/probe.ts
   ```
   This yields **actual** engine output (status, assignee, `executionState`,
   decision) instead of an inference, and it is read-only. A ready-made harness
   for the execution-policy engine is in `scripts/probe-execution-policy.ts` of
   this skill.

**Caveat when reporting probe results:** a service-layer probe exercises the
*engine*. It does **not** exercise the HTTP route layer, so it says nothing about
route-level behaviour (Zod body stripping, the `in_review` review-path guard,
agent ownership/authz, checkout locks). Verify those from the route source or
with a route test.

## Reference

- `references/engine-source-map.md` — source map (file:line), function-by-function
  engine walkthrough, error catalogue, the Zod-strip proof, and the verification
  transcripts this skill's claims are based on.
- `scripts/probe-execution-policy.ts` — runnable tsx harness that prints the
  engine's decision for each stage-advance scenario.
