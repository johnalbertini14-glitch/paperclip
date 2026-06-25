import express from "express";
import request from "supertest";
import { beforeEach, describe, expect, it, vi } from "vitest";

// ── Mock factories (hoisted by vitest) ─────────────────────────────────────────

const mockIssueService = vi.hoisted(() => ({
  getById: vi.fn(),
  getByIdentifier: vi.fn(),
  create: vi.fn(),
  update: vi.fn(),
  getRelationSummaries: vi.fn(),
  listUnresolvedBlockerIssueIds: vi.fn(),
  getDependencyReadiness: vi.fn(),
  getCurrentScheduledRetry: vi.fn(),
  addComment: vi.fn(),
  getActiveForIssue: vi.fn(),
  findMentionedAgents: vi.fn(),
  listWakeableBlockedDependents: vi.fn(),
  getWakeableParentAfterChildCompletion: vi.fn(),
  listAttachments: vi.fn(),
  remove: vi.fn(),
  assertCheckoutOwner: vi.fn(),
  createChild: vi.fn(),
  list: vi.fn(),
}));

const mockAccessService = vi.hoisted(() => ({
  decide: vi.fn(),
  canUser: vi.fn(async () => false),
  hasPermission: vi.fn(async () => false),
}));

const mockHeartbeatService = vi.hoisted(() => ({
  getRun: vi.fn(),
  wakeup: vi.fn(async () => undefined),
  reportRunActivity: vi.fn(async () => undefined),
  getActiveRunForAgent: vi.fn(async () => null),
  cancelRun: vi.fn(async () => null),
}));

const mockRecoveryActionsService = vi.hoisted(() => ({
  getActiveForIssue: vi.fn().mockResolvedValue(null),
  assertAuthority: vi.fn(),
}));

const mockIssueReferencesService = vi.hoisted(() => ({
  listIssueReferenceSummary: vi.fn().mockResolvedValue({ outbound: [], inbound: [] }),
}));

const mockIssueThreadInteractionService = vi.hoisted(() => ({
  listForIssue: vi.fn().mockResolvedValue([]),
  expireRequestConfirmationsSupersededByComment: vi.fn(async () => []),
  expireStaleRequestConfirmationsForIssueDocument: vi.fn(async () => []),
}));

const mockIssueApprovalService = vi.hoisted(() => ({
  listApprovalsForIssue: vi.fn().mockResolvedValue([]),
}));

const mockCompanyService = vi.hoisted(() => ({
  getById: vi.fn(),
}));

const mockFeedbackService = vi.hoisted(() => ({
  flushPendingFeedbackTraces: vi.fn(),
  listIssueVotesForUser: vi.fn(async () => []),
  saveIssueVote: vi.fn(async () => ({ vote: null, consentEnabledNow: false, sharingEnabledNow: false })),
}));

const mockProjectService = vi.hoisted(() => ({}));

const mockGoalService = vi.hoisted(() => ({}));

const mockWorkProductService = vi.hoisted(() => ({}));

const mockDocumentService = vi.hoisted(() => ({
  syncIssue: async () => undefined,
  syncComment: async () => undefined,
  syncDocument: async () => undefined,
}));

const mockDocumentAnnotationService = vi.hoisted(() => ({}));

const mockEnvironmentService = vi.hoisted(() => ({}));

const mockRoutineService = vi.hoisted(() => ({
  syncRunStatusForIssue: vi.fn(async () => undefined),
}));

const mockActivityService = vi.hoisted(() => ({
  log: vi.fn(async () => undefined),
}));

const mockApprovalService = vi.hoisted(() => ({}));

const mockBudgetService = vi.hoisted(() => ({}));

const mockSecretService = vi.hoisted(() => ({}));

const mockCostService = vi.hoisted(() => ({}));

const mockFinanceService = vi.hoisted(() => ({}));

const mockInstanceSettingsService = vi.hoisted(() => ({
  get: vi.fn(async () => ({
    id: "instance-settings-1",
    general: { censorUsernameInLogs: false, feedbackDataSharingPreference: "prompt" },
  })),
  listCompanyIds: vi.fn(async () => ["company-1"]),
}));

