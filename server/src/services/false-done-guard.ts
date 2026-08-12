/**
 * false-done-guard.ts
 *
 * Server-side evidence judge at the issue `done`-transition.
 * Prevents agents from closing an issue unless an independent judge
 * confirms acceptance / stop-condition evidence is present.
 *
 * Behavior contract (approved option A):
 * - Verdict schema: { "ok": boolean, "reason": string, "missing": string[] }
 * - FALSE_DONE_GUARD_MODE: "off" (no-op, DEFAULT), "shadow" (judge runs, verdict LOGGED, never blocks),
 *   "canary_block" (block ok:false on canary only; off-canary shadows only)
 * - Canary scope = code-bearing close-gate issues (changing product/UI/content code)
 * - ok:false on canary in canary_block → reject transition, HTTP 4xx with reason + missing[]
 * - Judge unavailable / parse-fail → FAIL-OPEN: allow transition, emit false_done_guard_skipped metric
 * - Judge model: PAPERCLIP_FALSE_DONE_JUDGE_MODEL env (existing adapter model path, env-named config only)
 *
 * STOP conditions that require CTO escalation:
 * - Aux judge-model path cannot be reused without new model/adapter config
 * - Other done-writers exist beyond issueService.update (grep for status: 'done' writers)
 */

import { logger } from "../middleware/logger.js";

// ---------------------------------------------------------------------------
// Env config
// ---------------------------------------------------------------------------

export type FalseDoneGuardMode = "off" | "shadow" | "canary_block";

const VALID_MODES: FalseDoneGuardMode[] = ["off", "shadow", "canary_block"];

/** Parse FALSE_DONE_GUARD_MODE env var. Defaults to "off". */
export function falseDoneGuardMode(): FalseDoneGuardMode {
  const raw = process.env.FALSE_DONE_GUARD_MODE?.trim().toLowerCase();
  if (!raw) return "off";
  if (VALID_MODES.includes(raw as FalseDoneGuardMode)) return raw as FalseDoneGuardMode;
  logger.warn(`[false-done-guard] Unknown FALSE_DONE_GUARD_MODE="${raw}", defaulting to "off"`);
  return "off";
}

/** PAPERCLIP_FALSE_DONE_JUDGE_MODEL: model ID for the evidence judge (env-named config only). */
export function falseDoneJudgeModel(): string {
  return process.env.PAPERCLIP_FALSE_DONE_JUDGE_MODEL?.trim() ?? "";
}

// ---------------------------------------------------------------------------
// Canary scope predicate
// ---------------------------------------------------------------------------

/**
 * Canary scope = code-bearing close-gate issues (changing product/UI/content code).
 *
 * Scope is defined as issues that:
 *   (a) Have a non-routine_execution originKind  — routine executions are infraautomation,
 *       not product code changes, so they do not go through the product review gate.
 *   (b) OR have an executionPolicy — the presence of an execution policy means the issue
 *       was explicitly routed for code-bearing work (agentic execution with workspace).
 *
 * This is a single, testable predicate. Update if the scope definition changes.
 */
