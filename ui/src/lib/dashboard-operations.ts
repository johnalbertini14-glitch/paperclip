import type {
  ActivityEvent,
  Approval,
  AttentionItem,
  AttentionSourceKind,
  Issue,
  RoutineListItem,
} from "@paperclipai/shared";

export type BoardAttentionKind = "decision" | "recovery" | "blocked" | "routine";
export type BoardAttentionSeverity = "critical" | "high" | "medium" | "low";

export interface BoardAttentionItem {
  id: string;
  kind: BoardAttentionKind;
  severity: BoardAttentionSeverity;
  title: string;
  description: string;
  actionLabel: string;
  occurredAt: Date | string;
  score: number;
  issue: Issue | null;
  approval: Approval | null;
  routine: RoutineListItem | null;
  /** Native attention-feed rows carry a link instead of a loaded entity. */
  href: string | null;
  identifier: string | null;
}

interface BuildBoardAttentionInput {
  approvals: Approval[];
  blockedIssues: Issue[];
  routines: RoutineListItem[];
  /** Rows from the native `/companies/:id/attention` feed (optional). */
  attention?: AttentionItem[];
  now?: Date;
}

const severityWeight: Record<BoardAttentionSeverity, number> = {
  critical: 400,
  high: 300,
  medium: 200,
  low: 100,
};

const priorityWeight: Record<string, number> = {
  critical: 40,
  high: 30,
  medium: 20,
  low: 10,
};

