import { describe, expect, it } from "vitest";
import type { ActivityEvent, Approval, AttentionItem, Issue, RoutineListItem } from "@paperclipai/shared";
import {
  buildBoardAttention,
  countStaleApprovals,
  meaningfulBoardActivity,
  nativeAttentionItems,
  requiresBoardAttention,
} from "./dashboard-operations";

const now = new Date("2026-07-17T16:00:00.000Z");

function approval(overrides: Partial<Approval> = {}): Approval {
  return {
    id: "approval-1",
    companyId: "company-1",
    type: "request_board_approval",
    requestedByAgentId: "agent-1",
    requestedByUserId: null,
    status: "pending",
    payload: {
      title: "Approve the production restart",
      recommendedAction: "Restart the worker to release the stuck write handle.",
    },
    decisionNote: null,
    decidedByUserId: null,
    decidedAt: null,
    createdAt: new Date("2026-06-01T12:00:00.000Z"),
    updatedAt: new Date("2026-06-01T12:00:00.000Z"),
    ...overrides,
  };
}

function issue(overrides: Partial<Issue> = {}): Issue {
  return {
    id: "issue-1",
    companyId: "company-1",
    projectId: null,
    projectWorkspaceId: null,
    goalId: null,
    parentId: null,
    reviewPolicy: null,
    responsibleUserId: null,
    title: "Feed backlog consumer is blocked",
    description: "Two validation tasks are waiting.",
    status: "blocked",
    workMode: "standard",
    priority: "high",
    assigneeAgentId: "agent-1",
    assigneeUserId: null,
    checkoutRunId: null,
    executionRunId: null,
    executionAgentNameKey: null,
    executionLockedAt: null,
    createdByAgentId: null,
    createdByUserId: null,
    issueNumber: 1,
    identifier: "PC-1",
    requestDepth: 0,
    billingCode: null,
    assigneeAdapterOverrides: null,
    executionWorkspaceId: null,
    executionWorkspacePreference: null,
    executionWorkspaceSettings: null,
    startedAt: null,
    completedAt: null,
    cancelledAt: null,
    hiddenAt: null,
    createdAt: new Date("2026-07-16T12:00:00.000Z"),
    updatedAt: new Date("2026-07-17T14:00:00.000Z"),
    blockedInboxAttention: {
      kind: "blocked",
      state: "needs_attention",
      reason: "blocked_chain_stalled",
      severity: "high",
      stoppedSinceAt: "2026-07-17T13:00:00.000Z",
      owner: { type: "board", agentId: null, userId: null, label: "Board" },
      action: { label: "Reassign the blocker", detail: "The current blocker has no viable owner." },
      sourceIssue: null,
      leafIssue: null,
      recoveryIssue: null,
      approvalId: null,
      interactionId: null,
      sampleIssueIdentifier: "PC-2",
      redaction: { externalDetailsRedacted: false, secretFieldsOmitted: true },
    },
    ...overrides,
  };
}

function routine(overrides: Partial<RoutineListItem> = {}): RoutineListItem {
  return {
    id: "routine-1",
    companyId: "company-1",
    projectId: null,
    goalId: null,
    parentIssueId: null,
    title: "Hourly DB backup",
    description: null,
    assigneeAgentId: "agent-1",
    responsibleUserId: null,
    priority: "critical",
    activityGatePolicy: "always",
    activityGateScope: "company",
    status: "active",
    concurrencyPolicy: "coalesce_if_active",
    catchUpPolicy: "skip_missed",
    variables: [],
    latestRevisionId: null,
    latestRevisionNumber: 1,
    createdByAgentId: null,
    createdByUserId: null,
    updatedByAgentId: null,
    updatedByUserId: null,
    lastTriggeredAt: new Date("2026-07-17T15:00:00.000Z"),
    lastEnqueuedAt: new Date("2026-07-17T15:00:00.000Z"),
    createdAt: new Date("2026-07-01T00:00:00.000Z"),
    updatedAt: new Date("2026-07-17T15:00:00.000Z"),
    triggers: [],
    activeIssue: null,
    lastRun: {
      id: "routine-run-1",
      companyId: "company-1",
      routineId: "routine-1",
      triggerId: null,
      source: "schedule",
      status: "failed",
      triggeredAt: new Date("2026-07-17T15:00:00.000Z"),
      idempotencyKey: null,
      triggerPayload: null,
      dispatchFingerprint: null,
      linkedIssueId: null,
      coalescedIntoRunId: null,
      failureReason: "Backup volume is read-only.",
      completedAt: new Date("2026-07-17T15:02:00.000Z"),
      createdAt: new Date("2026-07-17T15:00:00.000Z"),
      updatedAt: new Date("2026-07-17T15:02:00.000Z"),
      linkedIssue: null,
      trigger: null,
    },
    ...overrides,
  };
}

function activity(id: string, action: string): ActivityEvent {
  return {
    id,
    companyId: "company-1",
    actorType: "system",
    actorId: "system",
    action,
    entityType: "issue",
    entityId: "issue-1",
    agentId: null,
    runId: null,
    details: null,
    createdAt: now,
  };
}