const mockCompanySearchService = vi.hoisted(() => ({}));

const mockAgentService = vi.hoisted(() => ({
  getById: vi.fn(async () => ({ id: "agent-1", companyId: "company-1", role: "engineer" })),
}));

const mockLogActivity = vi.hoisted(() => vi.fn(async () => undefined));

// ── Module mock registration (called in beforeEach) ────────────────────────────

function registerModuleMocks() {
  vi.doMock("@paperclipai/shared/telemetry", () => ({
    trackAgentTaskCompleted: vi.fn(),
    trackErrorHandlerCrash: vi.fn(),
  }));

  vi.doMock("../telemetry.js", () => ({
    getTelemetryClient: vi.fn(() => ({ track: vi.fn() })),
  }));

  vi.doMock("../services/access.js", () => ({
    accessService: () => mockAccessService,
  }));

  vi.doMock("../services/heartbeat.js", () => ({
    heartbeatService: () => mockHeartbeatService,
  }));

  vi.doMock("../services/recovery-actions.js", () => ({
    recoveryActionsService: () => mockRecoveryActionsService,
  }));

  vi.doMock("../services/issue-references.js", () => ({
    issueReferenceService: () => mockIssueReferencesService,
    issueReferencesService: () => mockIssueReferencesService,
  }));

  vi.doMock("../services/issue-thread-interactions.js", () => ({
    issueThreadInteractionService: () => mockIssueThreadInteractionService,
  }));

  vi.doMock("../services/issue-approvals.js", () => ({
    issueApprovalService: () => mockIssueApprovalService,
  }));

  vi.doMock("../services/companies.js", () => ({
    companyService: () => mockCompanyService,
  }));

  vi.doMock("../services/feedback.js", () => ({
    feedbackService: () => mockFeedbackService,
  }));

  vi.doMock("../services/projects.js", () => ({
    projectService: () => mockProjectService,
  }));

  vi.doMock("../services/goals.js", () => ({
    goalService: () => mockGoalService,
  }));

  vi.doMock("../services/work-products.js", () => ({
    workProductService: () => mockWorkProductService,
  }));

  vi.doMock("../services/documents.js", () => ({
    documentService: () => mockDocumentService,
  }));

  vi.doMock("../services/document-annotations.js", () => ({
    documentAnnotationService: () => mockDocumentAnnotationService,
  }));

  vi.doMock("../services/environments.js", () => ({
    environmentService: () => mockEnvironmentService,
  }));

  vi.doMock("../services/routines.js", () => ({
    routineService: () => mockRoutineService,
  }));

  vi.doMock("../services/activity-log.js", () => ({
    logActivity: mockLogActivity,
  }));

  vi.doMock("../services/approvals.js", () => ({
    approvalService: () => mockApprovalService,
  }));

  vi.doMock("../services/budgets.js", () => ({
    budgetService: () => mockBudgetService,
  }));

  vi.doMock("../services/secrets.js", () => ({
    secretService: () => mockSecretService,
  }));

  vi.doMock("../services/costs.js", () => ({
    costService: () => mockCostService,
  }));

  vi.doMock("../services/finance.js", () => ({
    financeService: () => mockFinanceService,
  }));

  vi.doMock("../services/instance-settings.js", () => ({
    instanceSettingsService: () => mockInstanceSettingsService,
  }));

  vi.doMock("../services/company-search.js", () => ({
    companySearchService: () => mockCompanySearchService,
  }));

  vi.doMock("../services/agents.js", () => ({
    agentService: () => mockAgentService,
  }));

  vi.doMock("../services/index.js", () => ({
    companyService: () => mockCompanyService,
    accessService: () => mockAccessService,
    agentService: () => mockAgentService,
    documentAnnotationService: () => mockDocumentAnnotationService,
    documentService: () => mockDocumentService,
    executionWorkspaceService: () => ({}),
    feedbackService: () => mockFeedbackService,
    goalService: () => mockGoalService,
    heartbeatService: () => mockHeartbeatService,
    instanceSettingsService: () => mockInstanceSettingsService,
    issueApprovalService: () => mockIssueApprovalService,
    issueRecoveryActionService: () => mockRecoveryActionsService,
    issueReferenceService: () => mockIssueReferencesService,
    issueService: () => mockIssueService,
    issueThreadInteractionService: () => mockIssueThreadInteractionService,
    logActivity: mockLogActivity,
    projectService: () => mockProjectService,
    routineService: () => mockRoutineService,
    workProductService: () => mockWorkProductService,
    budgetService: () => mockBudgetService,
    secretService: () => mockSecretService,
    costService: () => mockCostService,
    financeService: () => mockFinanceService,
    companySearchService: () => mockCompanySearchService,
  }));

  vi.doMock("../services/issues.js", () => ({
    issueService: () => mockIssueService,
  }));
}