export function isFalseDoneCanaryScope(issue: {
  originKind?: string | null;
  executionPolicy?: unknown;
}): boolean {
  if (issue.executionPolicy !== undefined && issue.executionPolicy !== null) {
    return true;
  }
  if (issue.originKind !== undefined && issue.originKind !== null && issue.originKind !== "routine_execution") {
    return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// Verdict parse
// ---------------------------------------------------------------------------

export interface FalseDoneVerdict {
  ok: boolean;
  reason: string;
  missing: string[];
}

/**
 * Parse a judge response into a FalseDoneVerdict.
 * Returns null if the response cannot be parsed (caller should fail-open).
 */
export function parseFalseDoneVerdict(raw: string): FalseDoneVerdict | null {
  let parsed: unknown;
  try {
    // Strip any markdown code fences that some models emit
    const stripped = raw.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/i, "").trim();
    parsed = JSON.parse(stripped);
  } catch {
    return null;
  }
  if (typeof parsed !== "object" || parsed === null) return null;
  const obj = parsed as Record<string, unknown>;
  if (typeof obj.ok !== "boolean") return null;
  return {
    ok: obj.ok,
    reason: typeof obj.reason === "string" ? obj.reason : String(obj.reason ?? ""),
    missing: Array.isArray(obj.missing) ? obj.missing.filter((m) => typeof m === "string") : [],
  };
}

// ---------------------------------------------------------------------------
// Judge evidence builder
// ---------------------------------------------------------------------------

/**
 * Build the judge prompt from run-liveness evidence.
 * Reuses the full evidence inventory shape from
 * run-liveness.ts (RunLivenessEvidenceInput, lines 16-24 / 172-207) so the
 * judge sees every signal the liveness classifier already tracks — not just
 * comment/work-product counts. The collection itself is done in
 * `collectFalseDoneEvidence` (issues.ts), mirroring activity.ts.
 *
 * Evidence fields (all issue-scoped totals):
 * - issueCommentsCreated: number of comments on the issue
 * - documentRevisionsCreated: non-continuation document revisions
 * - planDocumentRevisionsCreated: revisions on the `plan` document
 * - workProductsCreated: work product files created
 * - workspaceOperationsCreated: workspace operations recorded
 * - activityEventsCreated: activity-log events for the issue
 * - toolOrActionEventsCreated: meaningful heartbeat run events (non-lifecycle)
 * - latestEvidenceAt: most recent evidence timestamp (ISO string)
 */
export interface FalseDoneJudgeEvidence {
  issueTitle: string;
  issueDescription: string;
  issueIdentifier: string;
  issueCommentsCreated: number;
  documentRevisionsCreated: number;
  planDocumentRevisionsCreated: number;
  workProductsCreated: number;
  workspaceOperationsCreated: number;
  activityEventsCreated: number;
  toolOrActionEventsCreated: number;
  latestEvidenceAt: string | null;
}

const JUDGE_SYSTEM_PROMPT = `You are a strict independent judge evaluating whether an autonomous agent has provided sufficient evidence that an issue's stop condition / acceptance criteria have been met before it is marked done.

You receive:
- The issue title and description (what the issue asked for)
- Evidence of work products created, comments posted, and document revisions made

Your job: determine whether the evidence is sufficient to confirm the issue is truly complete.

Reply ONLY with a single JSON object on one line:
{"ok": true, "reason": "<one-sentence rationale>"}
{"ok": false, "reason": "<one-sentence rationale>", "missing": ["<what is still missing>", "..."]}

ok=true ONLY when:
- The issue's stated goal has been demonstrably achieved (code written, PR opened, config changed, etc.)
- Acceptance criteria appear to be met based on the evidence

ok=false when:
- The evidence is thin or missing (no work products, no comments explaining the outcome)
- The issue appears to have been closed without sufficient work
- Only setup or exploratory work is shown but the actual deliverable is absent
`;

export function buildJudgePrompt(evidence: FalseDoneJudgeEvidence): string {
  const parts = [
    `Issue: ${evidence.issueIdentifier} — ${evidence.issueTitle}`,
    evidence.issueDescription ? `Description: ${evidence.issueDescription}` : null,
    "",
    "Evidence of work:",
    evidence.issueCommentsCreated > 0
      ? `- ${evidence.issueCommentsCreated} issue comment(s) posted`
      : "- No issue comments posted",
    evidence.documentRevisionsCreated > 0
      ? `- ${evidence.documentRevisionsCreated} document revision(s) created`
      : "- No document revisions",
    evidence.planDocumentRevisionsCreated > 0
      ? `- ${evidence.planDocumentRevisionsCreated} plan document revision(s)`
      : null,
    evidence.workProductsCreated > 0
      ? `- ${evidence.workProductsCreated} work product file(s) created`
      : "- No work products created",
    evidence.workspaceOperationsCreated > 0
      ? `- ${evidence.workspaceOperationsCreated} workspace operation(s)`
      : null,
    evidence.activityEventsCreated > 0
      ? `- ${evidence.activityEventsCreated} activity event(s)`
      : null,
    evidence.toolOrActionEventsCreated > 0
      ? `- ${evidence.toolOrActionEventsCreated} tool/action event(s)`
      : null,
    evidence.latestEvidenceAt ? `- Most recent activity: ${evidence.latestEvidenceAt}` : null,
    "",
    "Based on this evidence, is the issue truly done?",
  ]
    .filter((p): p is string => p !== null)
    .join("\n");

  return [
    JUDGE_SYSTEM_PROMPT,
    "",
    "---",
    "",
    parts,
  ].join("\n");
}

// ---------------------------------------------------------------------------
// Judge LLM call via Paperclip HTTP adapter gateway
// ---------------------------------------------------------------------------

/**
 * Call the evidence judge via the Paperclip gateway.
 * Uses the PAPERCLIP_FALSE_DONE_JUDGE_MODEL env to select the model adapter.
 *
 * Falls back to fail-open on any error (network, timeout, API failure).
 * A broken judge must NEVER wedge fleet closes.
 */
export async function callFalseDoneJudge(
  prompt: string,
  modelId: string,
  apiBase: string,
  apiKey: string,
): Promise<FalseDoneVerdict | null> {
  if (!modelId) return null;
  if (!apiKey) return null;

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 60_000);

  try {
    const res = await fetch(`${apiBase}/api/chat/completions`, {
      method: "POST",
      signal: controller.signal,
      headers: {
        "content-type": "application/json",
        "authorization": `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        model: modelId,
        messages: [
          { role: "system", content: JUDGE_SYSTEM_PROMPT },
          { role: "user", content: prompt },
        ],
        max_tokens: 512,
        temperature: 0,
      }),
    });

    clearTimeout(timer);

    if (!res.ok) {
      logger.error(`[false-done-guard] Judge API returned ${res.status}`);
      return null;
    }

    const json = await res.json() as { choices?: Array<{ message?: { content?: string } }> };
    const content = json?.choices?.[0]?.message?.content ?? "";
    return parseFalseDoneVerdict(content);
  } catch (err) {
    clearTimeout(timer);
    const msg = err instanceof Error ? err.message : String(err);
    logger.error(`[false-done-guard] Judge call failed: ${msg}`);
    return null;
  }
}

// ---------------------------------------------------------------------------
// Metric emit (fail-open fallback)
// ---------------------------------------------------------------------------

function emitGuardSkipped(issueId: string, reason: string): void {
  // Metric + structured log so Ops can detect a broken judge without requiring
  // the guard to wedge the fleet.  Using a namespaced key to avoid collisions.
  logger.warn(
    { metric: "false_done_guard_skipped", issueId, reason },
    `[false-done-guard] Guard skipped for issue ${issueId}: ${reason}`,
  );
}

// ---------------------------------------------------------------------------
// Main guard function
// ---------------------------------------------------------------------------

/**
 * Optional close-evidence deltas to merge with the collected evidence before
 * judging. Used by callers that know additional evidence is about to be
 * persisted in the same request — e.g. the PATCH /issues/:id route persists
 * a close comment AFTER `issueService.update()` returns, so the comment
 * isn't visible to `collectFalseDoneEvidence` but IS visible to the judge
 * when the route passes it through via `closeEvidence`.
 *
 * Without this channel the judge can only see pre-update evidence and will
 * judge same-request close evidence as "missing" — which in canary_block
 * mode can wrongly reject a valid close, and in shadow mode creates
 * false-negative noise.
 */
export interface FalseDoneCloseEvidence {
  /**
   * A non-empty close comment body that the caller is about to persist in
   * the same request. When supplied, the guard treats it as one additional
   * issue comment for evidence-counting purposes. An empty string is
   * treated as "no pending comment" and produces no delta.
   */
  pendingCommentBody?: string | null;
}

/**
 * Merge optional close-evidence deltas into a collected evidence snapshot.
 *
 * Rules:
 * - If `pendingCommentBody` is a non-empty string, add 1 to
 *   `issueCommentsCreated` and bump `latestEvidenceAt` to "now" (the
 *   comment is about to be created in the same request).
 * - If `pendingCommentBody` is empty/null/undefined, return the evidence
 *   unchanged.
 *
 * This is exported so the route layer can preview the merged evidence for
 * telemetry / structured logging, and so the regression test in
 * `false-done-guard.test.ts` can exercise the merge in isolation from the
 * judge call.
 */
export function mergeCloseEvidence(
  evidence: FalseDoneJudgeEvidence,
  closeEvidence?: FalseDoneCloseEvidence | null,
): FalseDoneJudgeEvidence {
  const pending = closeEvidence?.pendingCommentBody;
  if (typeof pending !== "string" || pending.length === 0) {
    return evidence;
  }
  const nextLatest = new Date().toISOString();
  const existingLatestMs = evidence.latestEvidenceAt
    ? Date.parse(evidence.latestEvidenceAt)
    : Number.NEGATIVE_INFINITY;
  const merged: FalseDoneJudgeEvidence = {
    ...evidence,
    issueCommentsCreated: evidence.issueCommentsCreated + 1,
    latestEvidenceAt:
      Number.isFinite(existingLatestMs) && existingLatestMs > Date.parse(nextLatest)
        ? evidence.latestEvidenceAt
        : nextLatest,
  };
  return merged;
}

export interface FalseDoneGuardInput {
  issueId: string;
  issueIdentifier: string;
  issueTitle: string;
  issueDescription: string;
  evidence: FalseDoneJudgeEvidence;
  /**
   * Optional close-evidence deltas (e.g. a comment body that will be
   * persisted in the same request). Merged into `evidence` before the
   * judge runs, so same-request close evidence is visible. See
   * `FalseDoneCloseEvidence` and `mergeCloseEvidence`.
   */
  closeEvidence?: FalseDoneCloseEvidence | null;
  mode: FalseDoneGuardMode;
  /**
   * Whether the issue is in canary scope (see isFalseDoneCanaryScope).
   * Only used in canary_block mode: ok:false blocks ONLY when inCanary is true.
   * Off-canary issues in canary_block mode still run the judge but shadow-log only.
   */
  inCanary: boolean;
  judgeModelId: string;
  judgeApiKey: string;
  judgeApiBase: string;
}

export interface FalseDoneGuardResult {
  allowed: boolean;
  reason?: string;
  missing?: string[];
  shadowLog?: boolean;
}

/**
 * assertFalseDoneGuard — the main guard function.
 *
 * Called between assertTransition and applyStatusSideEffects in issueService.update,
 * gated only when transitioning to status === 'done'.
 *
 * Behavior:
 * - mode=off: no-op, returns { allowed: true }
 * - mode=shadow: judge runs, verdict LOGGED, never blocks (regardless of canary scope)
 * - mode=canary_block: judge runs for EVERY issue; if ok:false AND issue in canary scope → reject with 4xx;
 *                     if ok:false AND issue NOT in canary scope → shadow log only (off-canary shadows)
 *
 * Any judge error / parse failure: FAIL-OPEN (allow transition, emit false_done_guard_skipped).
 */
export async function assertFalseDoneGuard(input: FalseDoneGuardInput): Promise<FalseDoneGuardResult> {
  const { issueId, issueIdentifier, mode, inCanary, judgeModelId, judgeApiKey, judgeApiBase } = input;

  if (mode === "off") {
    return { allowed: true };
  }

  // Same-request close evidence: callers that know additional evidence is
  // about to be persisted in this request (e.g. the PATCH /issues/:id route
  // posts the close comment AFTER issueService.update() returns) must pass
  // it through `closeEvidence` so the judge can see the full evidence set
  // before deciding. Without this channel the judge would only see
  // pre-update evidence and the guard could wrongly reject a valid close in
  // canary_block mode (or log a false negative in shadow mode).
  const mergedEvidence = mergeCloseEvidence(input.evidence, input.closeEvidence ?? null);
  const prompt = buildJudgePrompt(mergedEvidence);
  const verdict = await callFalseDoneJudge(prompt, judgeModelId, judgeApiBase, judgeApiKey);

  if (verdict === null) {
    emitGuardSkipped(issueId, "judge_unavailable_or_parse_failure");
    return { allowed: true };
  }

  if (!verdict.ok) {
    const logMsg =
      `[false-done-guard] Judge verdict=false for ${issueIdentifier}: ${verdict.reason}` +
      (verdict.missing.length > 0 ? `  Missing: ${verdict.missing.join(", ")}` : "");
    logger.warn(
      { metric: "false_done_verdict_rejected", issueId: issueIdentifier, reason: verdict.reason, missing: verdict.missing },
      logMsg,
    );

    // shadow mode never blocks. canary_block only blocks in-canary issues;
    // off-canary issues in canary_block still run the judge but shadow-log only.
    if (mode === "shadow" || !inCanary) {
      return { allowed: true, shadowLog: true };
    }

    // mode === "canary_block" AND inCanary → reject the transition.
    return {
      allowed: false,
      reason: verdict.reason,
      missing: verdict.missing,
    };
  }

  // ok === true
  logger.info(
    { metric: "false_done_verdict_accepted", issueId: issueIdentifier, reason: verdict.reason },
    `[false-done-guard] Judge verdict=true for ${issueIdentifier}: ${verdict.reason}`,
  );

  return { allowed: true };
}
