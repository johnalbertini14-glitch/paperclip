import { randomUUID } from "node:crypto";
import { and, eq } from "drizzle-orm";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import {
  agents,
  companies,
  createDb,
  executionWorkspaces,
  heartbeatRuns,
  issues,
  projects,
  workspaceOperations,
} from "@paperclipai/db";
import { getEmbeddedPostgresTestSupport, startEmbeddedPostgresTestDatabase } from "./helpers/embedded-postgres.js";
import { workspaceOperationService } from "../services/workspace-operations.js";

const embeddedPostgresSupport = await getEmbeddedPostgresTestSupport();
const describeEmbeddedPostgres = embeddedPostgresSupport.supported ? describe : describe.skip;

if (!embeddedPostgresSupport.supported) {
  console.warn(
    `Skipping workspace operations tests on this host: ${embeddedPostgresSupport.reason ?? "unsupported environment"}`,
  );
}

type Db = ReturnType<typeof createDb>;

// Conditional suite — must come before any hooks so all hooks are skipped atomically when unsupported.
const suite = embeddedPostgresSupport.supported ? describe : describe.skip;

suite("workspaceOperations issue reference guard", () => {
  let db!: Db;
  let tempDb: Awaited<ReturnType<typeof startEmbeddedPostgresTestDatabase>> | null = null;

  beforeAll(async () => {
    tempDb = await startEmbeddedPostgresTestDatabase("paperclip-wsops-guard-");
    db = createDb(tempDb.connectionString);
  }, 20_000);

  afterEach(async () => {
    await db.delete(workspaceOperations);
    await db.delete(heartbeatRuns);
    await db.delete(issues);
    await db.delete(executionWorkspaces);
    await db.delete(projects);
    await db.delete(agents);
    await db.delete(companies);
  });

  afterAll(async () => {
    await db.$client.end();
    await tempDb?.cleanup();
  });

  // Shared seed: two companies, each with one agent and one project.
  async function seedTwoCompanyScenario() {
    const companyA = randomUUID();
    const companyB = randomUUID();
    const agentA = randomUUID();
    const agentB = randomUUID();
    const projectA = randomUUID();
    const projectB = randomUUID();
    const issueA = randomUUID(); // belongs to companyA
    const issueB = randomUUID(); // belongs to companyB

    await db.insert(companies).values([
      { id: companyA, name: "CompanyA", status: "active", createdAt: new Date(), updatedAt: new Date() },
      { id: companyB, name: "CompanyB", status: "active", createdAt: new Date(), updatedAt: new Date() },
    ]);
    await db.insert(projects).values([
      { id: projectA, companyId: companyA, name: "ProjectA", status: "active", createdAt: new Date(), updatedAt: new Date() },
      { id: projectB, companyId: companyB, name: "ProjectB", status: "active", createdAt: new Date(), updatedAt: new Date() },
    ]);
    await db.insert(agents).values([
      { id: agentA, companyId: companyA, name: "AgentA", role: "engineer", status: "idle", adapterType: "codex_local", adapterConfig: {}, runtimeConfig: {}, permissions: {}, createdAt: new Date(), updatedAt: new Date() },
      { id: agentB, companyId: companyB, name: "AgentB", role: "engineer", status: "idle", adapterType: "codex_local", adapterConfig: {}, runtimeConfig: {}, permissions: {}, createdAt: new Date(), updatedAt: new Date() },
    ]);
    await db.insert(issues).values([
      { id: issueA, companyId: companyA, projectId: projectA, title: "IssueA", status: "in_progress", workMode: "standard", priority: "medium", createdAt: new Date(), updatedAt: new Date() },
      { id: issueB, companyId: companyB, projectId: projectB, title: "IssueB", status: "in_progress", workMode: "standard", priority: "medium", createdAt: new Date(), updatedAt: new Date() },
    ]);

    return { companyA, companyB, agentA, agentB, issueA, issueB };
  }

  it("rejects nonexistent issue UUID with structured error and zero rows", async () => {
    const companyId = randomUUID();
    await db.insert(companies).values({ id: companyId, name: "TestCo", status: "active", createdAt: new Date(), updatedAt: new Date() });

    const svc = workspaceOperationService(db);
    const recorder = svc.createRecorder({ companyId, issueId: randomUUID() }); // real UUID but no such issue

    const runPromise = recorder.recordOperation({
      phase: "worktree_prepare",
      run: async () => ({ status: "succeeded" }),
    });

    await expect(runPromise).rejects.toMatchObject({
      message: "Issue reference is invalid",
      details: { code: "workspace_operation_invalid_issue_reference" },
    });

    const rows = await db.select().from(workspaceOperations).where(eq(workspaceOperations.companyId, companyId));
    expect(rows).toHaveLength(0);
  });

  it("rejects cross-company issue UUID with structured error and zero rows", async () => {
    const { companyA, companyB, issueA } = await seedTwoCompanyScenario();
    // issueA belongs to companyA; try to use it under companyB's scope
    const svc = workspaceOperationService(db);
    const recorder = svc.createRecorder({ companyId: companyB, issueId: issueA });

    const runPromise = recorder.recordOperation({
      phase: "worktree_prepare",
      run: async () => ({ status: "succeeded" }),
    });

    await expect(runPromise).rejects.toMatchObject({
      message: "Issue reference is invalid",
      details: { code: "workspace_operation_invalid_issue_reference" },
    });

    const rows = await db.select().from(workspaceOperations).where(eq(workspaceOperations.companyId, companyB));
    expect(rows).toHaveLength(0);
  });

  it("rejects deleted issue UUID with structured error and zero rows", async () => {
    const companyId = randomUUID();
    const projectId = randomUUID();
    const issueId = randomUUID();

    await db.insert(companies).values({ id: companyId, name: "TestCo", status: "active", createdAt: new Date(), updatedAt: new Date() });
    await db.insert(projects).values({ id: projectId, companyId, name: "Project", status: "active", createdAt: new Date(), updatedAt: new Date() });
    await db.insert(issues).values({ id: issueId, companyId, projectId, title: "Issue", status: "in_progress", workMode: "standard", priority: "medium", createdAt: new Date(), updatedAt: new Date() });

    const svc = workspaceOperationService(db);
    const recorder = svc.createRecorder({ companyId, issueId });

    // Delete the issue between recorder creation and recordOperation call
    await db.delete(issues).where(eq(issues.id, issueId));

    const runPromise = recorder.recordOperation({
      phase: "worktree_prepare",
      run: async () => ({ status: "succeeded" }),
    });

    await expect(runPromise).rejects.toMatchObject({
      message: "Issue reference is invalid",
      details: { code: "workspace_operation_invalid_issue_reference" },
    });

    const rows = await db.select().from(workspaceOperations).where(eq(workspaceOperations.companyId, companyId));
    expect(rows).toHaveLength(0);
  });

  it("accepts valid same-company issue UUID and creates the operation row", async () => {
    const companyId = randomUUID();
    const projectId = randomUUID();
    const issueId = randomUUID();

    await db.insert(companies).values({ id: companyId, name: "TestCo", status: "active", createdAt: new Date(), updatedAt: new Date() });
    await db.insert(projects).values({ id: projectId, companyId, name: "Project", status: "active", createdAt: new Date(), updatedAt: new Date() });
    await db.insert(issues).values({ id: issueId, companyId, projectId, title: "Issue", status: "in_progress", workMode: "standard", priority: "medium", createdAt: new Date(), updatedAt: new Date() });

    const svc = workspaceOperationService(db);
    const recorder = svc.createRecorder({ companyId, issueId });

    const result = await recorder.recordOperation({
      phase: "worktree_prepare",
      command: "git checkout main",
      run: async () => ({ status: "succeeded", exitCode: 0 }),
    });

    expect(result).toMatchObject({
      issueId,
      companyId,
      phase: "worktree_prepare",
      command: "git checkout main",
      status: "succeeded",
    });

    const rows = await db.select().from(workspaceOperations).where(
      and(eq(workspaceOperations.companyId, companyId), eq(workspaceOperations.issueId, issueId)),
    );
    expect(rows).toHaveLength(1);
    expect(rows[0]?.id).toBe(result.id);
  });

  it("accepts explicit null issueId and creates the operation row", async () => {
    const companyId = randomUUID();
    await db.insert(companies).values({ id: companyId, name: "TestCo", status: "active", createdAt: new Date(), updatedAt: new Date() });

    const svc = workspaceOperationService(db);
    const recorder = svc.createRecorder({ companyId, issueId: null });

    const result = await recorder.recordOperation({
      phase: "worktree_prepare",
      run: async () => ({ status: "succeeded" }),
    });

    expect(result).toMatchObject({
      issueId: null,
      companyId,
      phase: "worktree_prepare",
      status: "succeeded",
    });

    const rows = await db.select().from(workspaceOperations).where(eq(workspaceOperations.companyId, companyId));
    expect(rows).toHaveLength(1);
    expect(rows[0]?.id).toBe(result.id);
  });

  it("accepts omitted issueId (undefined) without regressing to invalid lookup", async () => {
    // Regression: the prior implementation used `input.issueId !== null` which treated
    // omitted/undefined as a non-null value and entered the issue lookup path.
    // Normal callers (execution-workspaces.ts, projects.ts) omit the field entirely.
    const companyId = randomUUID();
    await db.insert(companies).values({ id: companyId, name: "TestCo", status: "active", createdAt: new Date(), updatedAt: new Date() });

    const svc = workspaceOperationService(db);
    // No issueId field at all — not even null
    const recorder = svc.createRecorder({ companyId });

    const result = await recorder.recordOperation({
      phase: "worktree_prepare",
      run: async () => ({ status: "succeeded" }),
    });

    expect(result).toMatchObject({
      issueId: null,
      companyId,
      phase: "worktree_prepare",
      status: "succeeded",
    });

    const rows = await db.select().from(workspaceOperations).where(eq(workspaceOperations.companyId, companyId));
    expect(rows).toHaveLength(1);
    expect(rows[0]?.id).toBe(result.id);
  });

  it("does not call the operation callback when issue reference is invalid", async () => {
    const companyId = randomUUID();
    await db.insert(companies).values({ id: companyId, name: "TestCo", status: "active", createdAt: new Date(), updatedAt: new Date() });

    const svc = workspaceOperationService(db);
    const recorder = svc.createRecorder({ companyId, issueId: randomUUID() });

    const runCallback = vi.fn(async () => ({ status: "succeeded" as const }));

    try {
      await recorder.recordOperation({ phase: "worktree_prepare", run: runCallback });
    } catch {
      // expected to throw
    }

    expect(runCallback).not.toHaveBeenCalled();
  });
});