describe("buildBoardAttention", () => {
  it("ranks a stale decision above blocked work and a recent routine failure", () => {
    const items = buildBoardAttention({
      approvals: [approval()],
      blockedIssues: [issue()],
      routines: [routine()],
      now,
    });

    expect(items.map((item) => item.kind)).toEqual(["decision", "blocked", "routine"]);
    expect(items[0]?.title).toBe("Approve the production restart");
    expect(items[1]?.description).toContain("no viable owner");
  });

  it("classifies active recovery and scheduled retry issues as recovery work", () => {
    const items = buildBoardAttention({
      approvals: [],
      blockedIssues: [issue({
        activeRecoveryAction: {
          id: "recovery-1",
          companyId: "company-1",
          sourceIssueId: "issue-1",
          recoveryIssueId: null,
          kind: "active_run_watchdog",
          status: "active",
          ownerType: "board",
          ownerAgentId: null,
          ownerUserId: null,
          previousOwnerAgentId: null,
          returnOwnerAgentId: null,
          cause: "timed_out",
          fingerprint: "fingerprint",
          evidence: {},
          nextAction: "Retry the preserved workspace.",
          wakePolicy: null,
          monitorPolicy: null,
          attemptCount: 1,
          maxAttempts: 3,
          timeoutAt: null,
          lastAttemptAt: null,
          outcome: null,
          resolutionNote: null,
          resolvedAt: null,
          createdAt: "2026-07-17T14:00:00.000Z",
          updatedAt: "2026-07-17T14:00:00.000Z",
        },
      })],
      routines: [],
      now,
    });

    expect(items[0]?.kind).toBe("recovery");
    expect(items[0]?.description).toBe("Retry the preserved workspace.");
  });

  it("filters agent-owned dependency work unless the chain is explicitly stalled", () => {
    const healthyAgentOwned = issue({
      id: "healthy-agent-work",
      blockedInboxAttention: {
        ...issue().blockedInboxAttention!,
        state: "missing_disposition",
        reason: "missing_successful_run_disposition",
        owner: { type: "agent", agentId: "agent-1", userId: null, label: "Code Worker" },
        action: { label: "Choose disposition", detail: "The assigned agent owns the next action." },
      },
    });
    const stalledChain = issue({
      id: "stalled-chain",
      blockedInboxAttention: {
        ...issue().blockedInboxAttention!,
        state: "needs_attention",
        reason: "blocked_chain_stalled",
        owner: { type: "unknown", agentId: null, userId: null, label: null },
      },
    });

    expect(requiresBoardAttention(healthyAgentOwned)).toBe(false);
    expect(requiresBoardAttention(stalledChain)).toBe(true);

    const items = buildBoardAttention({
      approvals: [],
      blockedIssues: [healthyAgentOwned, stalledChain],
      routines: [],
      now,
    });

    expect(items.map((item) => item.id)).toEqual(["issue:stalled-chain"]);
  });

  it("keeps Board-owned decisions and agent-owned recovery actions", () => {
    const boardDecision = issue({
      id: "board-decision",
      blockedInboxAttention: {
        ...issue().blockedInboxAttention!,
        state: "awaiting_decision",
        reason: "pending_board_decision",
        owner: { type: "board", agentId: null, userId: null, label: "Board" },
      },
    });
    const recovery = issue({
      id: "agent-recovery",
      activeRecoveryAction: {
        id: "recovery-2",
        companyId: "company-1",
        sourceIssueId: "agent-recovery",
        recoveryIssueId: null,
        kind: "active_run_watchdog",
        status: "active",
        ownerType: "agent",
        ownerAgentId: "agent-1",
        ownerUserId: null,
        previousOwnerAgentId: null,
        returnOwnerAgentId: null,
        cause: "timed_out",
        fingerprint: "recovery-fingerprint",
        evidence: {},
        nextAction: "Retry the preserved workspace.",
        wakePolicy: null,
        monitorPolicy: null,
        attemptCount: 1,
        maxAttempts: 3,
        timeoutAt: null,
        lastAttemptAt: null,
        outcome: null,
        resolutionNote: null,
        resolvedAt: null,
        createdAt: "2026-07-17T14:00:00.000Z",
        updatedAt: "2026-07-17T14:00:00.000Z",
      },
    });

    expect(requiresBoardAttention(boardDecision)).toBe(true);
    expect(requiresBoardAttention(recovery)).toBe(true);

    const items = buildBoardAttention({
      approvals: [],
      blockedIssues: [boardDecision, recovery],
      routines: [],
      now,
    });
    expect(items.map((item) => item.kind)).toEqual(["decision", "recovery"]);
  });
});

describe("dashboard activity filtering", () => {
  it("removes lease churn while preserving operational changes", () => {
    const events = [
      activity("1", "environment.lease_acquired"),
      activity("2", "issue.status_changed"),
      activity("3", "environment.lease_released"),
    ];

    expect(meaningfulBoardActivity(events)).toEqual([events[1]]);
  });
});