// ── App factory ───────────────────────────────────────────────────────────────

function createMockDb() {
  // Build a chainable mock query builder that is thenable (await-able).
  // Each method returns `queryBuilder` so chains like
  //   db.select().from().where().orderBy().limit()
  // keep working.  Calling .then on the object resolves to `resolvedRows`.
  let lastError: unknown = null;
  function makeQueryBuilder(resolvedRows: unknown[] = []) {
    const qb: Record<string, unknown> = {};
    const methods = [
      "select", "from", "where", "innerJoin", "leftJoin", "rightJoin",
      "orderBy", "limit", "offset", "update", "set", "into",
    ];
    for (const m of methods) {
      qb[m] = vi.fn(() => {
        if (lastError) throw lastError;
        return qb as any;
      });
    }
    // Make the object await-able: give it a valid .then
    (qb as unknown as Promise<unknown[]>).then = (
      onFulfilled: (v: unknown[]) => unknown,
      onRejected?: (e: unknown) => unknown,
    ): Promise<unknown> => {
      if (lastError && onRejected) return Promise.reject(lastError).then(onRejected, onRejected) as Promise<unknown>;
      return Promise.resolve(onFulfilled(resolvedRows)) as Promise<unknown>;
    };
    return qb as any;
  }

  async function mockTransaction<T>(fn: (tx: unknown) => Promise<T>): Promise<T> {
    try {
      return await fn(makeQueryBuilder([]));
    } catch (e) {
      lastError = e;
      throw e;
    }
  }

  return {
    transaction: mockTransaction,
    select: vi.fn(() => makeQueryBuilder([])),
    from: vi.fn(() => makeQueryBuilder([])),
    _setError: (e: unknown) => { lastError = e; },
  };
}

function createApp() {
  const app = express();
  app.use(express.json());
  return app;
}

// Debugging wrapper: use this instead of installActor when debugging
async function installActorDebug(app: express.Express, actor: Record<string, unknown>) {
  const [{ issueRoutes }, { errorHandler }] = await Promise.all([
    import("../routes/issues.js"),
    import("../middleware/index.js"),
  ]);

  app.use((req, _res, next) => {
    (req as any).actor = actor;
    next();
  });

  // Wrap route in try-catch to surface hidden errors
  app.use("/api", (req, res, next) => {
    const originalJson = res.json.bind(res);
    (res as any).json = (body: unknown) => {
      if (res.statusCode >= 400 && res.statusCode < 600) {
        console.log("[DEBUG] Error response:", res.statusCode, JSON.stringify(body));
        console.log("[DEBUG] Stack:", new Error().stack?.split("\n").slice(1, 5).join("\n"));
      }
      return originalJson(body);
    };
    next();
  });
  app.use("/api", issueRoutes(createMockDb() as any, {} as any));
  app.use(errorHandler);
  return app;
}

async function installActor(app: express.Express, actor: Record<string, unknown>) {
  const [{ issueRoutes }, { errorHandler }] = await Promise.all([
    import("../routes/issues.js"),
    import("../middleware/index.js"),
  ]);

  app.use((req, _res, next) => {
    (req as any).actor = actor;
    next();
  });
  app.use("/api", issueRoutes(createMockDb() as any, {} as any));
  app.use(errorHandler);
  return app;
}

// ── Fixtures ──────────────────────────────────────────────────────────────────