function recordValue(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function textValue(value: unknown): string | null {
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : null;
}

function approvalCopy(approval: Approval): { title: string; description: string } {
  const payload = recordValue(approval.payload);
  const title = textValue(payload?.title)
    ?? textValue(payload?.summary)?.split(/[.!?]\s/)[0]
    ?? approval.type.replaceAll("_", " ");
  const description = textValue(payload?.recommendedAction)
    ?? textValue(payload?.summary)
    ?? "A governed action is waiting for a Board decision.";
  return { title, description };
}

function ageHours(value: Date | string, now: Date): number {
  const timestamp = new Date(value).getTime();
  if (!Number.isFinite(timestamp)) return 0;
  return Math.max(0, (now.getTime() - timestamp) / 3_600_000);
}

function ageSeverity(value: Date | string, now: Date): BoardAttentionSeverity {
  const hours = ageHours(value, now);
  if (hours >= 24 * 30) return "critical";
  if (hours >= 24 * 7) return "high";
  if (hours >= 24) return "medium";
  return "low";
}

function scoreItem(
  severity: BoardAttentionSeverity,
  occurredAt: Date | string,
  now: Date,
  typeBonus: number,
  priority?: string | null,
): number {
  return severityWeight[severity]
    + Math.min(ageHours(occurredAt, now), 240)
    + typeBonus
    + (priority ? priorityWeight[priority] ?? 0 : 0);
}

function issueOccurredAt(issue: Issue): Date | string {
  return issue.blockedInboxAttention?.stoppedSinceAt
    ?? issue.activeRecoveryAction?.createdAt
    ?? issue.scheduledRetry?.scheduledRetryAt
    ?? issue.updatedAt;
}

function issueSeverity(issue: Issue, occurredAt: Date | string, now: Date): BoardAttentionSeverity {
  return issue.blockedInboxAttention?.severity ?? ageSeverity(occurredAt, now);
}

function issueDescription(issue: Issue, kind: BoardAttentionKind): string {
  const attention = issue.blockedInboxAttention;
  if (kind === "recovery") {
    return issue.activeRecoveryAction?.nextAction
      ?? issue.scheduledRetry?.scheduledRetryReason
      ?? attention?.action.detail
      ?? attention?.action.label
      ?? "Recovery is ready but needs a Board intervention.";
  }
  return attention?.action.detail
    ?? attention?.action.label
    ?? issue.description
    ?? "This work cannot continue until its blocker or owner is resolved.";
}

function isRecoveryIssue(issue: Issue): boolean {
  return issue.activeRecoveryAction?.status === "active"
    || issue.activeRecoveryAction?.status === "escalated"
    || issue.scheduledRetry?.status === "scheduled_retry"
    || issue.scheduledRetry?.status === "queued"
    || issue.blockedInboxAttention?.state === "recovery_open"
    || issue.blockedInboxAttention?.reason === "open_recovery_issue";
}

function isDecisionIssue(issue: Issue): boolean {
  return issue.blockedInboxAttention?.state === "awaiting_decision"
    || issue.blockedInboxAttention?.reason === "pending_board_decision"
    || issue.blockedInboxAttention?.reason === "pending_user_decision";
}

export function requiresBoardAttention(issue: Issue): boolean {
  if (isRecoveryIssue(issue)) return true;

  const attention = issue.blockedInboxAttention;
  if (!attention) return false;

  if (attention.reason === "blocked_chain_stalled") return true;

  return attention.owner.type === "board"
    || attention.owner.type === "user"
    || attention.owner.type === "external"
    || attention.owner.type === "unknown";
}

export function buildBoardAttention({
  approvals,
  blockedIssues,
  routines,
  attention,
  now = new Date(),
}: BuildBoardAttentionInput): BoardAttentionItem[] {
  const decisions = approvals
    .filter((approval) => approval.status === "pending")
    .map((approval): BoardAttentionItem => {
      const occurredAt = approval.createdAt;
      const severity = ageSeverity(occurredAt, now);
      const copy = approvalCopy(approval);
      return {
        id: `approval:${approval.id}`,
        kind: "decision",
        severity,
        title: copy.title,
        description: copy.description,
        actionLabel: "Review",
        occurredAt,
        score: scoreItem(severity, occurredAt, now, 30),
        issue: null,
        approval,
        routine: null,
        href: null,
        identifier: null,
      };
    });

  const work = blockedIssues
    .filter((issue) => issue.status !== "done" && issue.status !== "cancelled")
    .filter(requiresBoardAttention)
    .map((issue): BoardAttentionItem => {
      const kind: BoardAttentionKind = isRecoveryIssue(issue)
        ? "recovery"
        : isDecisionIssue(issue)
          ? "decision"
          : "blocked";
      const occurredAt = issueOccurredAt(issue);
      const severity = issueSeverity(issue, occurredAt, now);
      return {
        id: `issue:${issue.id}`,
        kind,
        severity,
        title: issue.title,
        description: issueDescription(issue, kind),
        actionLabel: kind === "recovery" && issue.scheduledRetry
          ? "Retry now"
          : kind === "decision"
            ? "Review"
            : "Inspect",
        occurredAt,
        score: scoreItem(severity, occurredAt, now, kind === "decision" ? 30 : kind === "recovery" ? 25 : 20, issue.priority),
        issue,
        approval: null,
        routine: null,
        href: null,
        identifier: issue.identifier ?? null,
      };
    });

  const failures = routines
    .filter((routine) => routine.status === "active")
    .filter((routine) => routine.lastRun?.status === "failed" || routine.lastRun?.status === "timed_out")
    .map((routine): BoardAttentionItem => {
      const run = routine.lastRun!;
      const occurredAt = run.updatedAt ?? run.triggeredAt;
      const severity = ageSeverity(occurredAt, now);
      return {
        id: `routine:${routine.id}`,
        kind: "routine",
        severity,
        title: routine.title,
        description: run.failureReason ?? "The latest routine run failed and may require intervention.",
        actionLabel: "Run now",
        occurredAt,
        score: scoreItem(severity, occurredAt, now, 15, routine.priority),
        issue: null,
        approval: null,
        routine,
        href: null,
        identifier: null,
      };
    });

  const coveredIssueIds = new Set(work.map((item) => item.issue?.id ?? ""));
  const coveredRecoveryIssueIds = new Set(work.filter((item) => item.kind === "recovery").map((item) => item.issue!.id));
  const native = nativeAttentionItems(attention, now, coveredIssueIds, coveredRecoveryIssueIds);

  return [...decisions, ...work, ...failures, ...native]
    .sort((left, right) => right.score - left.score || new Date(left.occurredAt).getTime() - new Date(right.occurredAt).getTime());
}

// Native attention-feed rows the July queue never surfaced. Evidence (30d of
// Board activity, 2026-09-20): thread interactions (questions, confirmations)
// were the Board's second most frequent UI decision after approvals, and 44
// were pending with no dashboard row. Approvals and blocked issues already
// come from their own queries above, so those source kinds are skipped here.
export const nativeDecisionSourceKinds: AttentionSourceKind[] = [
  "issue_thread_interaction",
  "decision",
  "review",
  "join_request",
  "agent_error_alert",
  "budget_alert",
];
export const nativeRecoverySourceKinds: AttentionSourceKind[] = ["recovery_action", "failed_run"];
const nativeDecisionKinds = new Set(nativeDecisionSourceKinds);
const nativeRecoveryKinds = new Set(nativeRecoverySourceKinds);
const nativeTypeBonus: Partial<Record<AttentionSourceKind, number>> = {
  issue_thread_interaction: 35,
  decision: 34,
  review: 32,
  agent_error_alert: 25,
  budget_alert: 25,
  recovery_action: 25,
  failed_run: 20,
  join_request: 20,
};

export function nativeAttentionItems(
  items: AttentionItem[] | undefined,
  now = new Date(),
  coveredIssueIds: Set<string> = new Set(),
  coveredRecoveryIssueIds: Set<string> = new Set(),
): BoardAttentionItem[] {
  return (items ?? [])
    .filter((item) => !item.dismissal?.isActive && !item.archivedAt)
    .filter((item) => nativeDecisionKinds.has(item.sourceKind) || nativeRecoveryKinds.has(item.sourceKind))
    .filter((item) => !(item.sourceKind !== "issue_thread_interaction" && item.subject.kind === "issue" && coveredIssueIds.has(item.subject.id)))
    .filter((item) => !(item.sourceKind === "recovery_action" && item.relatedIssue && coveredRecoveryIssueIds.has(item.relatedIssue.id)))
    .map((item): BoardAttentionItem => {
      const kind: BoardAttentionKind = nativeRecoveryKinds.has(item.sourceKind) ? "recovery" : "decision";
      const occurredAt = item.activityAt ?? item.createdAt;
      const issueRef = item.relatedIssue ?? (item.subject.kind === "issue" ? item.subject : null);
      const title = item.subject.title ?? issueRef?.title ?? item.sourceKind.replaceAll("_", " ");
      return {
        id: `attention:${item.id}`,
        kind,
        severity: item.severity,
        title,
        description: item.whyNow,
        actionLabel: item.inlineResolvable ? "Decide" : "Open",
        occurredAt,
        score: scoreItem(item.severity, occurredAt, now, nativeTypeBonus[item.sourceKind] ?? 20),
        issue: null,
        approval: null,
        routine: null,
        href: item.subject.href ?? issueRef?.href ?? "/decisions",
        identifier: issueRef?.identifier ?? null,
      };
    });
}

const activityNoisePatterns = [
  /lease[._-](acquired|released)/i,
  /environment[._-]lease/i,
  /heartbeat[._-](event|output|poll)/i,
  /run[._-](log|output)[._-]/i,
];

export function isMeaningfulBoardActivity(event: ActivityEvent): boolean {
  return !activityNoisePatterns.some((pattern) => pattern.test(event.action));
}

export function meaningfulBoardActivity(events: ActivityEvent[], limit = 5): ActivityEvent[] {
  const filtered = events.filter(isMeaningfulBoardActivity);
  return (filtered.length > 0 ? filtered : events).slice(0, limit);
}

export function countStaleApprovals(approvals: Approval[], now = new Date(), staleDays = 7): number {
  const threshold = now.getTime() - staleDays * 24 * 60 * 60 * 1000;
  return approvals.filter((approval) =>
    approval.status === "pending" && new Date(approval.createdAt).getTime() <= threshold).length;
}