describe("countStaleApprovals", () => {
  it("counts only pending approvals older than the threshold", () => {
    expect(countStaleApprovals([
      approval(),
      approval({ id: "recent", createdAt: new Date("2026-07-16T16:00:00.000Z") }),
      approval({ id: "approved", status: "approved" }),
    ], now)).toBe(1);
  });
});

describe("nativeAttentionItems", () => {
  function attention(overrides: Partial<AttentionItem>): AttentionItem {
    return {
      id: "att-1",
      companyId: "company-1",
      sourceKind: "issue_thread_interaction",
      subject: { kind: "interaction", id: "ix-1", companyId: "company-1", title: "Confirm the staging cutover", identifier: null, status: "pending", href: "/issues/PC-9" },
      whyNow: "Code Worker A asked the Board to confirm before deploying.",
      decisionVerbs: [],
      inlineResolvable: true,
      entryRule: "", exitRule: "", dedupKey: "ix-1", dismissalKey: "ix-1", dismissal: null,
      severity: "high",
      rank: 1,
      activityAt: "2026-07-17T15:30:00.000Z",
      createdAt: "2026-07-17T15:30:00.000Z",
      updatedAt: "2026-07-17T15:30:00.000Z",
      relatedIssue: { kind: "issue", id: "issue-9", companyId: "company-1", title: "Ship staging", identifier: "PC-9", status: "in_progress", href: "/issues/PC-9" },
      project: null, workspace: null, expiresAt: null, ruleKey: null, originAgentName: "Code Worker A",
      queues: [], shelf: false, retentionDays: 7, keep: false, archivedAt: null, retentionVersion: 1,
      decideBy: null, decideByAttribution: null, snoozedUntil: null, detail: null, trainingExampleId: null,
      ...overrides,
    } as AttentionItem;
  }

  it("turns a pending thread interaction into a linked Board decision", () => {
    const [item] = nativeAttentionItems([attention({})], now);
    expect(item?.kind).toBe("decision");
    expect(item?.actionLabel).toBe("Decide");
    expect(item?.href).toBe("/issues/PC-9");
    expect(item?.identifier).toBe("PC-9");
    expect(item?.description).toContain("confirm before deploying");
  });

  it("skips approvals, blocked-issue rows and issues already in the queue", () => {
    const items = nativeAttentionItems([
      attention({ id: "a", sourceKind: "approval" }),
      attention({ id: "b", sourceKind: "blocker_attention" }),
      attention({ id: "c", sourceKind: "review", subject: { kind: "issue", id: "issue-1", companyId: "company-1", title: "Reviewed", identifier: "PC-1", status: "in_review", href: "/issues/PC-1" } }),
      attention({ id: "d", sourceKind: "recovery_action" }),
    ], now, new Set(["issue-1"]));
    expect(items.map((item) => item.id)).toEqual(["attention:d"]);
    expect(items[0]?.kind).toBe("recovery");
  });

  it("does not repeat a loaded recovery issue via its native recovery action", () => {
    const rows = nativeAttentionItems([
      attention({ id: "recovery", sourceKind: "recovery_action", subject: { kind: "recovery_action", id: "action-9", companyId: "company-1", title: "Recover issue", identifier: null, status: "pending", href: "/issues/PC-9" } }),
      attention({ id: "interaction" }),
    ], now, new Set(["issue-9"]), new Set(["issue-9"]));
    expect(rows.map((item) => item.id)).toEqual(["attention:interaction"]);
  });

  it("retains an issue-subject thread interaction when its issue is already loaded", () => {
    const subject = { kind: "issue" as const, id: "issue-9", companyId: "company-1", title: "Ship staging", identifier: "PC-9", status: "blocked", href: "/issues/PC-9" };
    const rows = nativeAttentionItems([
      attention({ id: "interaction", sourceKind: "issue_thread_interaction", subject }),
      attention({ id: "review", sourceKind: "review", subject }),
    ], now, new Set(["issue-9"]));
    expect(rows.map((item) => item.id)).toEqual(["attention:interaction"]);
  });

  it("keeps a distinct recovery action when the loaded issue is only blocked", () => {
    const recoveryAction = attention({ sourceKind: "recovery_action", subject: { kind: "recovery_action", id: "action-9", companyId: "company-1", title: "Recover issue", identifier: null, status: "pending", href: "/issues/PC-9" } });
    const related = issue({ id: "issue-9" });
    expect(buildBoardAttention({ approvals: [], blockedIssues: [related], routines: [], attention: [recoveryAction], now }).map((item) => item.id).sort()).toEqual(["attention:att-1", "issue:issue-9"]);
    const recovering = issue({ id: "issue-9", blockedInboxAttention: { ...related.blockedInboxAttention!, state: "recovery_open" } });
    expect(buildBoardAttention({ approvals: [], blockedIssues: [recovering], routines: [], attention: [recoveryAction], now }).map((item) => item.id)).toEqual(["issue:issue-9"]);
  });

  it("merges native rows into the ranked queue", () => {
    const items = buildBoardAttention({ approvals: [], blockedIssues: [], routines: [], attention: [attention({})], now });
    expect(items).toHaveLength(1);
    expect(items[0]?.id).toBe("attention:att-1");
  });
});