function makeIssue(overrides: Record<string, unknown> = {}) {
  return {
    id: "issue-1",
    companyId: "company-1",
    identifier: "TEST-1",
    title: "Test Issue",
    description: null,
    status: "in_progress",
    priority: "medium",
    assigneeAgentId: "agent-1",
    assigneeUserId: null,
    parentId: null,
    projectId: null,
    createdByUserId: "board-user-1",
    createdAt: new Date(),
    updatedAt: new Date(),
    blockedBy: [],
    blockedByIssueIds: [],
    checkoutRunId: null,
    executionRunId: null,
    executionPolicy: null,
    executionState: null,
    monitorNextCheckAt: null,
    ...overrides,
  };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe.sequential("False-Blocker Gate + Stale-Review Guard — route-level", () => {
  beforeEach(() => {
    vi.resetModules();
    vi.doUnmock("@paperclipai/shared/telemetry");
    vi.doUnmock("../telemetry.js");
    vi.doUnmock("../services/access.js");
    vi.doUnmock("../services/activity-log.js");
    vi.doUnmock("../services/feedback.js");
    vi.doUnmock("../services/heartbeat.js");
    vi.doUnmock("../services/instance-settings.js");
    vi.doUnmock("../services/index.js");
    vi.doUnmock("../services/issues.js");
    vi.doUnmock("../services/recovery-actions.js");
    vi.doUnmock("../services/issue-references.js");
    vi.doUnmock("../services/issue-thread-interactions.js");
    vi.doUnmock("../services/issue-approvals.js");
    vi.doUnmock("../services/companies.js");
    vi.doUnmock("../services/projects.js");
    vi.doUnmock("../services/goals.js");
    vi.doUnmock("../services/work-products.js");
    vi.doUnmock("../services/documents.js");
    vi.doUnmock("../services/document-annotations.js");
    vi.doUnmock("../services/environments.js");
    vi.doUnmock("../services/routines.js");
    vi.doUnmock("../services/approvals.js");
    vi.doUnmock("../services/budgets.js");
    vi.doUnmock("../services/secrets.js");
    vi.doUnmock("../services/costs.js");
    vi.doUnmock("../services/finance.js");
    vi.doUnmock("../services/company-search.js");
    vi.doUnmock("../services/agents.js");
    vi.doUnmock("../routes/issues.js");
    vi.doUnmock("../routes/authz.js");
    vi.doUnmock("../middleware/index.js");
    registerModuleMocks();
    vi.clearAllMocks();

    // Default per-test stubs
    mockIssueService.getRelationSummaries.mockResolvedValue({ blockedBy: [], blocks: [] });
    mockIssueService.listWakeableBlockedDependents.mockResolvedValue([]);
    mockIssueService.getWakeableParentAfterChildCompletion.mockResolvedValue(null);
    mockIssueService.findMentionedAgents.mockResolvedValue([]);
    mockIssueService.listAttachments.mockResolvedValue([]);
    mockIssueService.assertCheckoutOwner.mockResolvedValue({ adoptedFromRunId: null });
    mockIssueService.addComment.mockResolvedValue({ id: "comment-1", issueId: "issue-1", body: "ok" });
    mockInstanceSettingsService.get.mockResolvedValue({
      id: "instance-settings-1",
      general: { censorUsernameInLogs: false, feedbackDataSharingPreference: "prompt" },
    });
    mockInstanceSettingsService.listCompanyIds.mockResolvedValue(["company-1"]);
    mockActivityService.log.mockResolvedValue(undefined);
    mockHeartbeatService.getRun.mockResolvedValue(null);
    mockHeartbeatService.getActiveRunForAgent.mockResolvedValue(null);

    // Route middleware mocks — must allow agent to mutate own issue
    mockAccessService.decide.mockImplementation(async (input: { action: string }) => ({
      allowed:
        input.action === "tasks:assign" ||
        input.action === "issue:read" ||
        input.action === "issue:mutate" ||
        input.action === "tasks:manage_active_checkouts" ||
        input.action === "company_scope:read",
      reason:
        input.action === "tasks:assign" ||
          input.action === "issue:read" ||
          input.action === "issue:mutate" ||
          input.action === "tasks:manage_active_checkouts" ||
          input.action === "company_scope:read"
          ? "allow_explicit_grant"
          : "deny_missing_grant",
    }));
    mockAccessService.canUser.mockResolvedValue(true);
    mockAccessService.hasPermission.mockResolvedValue(false);
  });

  // ── Guard 1: False-Blocker Pre-Flight Gate ─────────────────────────────────

  describe("Guard 1 — false-blocker route gate", () => {
    it("PATCH /issues/:id rejects blocked transition with empty blockers for agent", async () => {
      const existing = makeIssue({ status: "in_progress" });
      mockIssueService.getById.mockResolvedValue(existing);
      mockIssueService.listUnresolvedBlockerIssueIds.mockResolvedValue([]);
      mockIssueService.update.mockImplementation(async (_id: string, _patch: Record<string, unknown>) => ({ ...existing, status: "blocked" }));

      const app = await installActor(createApp(), {
        type: "agent",
        agentId: "agent-1",
        userId: null,
        runId: "run-1",
        companyId: "company-1",
        companyIds: ["company-1"],
        isInstanceAdmin: false,
      });

      const res = await request(app)
        .patch("/api/issues/issue-1")
        .send({ status: "blocked", blockedByIssueIds: [] });

      expect(res.status).toBe(422);
      expect(res.body.error).toMatch(/blocked requires blockedByIssueIds/);
    });

    it("PATCH /issues/:id rejects blocked transition when all blockers are already resolved", async () => {
      const existing = makeIssue({ status: "in_progress" });
      mockIssueService.getById.mockResolvedValue(existing);
      mockIssueService.listUnresolvedBlockerIssueIds.mockResolvedValue([]);

      const app = await installActor(createApp(), {
        type: "agent",
        agentId: "agent-1",
        userId: null,
        runId: "run-1",
        companyId: "company-1",
        companyIds: ["company-1"],
        isInstanceAdmin: false,
      });

      const res = await request(app)
        .patch("/api/issues/issue-1")
        .send({ status: "blocked", blockedByIssueIds: [] });

      expect(res.status).toBe(422);
      expect(res.body.error).toMatch(/blocked requires blockedByIssueIds/);
    });

    it("PATCH /issues/:id rejects blocked transition when all blockers are already resolved", async () => {
      const existing = makeIssue({ status: "in_progress" });
      mockIssueService.getById.mockResolvedValue(existing);
      mockIssueService.listUnresolvedBlockerIssueIds.mockResolvedValue([]);

      const app = await installActor(createApp(), {
        type: "agent",
        agentId: "agent-1",
        userId: null,
        runId: "run-1",
        companyId: "company-1",
        companyIds: ["company-1"],
        isInstanceAdmin: false,
      });

      const res = await request(app)
        .patch("/api/issues/issue-1")
        .send({ status: "blocked", blockedByIssueIds: ["bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"] });

      console.log("Guard1 B resolved body:", JSON.stringify(res.body));
      expect(res.status).toBe(422);
      expect(res.body.error).toMatch(/all listed blockers are already resolved|Cannot block/);
    });

    it("PATCH /issues/:id allows blocked transition when at least one blocker is unresolved", async () => {
      const existing = makeIssue({ status: "in_progress" });
      const updatedIssue = { ...existing, status: "blocked" };
      mockIssueService.getById.mockResolvedValue(existing);
      mockIssueService.listUnresolvedBlockerIssueIds.mockResolvedValue(["bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"]);
      mockIssueService.update.mockImplementation(async (_id: string, _patch: Record<string, unknown>) => updatedIssue);

      const app = await installActor(createApp(), {
        type: "agent",
        agentId: "agent-1",
        userId: null,
        runId: "run-1",
        companyId: "company-1",
        companyIds: ["company-1"],
        isInstanceAdmin: false,
      });

      const res = await request(app)
        .patch("/api/issues/issue-1")
        .send({ status: "blocked", blockedByIssueIds: ["bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"] });

      console.log("Guard1 C unresolved body:", JSON.stringify(res.body));
      expect(res.status).toBe(200);
      expect(mockIssueService.update).toHaveBeenCalled();
    });

    it("PATCH /issues/:id allows agent to re-block an already-blocked issue", async () => {
      const existing = makeIssue({ status: "blocked" });
      const updatedIssue = { ...existing, status: "blocked" };
      mockIssueService.getById.mockResolvedValue(existing);
      mockIssueService.update.mockImplementation(async (_id: string, _patch: Record<string, unknown>) => updatedIssue);

      const app = await installActor(createApp(), {
        type: "agent",
        agentId: "agent-1",
        userId: null,
        runId: "run-1",
        companyId: "company-1",
        companyIds: ["company-1"],
        isInstanceAdmin: false,
      });

      const res = await request(app)
        .patch("/api/issues/issue-1")
        .send({ status: "blocked", blockedByIssueIds: ["bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"] });

      console.log("Guard1 D reblock body:", JSON.stringify(res.body));
      expect(res.status).toBe(200);
    });

    it("PATCH /issues/:id allows board user to set blocked with empty blockers", async () => {
      const existing = makeIssue({ status: "in_progress" });
      const updatedIssue = { ...existing, status: "blocked" };
      mockIssueService.getById.mockResolvedValue(existing);
      mockIssueService.update.mockImplementation(async (_id: string, _patch: Record<string, unknown>) => updatedIssue);

      const app = await installActor(createApp(), {
        type: "board",
        agentId: null,
        userId: "board-user-1",
        runId: null,
        companyIds: ["company-1"],
        isInstanceAdmin: false,
      });

      const res = await request(app)
        .patch("/api/issues/issue-1")
        .send({ status: "blocked", blockedByIssueIds: [] });

      expect(res.status).toBe(200);
    });
  });

  // ── Guard 2: Stale-Review Guard ─────────────────────────────────────────────

  describe("Guard 2 — stale-review route gate", () => {
    it("PATCH /issues/:id rejects in_review transition when no valid review path exists", async () => {
      const existing = makeIssue({
        status: "in_progress",
        assigneeAgentId: "agent-1",
        assigneeUserId: null,
        executionState: null,
        monitorNextCheckAt: null,
      });
      mockIssueService.getById.mockResolvedValue(existing);
      mockIssueThreadInteractionService.listForIssue.mockResolvedValue([]);
      mockIssueApprovalService.listApprovalsForIssue.mockResolvedValue([]);

      const app = await installActor(createApp(), {
        type: "agent",
        agentId: "agent-1",
        userId: null,
        runId: "run-1",
        companyId: "company-1",
        companyIds: ["company-1"],
        isInstanceAdmin: false,
      });

      const res = await request(app)
        .patch("/api/issues/issue-1")
        .send({ status: "in_review" });

      expect(res.status).toBe(422);
      expect(res.body.details?.missing).toBe("review_path");
    });

    it("PATCH /issues/:id allows in_review when a pending wake_assignee interaction exists", async () => {
      const existing = makeIssue({
        status: "in_progress",
        assigneeAgentId: "agent-1",
        assigneeUserId: null,
        executionState: null,
        monitorNextCheckAt: null,
      });
      mockIssueService.getById.mockResolvedValue(existing);
      mockIssueThreadInteractionService.listForIssue.mockResolvedValue([
        {
          id: "interaction-1",
          status: "pending",
          continuationPolicy: "wake_assignee",
          kind: "request_confirmation",
        },
      ]);
      mockIssueApprovalService.listApprovalsForIssue.mockResolvedValue([]);
      mockIssueService.update.mockImplementation(
        async (_id: string, _patch: Record<string, unknown>) => ({ ...existing, status: "in_review" }),
      );

      const app = await installActor(createApp(), {
        type: "agent",
        agentId: "agent-1",
        userId: null,
        runId: "run-1",
        companyId: "company-1",
        companyIds: ["company-1"],
        isInstanceAdmin: false,
      });

      const res = await request(app)
        .patch("/api/issues/issue-1")
        .send({ status: "in_review" });

      expect(res.status).toBe(200);
    });

    it("PATCH /issues/:id allows in_review when a pending wake_assignee_on_accept interaction exists", async () => {
      const existing = makeIssue({
        status: "in_progress",
        assigneeAgentId: "agent-1",
        assigneeUserId: null,
        executionState: null,
        monitorNextCheckAt: null,
      });
      mockIssueService.getById.mockResolvedValue(existing);
      mockIssueThreadInteractionService.listForIssue.mockResolvedValue([
        {
          id: "interaction-2",
          status: "pending",
          continuationPolicy: "wake_assignee_on_accept",
          kind: "request_confirmation",
        },
      ]);
      mockIssueApprovalService.listApprovalsForIssue.mockResolvedValue([]);
      mockIssueService.update.mockImplementation(
        async (_id: string, _patch: Record<string, unknown>) => ({ ...existing, status: "in_review" }),
      );

      const app = await installActor(createApp(), {
        type: "agent",
        agentId: "agent-1",
        userId: null,
        runId: "run-1",
        companyId: "company-1",
        companyIds: ["company-1"],
        isInstanceAdmin: false,
      });

      const res = await request(app)
        .patch("/api/issues/issue-1")
        .send({ status: "in_review" });

      expect(res.status).toBe(200);
    });

    it("PATCH /issues/:id rejects in_review when only continuationPolicy=none interaction exists", async () => {
      const existing = makeIssue({
        status: "in_progress",
        assigneeAgentId: "agent-1",
        assigneeUserId: null,
        executionState: null,
        monitorNextCheckAt: null,
      });
      mockIssueService.getById.mockResolvedValue(existing);
      mockIssueThreadInteractionService.listForIssue.mockResolvedValue([
        {
          id: "interaction-3",
          status: "pending",
          continuationPolicy: "none",
          kind: "request_confirmation",
        },
      ]);
      mockIssueApprovalService.listApprovalsForIssue.mockResolvedValue([]);

      const app = await installActor(createApp(), {
        type: "agent",
        agentId: "agent-1",
        userId: null,
        runId: "run-1",
        companyId: "company-1",
        companyIds: ["company-1"],
        isInstanceAdmin: false,
      });

      const res = await request(app)
        .patch("/api/issues/issue-1")
        .send({ status: "in_review" });

      expect(res.status).toBe(422);
      expect(res.body.details?.missing).toBe("review_path");
    });

    it("PATCH /issues/:id allows in_review when human assigneeUserId is set", async () => {
      const existing = makeIssue({
        status: "in_progress",
        assigneeAgentId: "agent-1",
        assigneeUserId: null,
        executionState: null,
        monitorNextCheckAt: null,
      });
      mockIssueService.getById.mockResolvedValue(existing);
      mockIssueService.update.mockImplementation(
        async (_id: string, _patch: Record<string, unknown>) => ({
          ...existing,
          status: "in_review",
          assigneeUserId: "human-reviewer",
        }),
      );

      const app = await installActor(createApp(), {
        type: "agent",
        agentId: "agent-1",
        userId: null,
        runId: "run-1",
        companyId: "company-1",
        companyIds: ["company-1"],
        isInstanceAdmin: false,
      });

      const res = await request(app)
        .patch("/api/issues/issue-1")
        .send({ status: "in_review", assigneeUserId: "human-reviewer" });

      expect(res.status).toBe(200);
    });

    it("PATCH /issues/:id allows board user to transition to in_review without interaction", async () => {
      const existing = makeIssue({
        status: "in_progress",
        assigneeAgentId: null,
        assigneeUserId: null,
        executionState: null,
        monitorNextCheckAt: null,
      });
      mockIssueService.getById.mockResolvedValue(existing);
      mockIssueService.update.mockImplementation(
        async (_id: string, _patch: Record<string, unknown>) => ({ ...existing, status: "in_review" }),
      );

      const app = await installActor(createApp(), {
        type: "board",
        agentId: null,
        userId: "board-user-1",
        runId: null,
        companyIds: ["company-1"],
        isInstanceAdmin: false,
      });

      const res = await request(app)
        .patch("/api/issues/issue-1")
        .send({ status: "in_review" });

      expect(res.status).toBe(200);
    });
  });
});
