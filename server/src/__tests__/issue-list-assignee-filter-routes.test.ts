import { randomUUID } from "node:crypto";
import express from "express";
import request from "supertest";
import { eq } from "drizzle-orm";
import { PgDialect } from "drizzle-orm/pg-core";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { activityLog, agents, companies, companyMemberships, createDb, executionWorkspaces, externalObjects, externalObjectMentions, heartbeatRuns, issueLabels, labels, issueRelations, issueThreadInteractions, issues, principalPermissionGrants, projects, projectWorkspaces } from "@paperclipai/db";
import {
  getEmbeddedPostgresTestSupport,
  startEmbeddedPostgresTestDatabase,
} from "./helpers/embedded-postgres.js";
import { errorHandler } from "../middleware/index.js";
import {
  __clearIssueListResponseCacheForTests,
  __getIssueListResponseCacheSizeForTests,
  ISSUE_LIST_SERVER_CACHE_MAX_ENTRIES,
  issueRoutes,
} from "../routes/issues.js";
import { issueRecoveryActionService } from "../services/issue-recovery-actions.js";
import { attentionRoutes } from "../routes/attention.js";
import { dashboardAttentionIssueIds, issueService } from "../services/issues.js";
import { ensureHumanRoleDefaultGrants } from "../services/principal-access-compatibility.js";
import { resolveRequiredSuccessfulRunHandoffOnValidPath } from "../services/successful-run-handoff-state.js";

const embeddedPostgresSupport = await getEmbeddedPostgresTestSupport();
const describeEmbeddedPostgres = embeddedPostgresSupport.supported ? describe : describe.skip;

if (!embeddedPostgresSupport.supported) {
  console.warn(
    `Skipping embedded Postgres issue list route tests on this host: ${embeddedPostgresSupport.reason ?? "unsupported environment"}`,
  );
}

describeEmbeddedPostgres("issue list routes assigneeAgentId filter", () => {
  let db!: ReturnType<typeof createDb>;
  let tempDb: Awaited<ReturnType<typeof startEmbeddedPostgresTestDatabase>> | null = null;

  beforeAll(async () => {
    tempDb = await startEmbeddedPostgresTestDatabase("paperclip-issue-list-routes-");
    db = createDb(tempDb.connectionString);
  }, 20_000);

  afterEach(async () => {
    __clearIssueListResponseCacheForTests();
    await db.delete(externalObjectMentions);
    await db.delete(externalObjects);
    await db.delete(issueRelations);
    await db.delete(issueThreadInteractions);
    await db.delete(issues);
    await db.delete(labels);
    await db.delete(executionWorkspaces);
    await db.delete(projectWorkspaces);
    await db.delete(activityLog);
    await db.delete(heartbeatRuns);
    await db.delete(agents);
    await db.delete(principalPermissionGrants);
    await db.delete(companyMemberships);
    await db.delete(projects);
    await db.delete(companies);
  });

  afterAll(async () => {
    await tempDb?.cleanup();
  });

  function createApp(
    companyId: string,
    opts: Parameters<typeof issueRoutes>[2] = {},
  ) {
    const app = express();
    app.use(express.json());
    app.use((req, _res, next) => {
      const userId = req.header("x-test-user-id") ?? "cloud-user-1";
      (req as any).actor = req.header("x-test-actor") === "agent" ? {
        type: "agent", agentId: req.header("x-test-agent-id"), companyId, source: "agent_key",
      } : {
        type: "board",
        userId,
        companyIds: [companyId],
        memberships: [{ companyId, membershipRole: "owner", status: "active", principalId: userId }],
        source: "cloud_tenant",
        isInstanceAdmin: false,
      };
      next();
    });
    app.use("/api", issueRoutes(db, {} as any, opts));
    app.use(errorHandler);
    return app;
  }


  function uniqueIssuePrefix() {
    return `P${randomUUID().replace(/-/g, "").slice(0, 4).toUpperCase()}`;
  }

  async function seedCloudTenantMember(companyId: string, userId = "cloud-user-1") {
    await db.insert(companyMemberships).values({
      companyId,
      principalType: "user",
      principalId: userId,
      status: "active",
      membershipRole: "owner",
      updatedAt: new Date(),
    });
    await ensureHumanRoleDefaultGrants(db, {
      companyId,
      principalId: userId,
      membershipRole: "owner",
      grantedByUserId: null,
    });
  }

  it("filters linked external-object summaries before pagination and matches blocked count", async () => {
    const companyId = randomUUID();
    const failedId = randomUUID();
    const staleId = randomUUID();
    const emptyId = randomUUID();
    const unresolvedId = randomUUID();
    const blockerId = randomUUID();
    await db.insert(companies).values({ id: companyId, name: "Object filter", issuePrefix: uniqueIssuePrefix() });
    await seedCloudTenantMember(companyId);
    await db.insert(issues).values([
      ...Array.from({ length: 55 }, (_, i) => ({ id: randomUUID(), companyId,
        title: `Off-page unlinked ${i}`, status: "todo" as const,
        updatedAt: new Date("2026-10-28T12:00:00Z") })),
      { id: failedId, companyId, title: "Blocked failed", status: "blocked", updatedAt: new Date("2026-10-27T12:00:00Z") },
      { id: staleId, companyId, title: "Expired fresh", status: "todo", updatedAt: new Date("2026-10-26T12:00:00Z") },
      { id: emptyId, companyId, title: "No object", status: "todo", updatedAt: new Date("2026-10-25T12:00:00Z") },
      { id: unresolvedId, companyId, title: "Unresolved mention", status: "todo", updatedAt: new Date("2026-10-24T12:00:00Z") },
      { id: blockerId, companyId, title: "Blocker", status: "todo" },
    ]);
    await db.insert(issueRelations).values({ companyId, issueId: blockerId, relatedIssueId: failedId, type: "blocks" });
    const failedObject = randomUUID();
    const staleObject = randomUUID();
    await db.insert(externalObjects).values([
      { id: failedObject, companyId, providerKey: "test", objectType: "task", externalId: "failed",
        statusCategory: "blocked", liveness: "auth_required" },
      { id: staleObject, companyId, providerKey: "test", objectType: "task", externalId: "stale",
        statusCategory: "running", liveness: "fresh", nextRefreshAt: new Date("2020-01-01T00:00:00Z") },
    ]);
    await db.insert(externalObjectMentions).values([
      { companyId, sourceIssueId: failedId, sourceKind: "title", objectId: failedObject },
      { companyId, sourceIssueId: failedId, sourceKind: "description", objectId: failedObject },
      { companyId, sourceIssueId: staleId, sourceKind: "title", objectId: staleObject },
      { companyId, sourceIssueId: unresolvedId, sourceKind: "title" },
    ]);
    const app = createApp(companyId);
    const base = `/api/companies/${companyId}/issues`;
    for (const [status, expected] of [
      ["failed", [failedId]], ["auth_required", [failedId]],
      ["stale", [staleId]], ["running", [staleId]],
      ["failed,stale", [failedId, staleId]], ["waiting", []],
      ["unreachable", []],
    ] as const) {
      const rows = await request(app).get(`${base}?view=compact&externalObjectStatuses=${status}&limit=50`).expect(200);
      expect(rows.body.map((row: { id: string }) => row.id)).toEqual(expected);
      expect(await issueService(db).count(companyId, { externalObjectStatuses: status.split(",") })).toBe(expected.length);
    }
    const noneRows = await request(app).get(`${base}?view=compact&q=Unresolved%20mention&externalObjectStatuses=none`).expect(200);
    expect(noneRows.body.map((row: { id: string }) => row.id)).toEqual([unresolvedId]);
    expect((await request(app).get(`${base}?view=compact&attention=blocked&externalObjectStatuses=failed`).expect(200))
      .body.map((row: { id: string }) => row.id)).toEqual([failedId]);
    expect((await request(app).get(`${base}/count?attention=blocked&externalObjectStatuses=failed`).expect(200)).body.count).toBe(1);
    expect((await request(app).get(`${base}/count?attention=blocked&externalObjectStatuses=none`).expect(200)).body.count).toBe(0);
    await request(app).get(`${base}?externalObjectStatuses=bogus`).expect(400);
    await request(app).get(`${base}/count?attention=blocked&externalObjectStatuses=bogus`).expect(400);
  });

  it("filters typed creators before pagination with agent/user OR and matching count", async () => {
    const companyId = randomUUID();
    const agentId = randomUUID();
    const otherAgentId = randomUUID();
    const target = randomUUID();
    const userTarget = randomUUID();
    const userId = randomUUID();
    await db.insert(companies).values({ id: companyId, name: "Creator paging", issuePrefix: uniqueIssuePrefix() });
    await seedCloudTenantMember(companyId, userId);
    await db.insert(agents).values([agentId, otherAgentId].map((id) => ({
      id, companyId, name: id, role: "engineer", adapterType: "paperclip_runner" as const,
    })));
    await db.insert(issues).values([
      ...Array.from({ length: 55 }, (_, i) => ({
        id: randomUUID(), companyId, title: `Other creator ${i}`, status: "todo" as const,
        createdByAgentId: otherAgentId, updatedAt: new Date("2026-10-28T12:00:00.000Z"),
      })),
      { id: target, companyId, title: "Agent creator", status: "todo", createdByAgentId: agentId,
        updatedAt: new Date("2026-10-27T12:00:00.000Z") },
      { id: userTarget, companyId, title: "User creator", status: "todo", createdByUserId: userId,
        assigneeUserId: userId, updatedAt: new Date("2026-10-26T12:00:00.000Z") },
    ]);
    const app = createApp(companyId);
    const creators = [`agent:${agentId}`, `user:${userId}`];
    const path = `/api/companies/${companyId}/issues?view=compact&status=todo&createdByAny=agent:${agentId}&limit=50`;
    expect((await request(app).get(path).set("x-test-user-id", userId).expect(200)).body.map((issue: { id: string }) => issue.id)).toEqual([target]);
    expect((await request(app).get(path.replace(`agent:${agentId}`, creators.join(",")))
      .set("x-test-user-id", userId).expect(200)).body.map((issue: { id: string }) => issue.id)).toEqual([target, userTarget]);
    expect((await request(app).get(path.replace(`agent:${agentId}`, `agent:${agentId},user:me`))
      .set("x-test-user-id", userId).expect(200)).body.map((issue: { id: string }) => issue.id)).toEqual([target, userTarget]);
    expect((await request(app).get(`/api/companies/${companyId}/issues/count?createdByAny=user:me`)
      .set("x-test-user-id", userId).expect(200)).body.count).toBe(1);
    await request(app).get(path.replace(`agent:${agentId}`, "user:me"))
      .set("x-test-actor", "agent").set("x-test-agent-id", agentId).expect(403);
    expect(await issueService(db).count(companyId, { status: "todo", createdByAny: [`agent:${agentId}`] })).toBe(1);
    expect(await issueService(db).count(companyId, { status: "todo", createdByAny: creators })).toBe(2);
    expect(await issueService(db).count(companyId, { status: "todo", createdByAny: creators, q: "Agent creator" })).toBe(1);
    expect((await request(app).get(`/api/companies/${companyId}/issues?view=compact&status=todo&createdByAny=${creators.join(",")}&q=Agent%20creator`)
      .set("x-test-user-id", userId).expect(200)).body.map((issue: { id: string }) => issue.id)).toEqual([target]);
    expect((await request(app).get(`/api/companies/${companyId}/issues/count?status=todo&createdByAny=${creators.join(",")}&q=Agent%20creator`)
      .set("x-test-user-id", userId).expect(200)).body.count).toBe(1);
    expect((await request(app).get(`/api/companies/${companyId}/issues/count?status=todo&createdByAny=${creators.join(",")}&q=Absent%20creator`)
      .set("x-test-user-id", userId).expect(200)).body.count).toBe(0);
    const mixed = `status=todo&createdByAny=${creators.join(",")}&assigneeAny=user:${userId}&priorities=medium&q=User%20creator`;
    expect((await request(app).get(`/api/companies/${companyId}/issues?view=compact&${mixed}&limit=50`)
      .set("x-test-user-id", userId).expect(200)).body.map((issue: { id: string }) => issue.id)).toEqual([userTarget]);
    expect((await request(app).get(`/api/companies/${companyId}/issues/count?${mixed}`)
      .set("x-test-user-id", userId).expect(200)).body.count).toBe(1);
    await request(app).get(`/api/companies/${companyId}/issues/count?${mixed}&limit=50`).expect(400);
    await request(app).get(`/api/companies/${companyId}/issues/count?${mixed}`)
      .set("x-test-actor", "agent").set("x-test-agent-id", agentId).expect(403);
    await request(app).get(`/api/companies/${companyId}/issues/count?attention=bogus`).expect(400);
    await request(app).get(`/api/companies/${companyId}/issues/count?unassignedBoth=bogus`).expect(400);
    await request(app).get(`/api/companies/${companyId}/issues/count?assigneeAgentId=bogus`).expect(422);
    expect((await request(app).get(`/api/companies/${companyId}/issues?view=compact&assigneeUserId=me`)
      .set("x-test-user-id", userId).expect(200)).body.map((issue: { id: string }) => issue.id)).toEqual([userTarget]);
    expect((await request(app).get(`/api/companies/${companyId}/issues/count?assigneeUserId=me`)
      .set("x-test-user-id", userId).expect(200)).body.count).toBe(1);
    await request(app).get(path.replace(`agent:${agentId}`, "agent:invalid")).expect(400);
    await request(app).get(`/api/companies/${companyId}/issues/count?attention=blocked&createdByAny=user:invalid`).expect(400);
  });

  it("filters typed assignees before pagination with agent/user/unassigned OR and matching count", async () => {
    const companyId = randomUUID();
    const agentId = randomUUID();
    const otherAgentId = randomUUID();
    const userId = randomUUID();
    const agentTarget = randomUUID();
    const userTarget = randomUUID();
    const unassignedTarget = randomUUID();
    await db.insert(companies).values({ id: companyId, name: "Assignee paging", issuePrefix: uniqueIssuePrefix() });
    await seedCloudTenantMember(companyId, userId);
    await db.insert(agents).values([agentId, otherAgentId].map((id) => ({
      id, companyId, name: id, role: "engineer", adapterType: "paperclip_runner" as const,
    })));
    await db.insert(issues).values([
      ...Array.from({ length: 55 }, (_, i) => ({
        id: randomUUID(), companyId, title: `Other assignee ${i}`, status: "todo" as const,
        assigneeAgentId: otherAgentId, updatedAt: new Date("2026-10-28T12:00:00.000Z"),
      })),
      { id: agentTarget, companyId, title: "Agent assignee", status: "todo", assigneeAgentId: agentId,
        updatedAt: new Date("2026-10-27T12:00:00.000Z") },
      { id: userTarget, companyId, title: "User assignee", status: "todo", assigneeUserId: userId,
        updatedAt: new Date("2026-10-26T12:00:00.000Z") },
      { id: unassignedTarget, companyId, title: "Unassigned", status: "todo",
        updatedAt: new Date("2026-10-25T12:00:00.000Z") },
    ]);
    const app = createApp(companyId);
    const base = `/api/companies/${companyId}/issues?view=compact&status=todo&limit=50&assigneeAny=`;
    const selected = [`agent:${agentId}`, `user:${userId}`, "unassigned"];
    for (const [selection, expected] of [
      [selected[0]!, [agentTarget]],
      [selected.slice(0, 2).join(","), [agentTarget, userTarget]],
      [selected.join(","), [agentTarget, userTarget, unassignedTarget]],
    ] as const) {
      const response = await request(app).get(base + selection).set("x-test-user-id", userId).expect(200);
      expect(response.body.map((issue: { id: string }) => issue.id)).toEqual(expected);
    }
    expect(await issueService(db).count(companyId, { status: "todo", assigneeAny: selected })).toBe(3);
    const meSelection = `agent:${agentId},user:me,unassigned`;
    const meRows = await request(app).get(base + meSelection).set("x-test-user-id", userId).expect(200);
    expect(meRows.body.map((issue: { id: string }) => issue.id)).toEqual([agentTarget, userTarget, unassignedTarget]);
    const countBase = `/api/companies/${companyId}/issues/count?status=todo&assigneeAny=`;
    expect((await request(app).get(countBase + meSelection).set("x-test-user-id", userId).expect(200)).body.count).toBe(3);
    const localBoardTarget = randomUUID();
    await seedCloudTenantMember(companyId, "local-board");
    await db.insert(issues).values({ id: localBoardTarget, companyId, title: "Board-local assignee",
      status: "todo", assigneeUserId: "local-board" });
    expect(await issueService(db).count(companyId, { status: "todo", assigneeAny: ["user:local-board"] })).toBe(1);
    expect((await request(app).get(base + "user:me")
      .set("x-test-user-id", "local-board").expect(200)).body.map((issue: { id: string }) => issue.id)).toEqual([localBoardTarget]);
    expect((await request(app).get(countBase + "user:me")
      .set("x-test-user-id", "local-board").expect(200)).body.count).toBe(1);
    await request(app).get(base + "user:me").set("x-test-actor", "agent").set("x-test-agent-id", agentId).expect(403);
    await request(app).get(countBase + "user:me").set("x-test-actor", "agent").set("x-test-agent-id", agentId).expect(403);
    await request(app).get(base + "agent:invalid").expect(400);
    await request(app).get(`/api/companies/${companyId}/issues/count?attention=blocked&assigneeAny=user:invalid`).expect(400);
  });

  it("filters labelIds before the first page with OR semantics and matching count", async () => {
    const companyId = randomUUID();
    const otherLabel = randomUUID();
    const targetLabel = randomUUID();
    const target = randomUUID();
    await db.insert(companies).values({ id: companyId, name: "Label paging", issuePrefix: uniqueIssuePrefix() });
    await seedCloudTenantMember(companyId);
    await db.insert(labels).values([
      { id: otherLabel, companyId, name: "Other", color: "#000000" },
      { id: targetLabel, companyId, name: "Target", color: "#ffffff" },
    ]);
    const offPage = Array.from({ length: 55 }, (_, i) => ({
      id: randomUUID(), companyId, title: `Other label ${i}`, status: "todo" as const,
      updatedAt: new Date("2026-10-28T12:00:00.000Z"),
    }));
    await db.insert(issues).values([
      ...offPage,
      { id: target, companyId, title: "Target label", status: "todo" as const,
        updatedAt: new Date("2026-10-27T12:00:00.000Z") },
    ]);
    await db.insert(issueLabels).values([
      ...offPage.map(({ id }) => ({ issueId: id, labelId: otherLabel, companyId })),
      { issueId: target, labelId: targetLabel, companyId },
    ]);
    const app = createApp(companyId);
    const path = `/api/companies/${companyId}/issues?view=compact&status=todo&labelIds=${targetLabel},${randomUUID()}&limit=50&sortField=updated&sortDir=desc`;
    expect((await request(app).get(path).expect(200)).body.map((issue: { id: string }) => issue.id)).toEqual([target]);
    expect(await issueService(db).count(companyId, { status: "todo", labelIds: [targetLabel] })).toBe(1);
    expect(await issueService(db).count(companyId, { status: "todo", labelIds: [otherLabel] })).toBe(55);
    await request(app).get(path.replace(`${targetLabel},`, "bad,")).expect(400);
    await request(app).get(`/api/companies/${companyId}/issues/count?attention=blocked&labelIds=bad`).expect(400);
  });

  it("filters projectIds before the first page and rejects malformed lists", async () => {
    const companyId = randomUUID();
    const otherProjectId = randomUUID();
    const targetProjectId = randomUUID();
    const target = randomUUID();
    await db.insert(companies).values({ id: companyId, name: "Project paging", issuePrefix: uniqueIssuePrefix() });
    await seedCloudTenantMember(companyId);
    await db.insert(projects).values([
      { id: otherProjectId, companyId, name: "Other" },
      { id: targetProjectId, companyId, name: "Target" },
    ]);
    await db.insert(issues).values([
      ...Array.from({ length: 55 }, (_, i) => ({
        id: randomUUID(), companyId, projectId: otherProjectId,
        title: `Other ${i}`, status: "todo" as const,
        updatedAt: new Date("2026-10-28T12:00:00.000Z"),
      })),
      { id: target, companyId, projectId: targetProjectId,
        title: "Target project", status: "todo" as const,
        updatedAt: new Date("2026-10-27T12:00:00.000Z") },
    ]);
    const app = createApp(companyId);
    const path = `/api/companies/${companyId}/issues?view=compact&status=todo&projectIds=${targetProjectId},${randomUUID()}&limit=50&sortField=updated&sortDir=desc`;
    expect((await request(app).get(path).expect(200)).body.map((issue: { id: string }) => issue.id)).toEqual([target]);
    await request(app).get(path.replace(`${targetProjectId},`, ",")).expect(400);
    await request(app).get(path.replace(`${targetProjectId},`, "not-a-uuid,")).expect(400);
    await request(app).get(`/api/companies/${companyId}/issues/count?attention=blocked&projectIds=bad`).expect(400);
  });

  it("filters workspaceIds before pagination and rejects malformed lists", async () => {
    const companyId = randomUUID();
    const projectId = randomUUID();
    const otherWorkspaceId = randomUUID();
    const targetWorkspaceId = randomUUID();
    const executionWorkspaceId = randomUUID();
    const executionIssueId = randomUUID();
    const target = randomUUID();
    await db.insert(companies).values({ id: companyId, name: "Workspace paging", issuePrefix: uniqueIssuePrefix() });
    await seedCloudTenantMember(companyId);
    await db.insert(projects).values({ id: projectId, companyId, name: "Workspace project" });
    await db.insert(projectWorkspaces).values([
      { id: otherWorkspaceId, companyId, projectId, name: "Other" },
      { id: targetWorkspaceId, companyId, projectId, name: "Target" },
    ]);
    await db.insert(executionWorkspaces).values({
      id: executionWorkspaceId, companyId, projectId, projectWorkspaceId: otherWorkspaceId,
      mode: "isolated_workspace", strategyType: "local_fs", name: "Execution",
    });
    await db.insert(issues).values([
      ...Array.from({ length: 55 }, (_, i) => ({
        id: randomUUID(), companyId, projectId, projectWorkspaceId: otherWorkspaceId,
        title: `Other workspace ${i}`, status: "todo" as const,
        updatedAt: new Date("2026-10-28T12:00:00.000Z"),
      })),
      { id: target, companyId, projectId, projectWorkspaceId: targetWorkspaceId,
        title: "Target workspace", status: "todo" as const,
        updatedAt: new Date("2026-10-27T12:00:00.000Z") },
      { id: executionIssueId, companyId, projectId, projectWorkspaceId: targetWorkspaceId,
        executionWorkspaceId, title: "Execution takes precedence", status: "todo" as const,
        updatedAt: new Date("2026-10-27T12:00:00.000Z") },
    ]);
    const app = createApp(companyId);
    const path = `/api/companies/${companyId}/issues?view=compact&status=todo&workspaceIds=${targetWorkspaceId},${randomUUID()}&limit=50&sortField=updated&sortDir=desc`;
    expect((await request(app).get(path).expect(200)).body.map((issue: { id: string }) => issue.id)).toEqual([target]);
    expect(await issueService(db).count(companyId, { status: "todo", workspaceIds: [targetWorkspaceId, randomUUID()] })).toBe(1);
    expect(await issueService(db).count(companyId, { status: "todo", workspaceIds: [otherWorkspaceId] })).toBe(55);
    expect((await request(app).get(path.replace(`${targetWorkspaceId},`, `${executionWorkspaceId},`)).expect(200)).body.map((issue: { id: string }) => issue.id)).toEqual([executionIssueId]);
    expect(await issueService(db).count(companyId, { status: "todo", workspaceIds: [executionWorkspaceId] })).toBe(1);
    await request(app).get(path.replace(`${targetWorkspaceId},`, ",")).expect(400);
    await request(app).get(path.replace(`${targetWorkspaceId},`, "bad,")).expect(400);
    await request(app).get(`/api/companies/${companyId}/issues/count?attention=blocked&workspaceIds=bad`).expect(400);
  });

  it("normalizes default project and shared execution workspaces before paging and count", async () => {
    const companyId = randomUUID();
    const projectId = randomUUID();
    const primaryId = randomUUID();
    const defaultId = randomUUID();
    const namedId = randomUUID();
    const sharedId = randomUUID();
    const isolatedId = randomUUID();
    const defaultIssueId = randomUUID();
    const sharedIssueId = randomUUID();
    const namedIssueId = randomUUID();
    const isolatedIssueId = randomUUID();
    await db.insert(companies).values({ id: companyId, name: "Workspace normalization", issuePrefix: uniqueIssuePrefix() });
    await seedCloudTenantMember(companyId);
    await db.insert(projects).values({ id: projectId, companyId, name: "Project", executionWorkspacePolicy: { defaultProjectWorkspaceId: defaultId } });
    await db.insert(projectWorkspaces).values([
      { id: primaryId, companyId, projectId, name: "Primary", isPrimary: true },
      { id: defaultId, companyId, projectId, name: "Policy default" },
      { id: namedId, companyId, projectId, name: "Named" },
    ]);
    await db.insert(executionWorkspaces).values([
      { id: sharedId, companyId, projectId, projectWorkspaceId: defaultId, mode: "shared_workspace", strategyType: "local_fs", name: "Shared" },
      { id: isolatedId, companyId, projectId, projectWorkspaceId: defaultId, mode: "isolated_workspace", strategyType: "local_fs", name: "Isolated" },
    ]);
    await db.insert(issues).values([
      { id: defaultIssueId, companyId, projectId, projectWorkspaceId: defaultId, title: "Default", status: "todo" },
      { id: sharedIssueId, companyId, projectId, projectWorkspaceId: namedId, executionWorkspaceId: sharedId, title: "Shared", status: "todo" },
      { id: namedIssueId, companyId, projectId, projectWorkspaceId: namedId, title: "Named", status: "todo" },
      { id: isolatedIssueId, companyId, projectId, projectWorkspaceId: defaultId, executionWorkspaceId: isolatedId, title: "Isolated", status: "todo" },
    ]);
    const app = createApp(companyId);
    for (const [workspaceId, expected] of [
      [defaultId, []], [sharedId, []], [namedId, [namedIssueId]], [isolatedId, [isolatedIssueId]],
    ] as const) {
      const path = `/api/companies/${companyId}/issues?view=compact&workspaceIds=${workspaceId}&limit=50`;
      expect((await request(app).get(path).expect(200)).body.map((issue: { id: string }) => issue.id)).toEqual(expected);
      expect(await issueService(db).count(companyId, { workspaceIds: [workspaceId] })).toBe(expected.length);
    }
    // A primary workspace is not the default when the explicit project policy wins.
    expect(await issueService(db).count(companyId, { workspaceIds: [primaryId] })).toBe(0);
  });

  it("uses primary fallback and the same workspace predicate for blocked inbox list and count", async () => {
    const companyId = randomUUID();
    const creatorAgentId = randomUUID();
    const creatorUserId = randomUUID();
    const projectId = randomUUID();
    const primaryId = randomUUID();
    const namedId = randomUUID();
    const sharedId = randomUUID();
    const blockedId = randomUUID();
    const sharedBlockedId = randomUUID();
    const leafId = randomUUID();
    await db.insert(companies).values({ id: companyId, name: "Blocked workspace", issuePrefix: uniqueIssuePrefix() });
    await seedCloudTenantMember(companyId);
    await seedCloudTenantMember(companyId, creatorUserId);
    await db.insert(agents).values({ id: creatorAgentId, companyId, name: "Creator", role: "engineer", adapterType: "paperclip_runner" });
    await db.insert(projects).values({ id: projectId, companyId, name: "Primary fallback project" });
    await db.insert(projectWorkspaces).values([
      { id: primaryId, companyId, projectId, name: "Primary", isPrimary: true },
      { id: namedId, companyId, projectId, name: "Named" },
    ]);
    await db.insert(executionWorkspaces).values({
      id: sharedId, companyId, projectId, projectWorkspaceId: primaryId,
      mode: "shared_workspace", strategyType: "local_fs", name: "Shared primary",
    });
    await db.insert(issues).values([
      { id: blockedId, companyId, projectId, projectWorkspaceId: namedId, title: "Blocked named source", status: "blocked", priority: "critical", createdByAgentId: creatorAgentId, assigneeAgentId: creatorAgentId },
      { id: sharedBlockedId, companyId, projectId, projectWorkspaceId: namedId, executionWorkspaceId: sharedId,
        title: "Blocked shared source", status: "blocked", priority: "low", createdByUserId: creatorUserId, assigneeUserId: creatorUserId },
      { id: leafId, companyId, projectId, projectWorkspaceId: primaryId, title: "Unassigned blocker", status: "todo" },
    ]);
    await db.insert(issueRelations).values([
      { companyId, issueId: leafId, relatedIssueId: blockedId, type: "blocks" },
      { companyId, issueId: leafId, relatedIssueId: sharedBlockedId, type: "blocks" },
    ]);
    await db.insert(heartbeatRuns).values({
      companyId, agentId: creatorAgentId, status: "queued", contextSnapshot: { issueId: blockedId },
    });
    const app = createApp(companyId);
    for (const [workspaceId, expected] of [
      [namedId, [blockedId]], [primaryId, []], [sharedId, []],
    ] as const) {
      const path = `/api/companies/${companyId}/issues?view=compact&attention=blocked&workspaceIds=${workspaceId}&limit=50`;
      const rows = await request(app).get(path).expect(200);
      expect(rows.body.map((issue: { id: string }) => issue.id)).toEqual(expected);
      const count = await request(app).get(`/api/companies/${companyId}/issues/count?attention=blocked&workspaceIds=${workspaceId}`).expect(200);
      expect(count.body.count).toBe(expected.length);
    }
    expect(await issueService(db).count(companyId, { workspaceIds: [primaryId] })).toBe(0);
    expect((await request(app).get(`/api/companies/${companyId}/issues?view=compact&workspaceIds=${primaryId}&limit=50`).expect(200)).body).toEqual([]);
    const critical = `attention=blocked&priorities=critical&limit=50`;
    expect((await request(app).get(`/api/companies/${companyId}/issues?view=compact&${critical}`).expect(200))
      .body.map((issue: { id: string }) => issue.id)).toEqual([blockedId]);
    expect((await request(app).get(`/api/companies/${companyId}/issues/count?attention=blocked&priorities=critical`).expect(200))
      .body.count).toBe(1);
    expect((await request(app).get(`/api/companies/${companyId}/issues/count?attention=blocked&priorities=high`).expect(200))
      .body.count).toBe(0);
    const liveBlocked = `/api/companies/${companyId}/issues?view=compact&attention=blocked&liveOnly=true&limit=50`;
    expect((await request(app).get(liveBlocked).expect(200)).body.map((issue: { id: string }) => issue.id)).toEqual([blockedId]);
    expect((await request(app).get(`/api/companies/${companyId}/issues/count?attention=blocked&liveOnly=true`).expect(200))
      .body.count).toBe(1);
    expect((await request(app).get(`/api/companies/${companyId}/issues/count?attention=blocked&liveOnly=true&priorities=low`).expect(200))
      .body.count).toBe(0);
    for (const [creator, expected] of [
      [`agent:${creatorAgentId}`, [blockedId]],
      [`user:${creatorUserId}`, [sharedBlockedId]],
      [`agent:${creatorAgentId},user:${creatorUserId}`, [blockedId, sharedBlockedId]],
    ] as const) {
      const base = `/api/companies/${companyId}/issues`;
      const rows = await request(app).get(`${base}?view=compact&attention=blocked&createdByAny=${creator}&limit=50`).expect(200);
      expect(rows.body.map((issue: { id: string }) => issue.id).sort()).toEqual([...expected].sort());
      const count = await request(app).get(`${base}/count?attention=blocked&createdByAny=${creator}`).expect(200);
      expect(count.body.count).toBe(expected.length);
    }
    for (const [assignee, expected] of [
      [`agent:${creatorAgentId}`, [blockedId]],
      [`user:${creatorUserId}`, [sharedBlockedId]],
      [`agent:${creatorAgentId},user:${creatorUserId}`, [blockedId, sharedBlockedId]],
      ["unassigned", []],
    ] as const) {
      const base = `/api/companies/${companyId}/issues`;
      const rows = await request(app).get(`${base}?view=compact&attention=blocked&assigneeAny=${assignee}&limit=50`).expect(200);
      expect(rows.body.map((issue: { id: string }) => issue.id).sort()).toEqual([...expected].sort());
      const count = await request(app).get(`${base}/count?attention=blocked&assigneeAny=${assignee}`).expect(200);
      expect(count.body.count).toBe(expected.length);
    }
    await request(app).get(`/api/companies/${companyId}/issues/count?attention=blocked&priorities=invalid`).expect(400);
  });

  it("filters priorities before pagination, including a match beyond the unfiltered first page", async () => {
    const companyId = randomUUID();
    await db.insert(companies).values({ id: companyId, name: "Priority paging", issuePrefix: uniqueIssuePrefix() });
    await seedCloudTenantMember(companyId);
    const target = randomUUID();
    await db.insert(issues).values([
      ...Array.from({ length: 55 }, (_, i) => ({
        id: randomUUID(), companyId, title: `Ordinary ${i}`, status: "todo" as const,
        priority: "low" as const, updatedAt: new Date("2026-10-28T12:00:00.000Z"),
      })),
      { id: target, companyId, title: "Target priority", status: "todo" as const,
        priority: "critical" as const, updatedAt: new Date("2026-10-27T12:00:00.000Z") },
    ]);
    const app = createApp(companyId);
    const path = `/api/companies/${companyId}/issues?view=compact&status=todo&priorities=critical,high&limit=50&sortField=updated&sortDir=desc`;
    const response = await request(app).get(path).expect(200);
    expect(response.body.map((issue: { id: string }) => issue.id)).toEqual([target]);
    expect(await issueService(db).count(companyId, { status: "todo", priorities: ["critical", "high"] })).toBe(1);
    await request(app).get(path.replace("critical,high", "critical,invalid")).expect(400);
    await request(app).get(path.replace("critical,high", "")).expect(400);
  });

  it("returns only unassigned issues for assigneeAgentId=null", async () => {
    const companyId = randomUUID();
    const assigneeAgentId = randomUUID();
    const assignedIssueId = randomUUID();
    const unassignedIssueId = randomUUID();

    await db.insert(companies).values({
      id: companyId,
      name: "Paperclip",
      issuePrefix: uniqueIssuePrefix(),
      requireBoardApprovalForNewAgents: false,
    });
    await seedCloudTenantMember(companyId);
    await db.insert(agents).values({
      id: assigneeAgentId,
      companyId,
      name: "Assignee",
      role: "engineer",
      status: "active",
      adapterType: "codex_local",
      adapterConfig: {},
      runtimeConfig: {},
      permissions: {},
    });
    await db.insert(issues).values([
      {
        id: assignedIssueId,
        companyId,
        title: "Assigned issue",
        status: "todo",
        priority: "medium",
        assigneeAgentId,
      },
      {
        id: unassignedIssueId,
        companyId,
        title: "Unassigned issue",
        status: "todo",
        priority: "medium",
        assigneeAgentId: null,
      },
    ]);

    const app = createApp(companyId);
    const res = await request(app)
      .get(`/api/companies/${companyId}/issues`)
      .query({ status: "todo", assigneeAgentId: "null", limit: "20" });

    expect(res.status, JSON.stringify(res.body)).toBe(200);
    expect(res.body.map((issue: { id: string }) => issue.id)).toEqual([unassignedIssueId]);
  });

  it("distinguishes agent-unassigned from both-unassigned before pagination", async () => {
    const companyId = randomUUID();
    const target = randomUUID();
    await db.insert(companies).values({ id: companyId, name: "Both unassigned", issuePrefix: uniqueIssuePrefix() });
    await seedCloudTenantMember(companyId);
    await db.insert(issues).values([
      ...Array.from({ length: 55 }, (_, i) => ({
        id: randomUUID(), companyId, title: `User assigned ${i}`, status: "todo" as const,
        priority: "medium" as const, assigneeUserId: "cloud-user-1",
        updatedAt: new Date("2026-10-28T12:00:00.000Z"),
      })),
      { id: target, companyId, title: "Neither assigned", status: "todo" as const,
        priority: "medium" as const, updatedAt: new Date("2026-10-27T12:00:00.000Z") },
    ]);
    const app = createApp(companyId);
    const path = `/api/companies/${companyId}/issues?view=compact&status=todo&assigneeAgentId=null&limit=50&sortField=updated&sortDir=desc`;
    const agentOnly = await request(app).get(path).expect(200);
    expect(agentOnly.body).toHaveLength(50);
    const both = await request(app).get(`${path}&unassignedBoth=true`).expect(200);
    expect(both.body.map((issue: { id: string }) => issue.id)).toEqual([target]);
    await request(app).get(`${path}&unassignedBoth=maybe`).expect(400);
  });

  it("projects a queued retry on a blocked issue before Dashboard classification", async () => {
    const companyId = randomUUID();
    const agentId = randomUUID();
    const issueId = randomUUID();
    await db.insert(companies).values({ id: companyId, name: "Queued retry projection", issuePrefix: uniqueIssuePrefix() });
    await seedCloudTenantMember(companyId);
    await db.insert(agents).values({ id: agentId, companyId, name: "Retry worker", role: "engineer", adapterType: "paperclip_runner" });
    await db.insert(issues).values({ id: issueId, companyId, title: "Retry issue", status: "blocked", assigneeAgentId: agentId });
    await db.insert(heartbeatRuns).values({ companyId, agentId, status: "queued", scheduledRetryReason: "Retry after transient failure", contextSnapshot: { issueId } });
    const app = createApp(companyId);
    const res = await request(app).get(`/api/companies/${companyId}/issues?view=compact&attention=blocked&limit=50`).expect(200);
    expect(res.body.find((row: { id: string }) => row.id === issueId)?.scheduledRetry).toMatchObject({ status: "queued", scheduledRetryReason: "Retry after transient failure" });
  });

  it("filters off-page Dashboard recovery retries before paging and agrees with count", async () => {
    const companyId = randomUUID();
    const agentId = randomUUID();
    const blockerId = randomUUID();
    const recoveryId = randomUUID();
    const decisionId = randomUUID();
    await db.insert(companies).values({ id: companyId, name: "Dashboard recovery paging", issuePrefix: uniqueIssuePrefix() });
    await seedCloudTenantMember(companyId);
    await db.insert(agents).values({ id: agentId, companyId, name: "Retry worker", role: "engineer", adapterType: "paperclip_runner" });
    await db.insert(issues).values([
      { id: blockerId, companyId, title: "Shared blocker", status: "todo" },
      ...Array.from({ length: 55 }, (_, i) => ({ companyId, title: `Ordinary blocked ${i}`, status: "blocked" as const, updatedAt: new Date("2026-10-28T12:00:00Z") })),
      { id: recoveryId, companyId, title: "Off-page queued recovery", status: "blocked", assigneeAgentId: agentId, updatedAt: new Date("2026-10-20T12:00:00Z") },
      { id: decisionId, companyId, title: "Off-page pending decision", status: "blocked", assigneeAgentId: agentId, updatedAt: new Date("2026-10-19T12:00:00Z") },
    ]);
    await db.insert(issueThreadInteractions).values({
      companyId, issueId: decisionId, kind: "request_confirmation", status: "pending", createdByAgentId: agentId,
      payload: { version: 1, prompt: "Decide the issue" },
    });
    const blockedRows = await db.select({ id: issues.id }).from(issues);
    await db.insert(issueRelations).values(blockedRows.filter((row) => row.id !== blockerId).map((row) => ({
      companyId, issueId: blockerId, relatedIssueId: row.id, type: "blocks" as const,
    })));
    await db.insert(heartbeatRuns).values({
      companyId, agentId, status: "queued", scheduledRetryReason: "Retry after transient failure", contextSnapshot: { issueId: recoveryId },
    });
    const app = createApp(companyId);
    const base = `/api/companies/${companyId}/issues`;
    const page = await request(app).get(`${base}?view=compact&attention=blocked&limit=50`).expect(200);
    expect(page.body).toHaveLength(50);
    expect(page.body.map((row: { id: string }) => row.id)).not.toContain(recoveryId);
    const filtered = await request(app).get(`${base}?view=compact&attention=blocked&dashboardKind=recovery&limit=50`).expect(200);
    expect(filtered.body.map((row: { id: string }) => row.id)).toEqual([recoveryId]);
    const count = await request(app).get(`${base}/count?attention=blocked&dashboardKind=recovery`).expect(200);
    expect(count.body.count).toBe(1);
    const blocked = await request(app).get(`${base}?view=compact&attention=blocked&dashboardKind=blocked&limit=50&offset=50`).expect(200);
    expect(blocked.body).toHaveLength(5);
    expect(blocked.body.map((row: { id: string }) => row.id)).not.toContain(recoveryId);
    const blockedCount = await request(app).get(`${base}/count?attention=blocked&dashboardKind=blocked`).expect(200);
    expect(blockedCount.body.count).toBe(55);
    const decisions = await request(app).get(`${base}?view=compact&attention=blocked&dashboardKind=decision&limit=50`).expect(200);
    expect(decisions.body.map((row: { id: string }) => row.id)).toEqual([decisionId]);
    const decisionsCount = await request(app).get(`${base}/count?attention=blocked&dashboardKind=decision`).expect(200);
    expect(decisionsCount.body.count).toBe(1);
    // Counts alone lose the identity needed to deduplicate a native review that
    // describes the same off-page issue. Keep this server-only set off the wire.
    const ids = await dashboardAttentionIssueIds(db, companyId);
    expect([...ids.recovery]).toEqual([recoveryId]);
    expect([...ids.decision]).toEqual([decisionId]);
    expect(ids.blocked.size).toBe(55);
    expect(ids.blocked.has(recoveryId)).toBe(false);
    expect(ids.blocked.has(decisionId)).toBe(false);
    await issueRecoveryActionService(db).upsertSourceScoped({
      companyId, sourceIssueId: recoveryId, kind: "missing_disposition", ownerType: "board",
      cause: "successful_run_missing_issue_disposition", fingerprint: "off-page-native-overlap",
      evidence: { sourceRunId: "run-off-page" }, nextAction: "Choose a disposition.", wakePolicy: { type: "wake_owner" },
    });
    const attentionApp = createApp(companyId);
    attentionApp.use("/api", attentionRoutes(db));
    const native = await request(attentionApp)
      .get(`/api/companies/${companyId}/attention?sourceKinds=issue_thread_interaction,recovery_action&dashboardCounts=true&limit=1`)
      .expect(200);
    expect(native.body.items).toHaveLength(1);
    expect(native.body.nextCursor).toBeTruthy();
    expect(native.body.countsBySourceKind.recovery_action).toBe(1);
    expect(native.body.dashboardCounts).toEqual({ blocked: 55, decision: 2, recovery: 1 });
    await request(app).get(`${base}?attention=blocked&dashboardKind=unknown`).expect(400);
    await request(app).get(`${base}/count?dashboardKind=recovery`).expect(400);
  });

  it("does not classify a running retry as a queued Dashboard recovery", async () => {
    const companyId = randomUUID();
    const agentId = randomUUID();
    const issueId = randomUUID();
    await db.insert(companies).values({ id: companyId, name: "Running retry", issuePrefix: uniqueIssuePrefix() });
    await seedCloudTenantMember(companyId);
    await db.insert(agents).values({ id: agentId, companyId, name: "Running worker", role: "engineer", adapterType: "paperclip_runner" });
    await db.insert(issues).values({ id: issueId, companyId, title: "Running retry issue", status: "blocked", assigneeAgentId: agentId });
    await db.insert(heartbeatRuns).values([
      { companyId, agentId, status: "scheduled_retry", scheduledRetryReason: "Older scheduled retry", contextSnapshot: { issueId } },
      { companyId, agentId, status: "running", scheduledRetryReason: "Current retry", contextSnapshot: { issueId } },
    ]);
    const app = createApp(companyId);
    const base = `/api/companies/${companyId}/issues`;
    const filtered = await request(app).get(`${base}?view=compact&attention=blocked&dashboardKind=recovery&limit=50`).expect(200);
    expect(filtered.body).toEqual([]);
    const count = await request(app).get(`${base}/count?attention=blocked&dashboardKind=recovery`).expect(200);
    expect(count.body.count).toBe(0);
  });

  it("classifies an active recovery action consistently on a blocked issue", async () => {
    const companyId = randomUUID();
    const agentId = randomUUID();
    const issueId = randomUUID();
    await db.insert(companies).values({ id: companyId, name: "Active recovery", issuePrefix: uniqueIssuePrefix() });
    await seedCloudTenantMember(companyId);
    await db.insert(agents).values({ id: agentId, companyId, name: "Recovery worker", role: "engineer", status: "active", adapterType: "codex_local", adapterConfig: {}, runtimeConfig: {}, permissions: {} });
    await db.insert(issues).values({ id: issueId, companyId, title: "Active recovery issue", status: "blocked", assigneeAgentId: agentId });
    await issueRecoveryActionService(db).upsertSourceScoped({
      companyId, sourceIssueId: issueId, kind: "missing_disposition", ownerType: "agent", ownerAgentId: agentId,
      cause: "successful_run_missing_issue_disposition", fingerprint: "dashboard-active-recovery",
      evidence: { sourceRunId: "run-1" }, nextAction: "Choose a disposition.", wakePolicy: { type: "wake_owner" },
    });
    const app = createApp(companyId);
    const base = `/api/companies/${companyId}/issues`;
    const page = await request(app).get(`${base}?view=compact&attention=blocked&dashboardKind=recovery&limit=50`).expect(200);
    const count = await request(app).get(`${base}/count?attention=blocked&dashboardKind=recovery`).expect(200);
    expect(count.body.count).toBe(page.body.length);
    expect(page.body.map((row: { id: string }) => row.id)).toEqual([issueId]);
    expect(page.body[0].activeRecoveryAction?.status).toMatch(/active|escalated/);
  });

  it("returns compact issue list rows with recovery chips but without detail-only fields", async () => {
    const companyId = randomUUID();
    const ownerAgentId = randomUUID();
    const issueId = randomUUID();
    const sourceRunId = randomUUID();

    await db.insert(companies).values({
      id: companyId,
      name: "Paperclip",
      issuePrefix: uniqueIssuePrefix(),
      requireBoardApprovalForNewAgents: false,
    });
    await seedCloudTenantMember(companyId);
    await db.insert(agents).values({
      id: ownerAgentId,
      companyId,
      name: "Recovery owner",
      role: "engineer",
      status: "active",
      adapterType: "codex_local",
      adapterConfig: {},
      runtimeConfig: {},
      permissions: {},
    });
    await db.insert(issues).values({
      id: issueId,
      companyId,
      title: "Compact issue",
      description: "This long detail belongs on the issue detail endpoint, not the board list.",
      status: "todo",
      priority: "medium",
      billingCode: "product",
    });
    const recoveryAction = await issueRecoveryActionService(db).upsertSourceScoped({
      companyId,
      sourceIssueId: issueId,
      kind: "missing_disposition",
      ownerType: "agent",
      ownerAgentId,
      cause: "successful_run_missing_issue_disposition",
      fingerprint: "missing-disposition:compact-route",
      evidence: { sourceRunId: "run-1" },
      nextAction: "Choose a valid issue disposition.",
      wakePolicy: { type: "wake_owner" },
    });
    await db.insert(activityLog).values({
      companyId,
      actorType: "system",
      actorId: "system",
      action: "issue.successful_run_handoff_required",
      entityType: "issue",
      entityId: issueId,
      agentId: ownerAgentId,
      runId: null,
      details: {
        sourceRunId,
        detectedProgressSummary: "Implemented the requested change without choosing a disposition.",
      },
    });

    const app = createApp(companyId);
    const res = await request(app)
      .get(`/api/companies/${companyId}/issues`)
      .query({ view: "compact", limit: "20" });

    expect(res.status, JSON.stringify(res.body)).toBe(200);
    expect(res.headers.etag).toMatch(/^"compact-issues:/);
    expect(res.headers["cache-control"]).toBe("private, must-revalidate");
    expect(res.body).toHaveLength(1);
    expect(res.body[0]).toMatchObject({
      id: issueId,
      companyId,
      title: "Compact issue",
      description: "This long detail belongs on the issue detail endpoint, not the board list.",
      status: "todo",
      priority: "medium",
      billingCode: "product",
      activeRecoveryAction: {
        id: recoveryAction.id,
        sourceIssueId: issueId,
        ownerAgentId,
        kind: "missing_disposition",
      },
      successfulRunHandoff: {
        state: "required",
        required: true,
        hasLiveContinuation: false,
        sourceRunId,
        assigneeAgentId: ownerAgentId,
      },
    });
    expect(res.body[0]).not.toHaveProperty("workProducts");
    expect(res.body[0]).not.toHaveProperty("project");
    expect(res.body[0]).not.toHaveProperty("goal");
  });

  it("filters own live runs before pagination and count, without task-key or company leakage", async () => {
    const companyId = randomUUID();
    const otherCompanyId = randomUUID();
    const agentId = randomUUID();
    const liveId = randomUUID();
    const otherId = randomUUID();
    const doneId = randomUUID();
    await db.insert(companies).values([
      { id: companyId, name: "Live paging", issuePrefix: uniqueIssuePrefix() },
      { id: otherCompanyId, name: "Other live tenant", issuePrefix: uniqueIssuePrefix() },
    ]);
    await seedCloudTenantMember(companyId);
    await db.insert(agents).values({ id: agentId, companyId, name: "Live worker", role: "engineer", status: "active", adapterType: "codex_local", adapterConfig: {}, runtimeConfig: {}, permissions: {} });
    await db.insert(issues).values([
      ...Array.from({ length: 55 }, (_, index) => ({ companyId, title: `Nonlive ${index}`, status: "todo" as const, priority: "medium" as const, updatedAt: new Date("2026-10-27T12:00:00.000Z") })),
      { id: liveId, companyId, title: "Offscreen live", status: "todo" as const, priority: "medium" as const, updatedAt: new Date("2026-10-25T12:00:00.000Z") },
      { id: doneId, companyId, title: "Terminal live run", status: "done" as const, priority: "medium" as const },
      { id: otherId, companyId: otherCompanyId, title: "Other tenant issue", status: "todo" as const, priority: "medium" as const },
    ]);
    await db.insert(heartbeatRuns).values([
      { companyId, agentId, status: "queued", contextSnapshot: { taskId: liveId } },
      { companyId, agentId, status: "running", contextSnapshot: { issueId: doneId } },
      { companyId, agentId, status: "running", contextSnapshot: { issueId: otherId, taskId: liveId } },
      { companyId, agentId, status: "succeeded", contextSnapshot: { issueId: otherId } },
      { companyId: otherCompanyId, agentId, status: "running", contextSnapshot: { issueId: liveId } },
    ]);
    const app = createApp(companyId);
    const base = `/api/companies/${companyId}/issues?view=compact&limit=50&sortField=updated&sortDir=desc`;
    expect((await request(app).get(base).expect(200)).body.map((row: { id: string }) => row.id)).not.toContain(liveId);
    expect((await request(app).get(`${base}&liveOnly=true`).expect(200)).body.map((row: { id: string }) => row.id)).toEqual([liveId]);
    expect(await issueService(db).count(companyId, { liveOnly: true })).toBe(1);
    await request(app).get(`${base}&liveOnly=invalid`).expect(400);
    await request(app).get(`/api/companies/${companyId}/issues/count?attention=blocked&liveOnly=invalid`).expect(400);
  });

  it("marks a required successful-run handoff live while a run targets the issue", async () => {
    const companyId = randomUUID();
    const agentId = randomUUID();
    const issueId = randomUUID();
    const runId = randomUUID();

    await db.insert(companies).values({
      id: companyId,
      name: "Paperclip",
      issuePrefix: uniqueIssuePrefix(),
      requireBoardApprovalForNewAgents: false,
    });
    await seedCloudTenantMember(companyId);
    await db.insert(agents).values({
      id: agentId,
      companyId,
      name: "Assignee",
      role: "engineer",
      status: "active",
      adapterType: "codex_local",
      adapterConfig: {},
      runtimeConfig: {},
      permissions: {},
    });
    await db.insert(issues).values({
      id: issueId,
      companyId,
      title: "Live handoff issue",
      status: "in_progress",
      priority: "medium",
      assigneeAgentId: agentId,
    });
    await db.insert(activityLog).values({
      companyId,
      actorType: "system",
      actorId: "system",
      action: "issue.successful_run_handoff_required",
      entityType: "issue",
      entityId: issueId,
      agentId,
      details: { sourceRunId: randomUUID() },
    });
    await db.insert(heartbeatRuns).values({
      id: runId,
      companyId,
      agentId,
      status: "running",
      contextSnapshot: { taskId: issueId },
    });

    const app = createApp(companyId);
    const res = await request(app)
      .get(`/api/companies/${companyId}/issues`)
      .query({ view: "compact", limit: "20" });

    expect(res.status, JSON.stringify(res.body)).toBe(200);
    expect(res.body[0]?.successfulRunHandoff).toMatchObject({
      state: "required",
      required: true,
      hasLiveContinuation: true,
      liveRunId: runId,
    });
  });

  it("marks an escalated successful-run handoff live while a run targets the issue", async () => {
    const companyId = randomUUID();
    const agentId = randomUUID();
    const issueId = randomUUID();
    const runId = randomUUID();

    await db.insert(companies).values({
      id: companyId,
      name: "Paperclip",
      issuePrefix: uniqueIssuePrefix(),
      requireBoardApprovalForNewAgents: false,
    });
    await seedCloudTenantMember(companyId);
    await db.insert(agents).values({
      id: agentId,
      companyId,
      name: "Assignee",
      role: "engineer",
      status: "active",
      adapterType: "codex_local",
      adapterConfig: {},
      runtimeConfig: {},
      permissions: {},
    });
    await db.insert(issues).values({
      id: issueId,
      companyId,
      title: "Escalated handoff issue",
      status: "in_progress",
      priority: "medium",
      assigneeAgentId: agentId,
    });
    await db.insert(activityLog).values({
      companyId,
      actorType: "system",
      actorId: "system",
      action: "issue.successful_run_handoff_escalated",
      entityType: "issue",
      entityId: issueId,
      agentId,
      details: { sourceRunId: randomUUID() },
    });
    await db.insert(heartbeatRuns).values({
      id: runId,
      companyId,
      agentId,
      status: "running",
      contextSnapshot: { taskId: issueId },
    });

    const app = createApp(companyId);
    const res = await request(app)
      .get(`/api/companies/${companyId}/issues`)
      .query({ view: "compact", limit: "20" });

    expect(res.status, JSON.stringify(res.body)).toBe(200);
    expect(res.body[0]?.successfulRunHandoff).toMatchObject({
      state: "escalated",
      required: false,
      hasLiveContinuation: true,
      liveRunId: runId,
    });
  });

  it("logs resolved when a valid-path skip closes a stale required handoff", async () => {
    const companyId = randomUUID();
    const agentId = randomUUID();
    const issueId = randomUUID();
    const resolverRunId = randomUUID();
    const sourceRunId = randomUUID();

    await db.insert(companies).values({
      id: companyId,
      name: "Paperclip",
      issuePrefix: uniqueIssuePrefix(),
      requireBoardApprovalForNewAgents: false,
    });
    await db.insert(agents).values({
      id: agentId,
      companyId,
      name: "Assignee",
      role: "engineer",
      status: "active",
      adapterType: "codex_local",
      adapterConfig: {},
      runtimeConfig: {},
      permissions: {},
    });
    await db.insert(heartbeatRuns).values({
      id: resolverRunId,
      companyId,
      agentId,
      status: "succeeded",
      contextSnapshot: { issueId },
    });
    await db.insert(issues).values({
      id: issueId,
      companyId,
      identifier: `${uniqueIssuePrefix()}-1`,
      title: "Stale handoff",
      status: "in_progress",
      priority: "medium",
      assigneeAgentId: agentId,
    });
    await db.insert(activityLog).values({
      companyId,
      actorType: "system",
      actorId: "heartbeat",
      action: "issue.successful_run_handoff_required",
      entityType: "issue",
      entityId: issueId,
      agentId,
      details: { sourceRunId },
      createdAt: new Date("2026-07-01T00:00:00.000Z"),
    });

    await expect(resolveRequiredSuccessfulRunHandoffOnValidPath(db, {
      companyId,
      issueId,
      issueIdentifier: "PAP-1",
      agentId,
      runId: resolverRunId,
      skipReason: "persisted issue monitor owns the next action",
    })).resolves.toBe(true);

    const resolved = await db
      .select()
      .from(activityLog)
      .where(eq(activityLog.entityId, issueId))
      .then((rows) => rows.find((row) => row.action === "issue.successful_run_handoff_resolved"));
    expect(resolved).toMatchObject({
      runId: resolverRunId,
      details: {
        sourceRunId,
        resolvedByRunId: resolverRunId,
        resolvedBySkipReason: "persisted issue monitor owns the next action",
      },
    });
  });

  it("returns 304 for unchanged compact issue list ETags", async () => {
    const companyId = randomUUID();
    const issueId = randomUUID();

    await db.insert(companies).values({
      id: companyId,
      name: "Paperclip",
      issuePrefix: uniqueIssuePrefix(),
      requireBoardApprovalForNewAgents: false,
    });
    await seedCloudTenantMember(companyId);
    await db.insert(issues).values({
      id: issueId,
      companyId,
      title: "Cached compact issue",
      status: "todo",
      priority: "medium",
    });

    const app = createApp(companyId);
    const first = await request(app)
      .get(`/api/companies/${companyId}/issues`)
      .query({ view: "compact", limit: "20" });
    expect(first.status, JSON.stringify(first.body)).toBe(200);
    expect(first.headers.etag).toBeTruthy();

    const second = await request(app)
      .get(`/api/companies/${companyId}/issues`)
      .query({ view: "compact", limit: "20" })
      .set("If-None-Match", first.headers.etag);

    expect(second.status).toBe(304);
    expect(second.text).toBe("");
  });

  it("coalesces simultaneous identical compact issue-list requests into one service computation", async () => {
    const companyId = randomUUID();
    const issueId = randomUUID();
    let computeCount = 0;

    await db.insert(companies).values({
      id: companyId,
      name: "Paperclip",
      issuePrefix: uniqueIssuePrefix(),
      requireBoardApprovalForNewAgents: false,
    });
    await seedCloudTenantMember(companyId);
    await db.insert(issues).values({
      id: issueId,
      companyId,
      title: "Coalesced issue",
      status: "todo",
      priority: "medium",
    });

    const app = createApp(companyId, {
      issueListDiagnostics: {
        async onComputeStart() {
          computeCount += 1;
          await new Promise((resolve) => setTimeout(resolve, 50));
        },
      },
    });
    const responses = await Promise.all(Array.from({ length: 10 }, () =>
      request(app)
        .get(`/api/companies/${companyId}/issues`)
        .query({ view: "compact", limit: "20" })
    ));

    expect(responses.every((res) => res.status === 200)).toBe(true);
    expect(responses.map((res) => res.body.map((issue: { id: string }) => issue.id))).toEqual(
      Array.from({ length: 10 }, () => [issueId]),
    );
    expect(computeCount).toBe(1);
    expect(responses.some((res) => res.headers["x-paperclip-request-cache"] === "coalesced")).toBe(true);
  });

  it("keeps compact issue-list cache keys separated by board user identity", async () => {
    const companyId = randomUUID();
    const issueId = randomUUID();
    let computeCount = 0;

    await db.insert(companies).values({
      id: companyId,
      name: "Paperclip",
      issuePrefix: uniqueIssuePrefix(),
      requireBoardApprovalForNewAgents: false,
    });
    await seedCloudTenantMember(companyId, "cloud-user-1");
    await seedCloudTenantMember(companyId, "cloud-user-2");
    await db.insert(issues).values({
      id: issueId,
      companyId,
      title: "Separated issue",
      status: "todo",
      priority: "medium",
    });

    const app = createApp(companyId, {
      issueListDiagnostics: {
        async onComputeStart() {
          computeCount += 1;
          await new Promise((resolve) => setTimeout(resolve, 40));
        },
      },
    });
    const [first, second] = await Promise.all([
      request(app)
        .get(`/api/companies/${companyId}/issues`)
        .set("X-Test-User-Id", "cloud-user-1")
        .query({ view: "compact", limit: "20" }),
      request(app)
        .get(`/api/companies/${companyId}/issues`)
        .set("X-Test-User-Id", "cloud-user-2")
        .query({ view: "compact", limit: "20" }),
    ]);

    expect(first.status, JSON.stringify(first.body)).toBe(200);
    expect(second.status, JSON.stringify(second.body)).toBe(200);
    expect(computeCount).toBe(2);
    expect(first.headers["x-paperclip-request-cache"]).toBe("miss");
    expect(second.headers["x-paperclip-request-cache"]).toBe("miss");
  });

  it("serves repeated compact issue-list requests from the short server cache", async () => {
    const companyId = randomUUID();
    const issueId = randomUUID();
    let computeCount = 0;

    await db.insert(companies).values({
      id: companyId,
      name: "Paperclip",
      issuePrefix: uniqueIssuePrefix(),
      requireBoardApprovalForNewAgents: false,
    });
    await seedCloudTenantMember(companyId);
    await db.insert(issues).values({
      id: issueId,
      companyId,
      title: "Cached issue",
      status: "todo",
      priority: "medium",
    });

    const app = createApp(companyId, {
      issueListDiagnostics: {
        onComputeStart() {
          computeCount += 1;
        },
      },
    });
    const first = await request(app)
      .get(`/api/companies/${companyId}/issues`)
      .query({ view: "compact", limit: "20" });
    const second = await request(app)
      .get(`/api/companies/${companyId}/issues`)
      .query({ view: "compact", limit: "20" });

    expect(first.status, JSON.stringify(first.body)).toBe(200);
    expect(second.status, JSON.stringify(second.body)).toBe(200);
    expect(computeCount).toBe(1);
    expect(first.headers["x-paperclip-request-cache"]).toBe("miss");
    expect(second.headers["x-paperclip-request-cache"]).toBe("hit");
  });

  it("bounds compact issue-list server cache entries", async () => {
    const companyId = randomUUID();
    const issueId = randomUUID();

    await db.insert(companies).values({
      id: companyId,
      name: "Paperclip",
      issuePrefix: uniqueIssuePrefix(),
      requireBoardApprovalForNewAgents: false,
    });
    await seedCloudTenantMember(companyId);
    await db.insert(issues).values({
      id: issueId,
      companyId,
      title: "Bounded cache issue",
      status: "todo",
      priority: "medium",
    });

    const app = createApp(companyId);
    for (let index = 0; index < ISSUE_LIST_SERVER_CACHE_MAX_ENTRIES + 5; index += 1) {
      const res = await request(app)
        .get(`/api/companies/${companyId}/issues`)
        .query({ view: "compact", limit: "20", q: `cache-key-${index}` });
      expect(res.status, JSON.stringify(res.body)).toBe(200);
    }

    const cacheSize = __getIssueListResponseCacheSizeForTests();
    // Entries may expire during 261 HTTP requests; the invariant is an upper bound.
    expect(cacheSize).toBeGreaterThan(0);
    expect(cacheSize).toBeLessThanOrEqual(ISSUE_LIST_SERVER_CACHE_MAX_ENTRIES);
    const last = await request(app)
      .get(`/api/companies/${companyId}/issues`)
      .query({ view: "compact", limit: "20", q: `cache-key-${ISSUE_LIST_SERVER_CACHE_MAX_ENTRIES + 4}` });
    expect(last.headers["x-paperclip-request-cache"]).toBe("hit");
  });

  it("logs request_storm_detected for identical in-flight compact issue-list fanout without query values", async () => {
    const companyId = randomUUID();
    const issueId = randomUUID();
    const stormEvents: unknown[] = [];

    await db.insert(companies).values({
      id: companyId,
      name: "Paperclip",
      issuePrefix: uniqueIssuePrefix(),
      requireBoardApprovalForNewAgents: false,
    });
    await seedCloudTenantMember(companyId);
    await db.insert(issues).values({
      id: issueId,
      companyId,
      title: "Storm issue",
      status: "todo",
      priority: "medium",
    });

    const app = createApp(companyId, {
      issueListDiagnostics: {
        async onComputeStart() {
          await new Promise((resolve) => setTimeout(resolve, 50));
        },
        onStormDetected(event) {
          stormEvents.push(event);
        },
      },
    });
    const responses = await Promise.all(Array.from({ length: 5 }, () =>
      request(app)
        .get(`/api/companies/${companyId}/issues`)
        .set("Referer", "http://localhost:3100/issues?q=do-not-log-this")
        .set("X-Paperclip-Tab-Visible", "visible")
        .query({ view: "compact", limit: "20", q: "do-not-log-this" })
    ));

    expect(responses.every((res) => res.status === 200)).toBe(true);
    expect(stormEvents).toHaveLength(1);
    expect(stormEvents[0]).toMatchObject({
      event: "request_storm_detected",
      route: "GET /api/companies/:companyId/issues",
      companyId,
      visibilityHint: "visible",
      referer: "/issues",
    });
    expect((stormEvents[0] as { queryKeys: string[] }).queryKeys).toEqual(
      expect.arrayContaining(["limit", "q", "view"]),
    );
    expect(JSON.stringify(stormEvents[0])).not.toContain("do-not-log-this");
  });

  it("keeps UUID assignee filtering behavior unchanged", async () => {
    const companyId = randomUUID();
    const assigneeAgentId = randomUUID();
    const otherAgentId = randomUUID();
    const assignedIssueId = randomUUID();
    const otherIssueId = randomUUID();

    await db.insert(companies).values({
      id: companyId,
      name: "Paperclip",
      issuePrefix: uniqueIssuePrefix(),
      requireBoardApprovalForNewAgents: false,
    });
    await seedCloudTenantMember(companyId);
    await db.insert(agents).values([
      {
        id: assigneeAgentId,
        companyId,
        name: "Assignee",
        role: "engineer",
        status: "active",
        adapterType: "codex_local",
        adapterConfig: {},
        runtimeConfig: {},
        permissions: {},
      },
      {
        id: otherAgentId,
        companyId,
        name: "Other",
        role: "engineer",
        status: "active",
        adapterType: "codex_local",
        adapterConfig: {},
        runtimeConfig: {},
        permissions: {},
      },
    ]);
    await db.insert(issues).values([
      {
        id: assignedIssueId,
        companyId,
        title: "Assigned issue",
        status: "todo",
        priority: "medium",
        assigneeAgentId,
      },
      {
        id: otherIssueId,
        companyId,
        title: "Other issue",
        status: "todo",
        priority: "medium",
        assigneeAgentId: otherAgentId,
      },
    ]);

    const app = createApp(companyId);
    const res = await request(app)
      .get(`/api/companies/${companyId}/issues`)
      .query({ status: "todo", assigneeAgentId, limit: "20" });

    expect(res.status, JSON.stringify(res.body)).toBe(200);
    expect(res.body.map((issue: { id: string }) => issue.id)).toEqual([assignedIssueId]);
  });

  it("returns 422 for malformed assigneeAgentId filters", async () => {
    const companyId = randomUUID();
    await db.insert(companies).values({
      id: companyId,
      name: "Paperclip",
      issuePrefix: uniqueIssuePrefix(),
      requireBoardApprovalForNewAgents: false,
    });
    await seedCloudTenantMember(companyId);

    const app = createApp(companyId);
    const res = await request(app)
      .get(`/api/companies/${companyId}/issues`)
      .query({ status: "todo", assigneeAgentId: "bad", limit: "20" });

    expect(res.status).toBe(422);
    expect(res.body).toMatchObject({
      error: "assigneeAgentId must be a UUID or 'null'",
    });
  });

  it("returns opt-in live descendant counts for offscreen live descendants only", async () => {
    const companyId = randomUUID();
    const otherCompanyId = randomUUID();
    const agentId = randomUUID();
    const otherAgentId = randomUUID();
    const rootIssueId = randomUUID();
    const offPageBlockedId = randomUUID();
    const childIssueId = randomUUID();
    const grandchildIssueId = randomUUID();
    const hiddenChildIssueId = randomUUID();
    const crossCompanyChildIssueId = randomUUID();
    const rootRunId = randomUUID();
    const grandchildRunId = randomUUID();
    const hiddenRunId = randomUUID();
    const crossCompanyRunId = randomUUID();

    await db.insert(companies).values([
      {
        id: companyId,
        name: "Paperclip",
        issuePrefix: uniqueIssuePrefix(),
        requireBoardApprovalForNewAgents: false,
      },
      {
        id: otherCompanyId,
        name: "Other Company",
        issuePrefix: uniqueIssuePrefix(),
        requireBoardApprovalForNewAgents: false,
      },
    ]);
    await seedCloudTenantMember(companyId);
    await db.insert(agents).values([
      {
        id: agentId,
        companyId,
        name: "Assignee",
        role: "engineer",
        status: "active",
        adapterType: "codex_local",
        adapterConfig: {},
        runtimeConfig: {},
        permissions: {},
      },
      {
        id: otherAgentId,
        companyId: otherCompanyId,
        name: "Other",
        role: "engineer",
        status: "active",
        adapterType: "codex_local",
        adapterConfig: {},
        runtimeConfig: {},
        permissions: {},
      },
    ]);
    await db.insert(heartbeatRuns).values([
      {
        id: rootRunId,
        companyId,
        agentId,
        status: "running",
        contextSnapshot: { issueId: rootIssueId },
      },
      {
        id: grandchildRunId,
        companyId,
        agentId,
        status: "queued",
        contextSnapshot: { issueId: grandchildIssueId },
      },
      {
        id: hiddenRunId,
        companyId,
        agentId,
        status: "running",
        contextSnapshot: { issueId: hiddenChildIssueId },
      },
      {
        id: crossCompanyRunId,
        companyId: otherCompanyId,
        agentId: otherAgentId,
        status: "running",
        contextSnapshot: { issueId: crossCompanyChildIssueId },
      },
    ]);
    await db.insert(issues).values([
      {
        id: rootIssueId,
        companyId,
        title: "Blocked parent",
        status: "blocked",
        priority: "critical",
        executionRunId: rootRunId,
        assigneeAgentId: agentId,
      },
      {
        id: childIssueId,
        companyId,
        title: "Offscreen child",
        status: "todo",
        priority: "medium",
        parentId: rootIssueId,
        assigneeAgentId: agentId,
      },
      {
        id: grandchildIssueId,
        companyId,
        title: "Offscreen live grandchild (context-only run)",
        status: "todo",
        priority: "medium",
        parentId: childIssueId,
        // The live run carries issueId, but the issue has no executionRunId.
        // The target-seeded traversal must retain that fallback.
        assigneeAgentId: agentId,
      },
      {
        id: hiddenChildIssueId,
        companyId,
        title: "Hidden live child",
        status: "todo",
        priority: "medium",
        parentId: rootIssueId,
        executionRunId: hiddenRunId,
        hiddenAt: new Date("2026-07-02T00:00:00.000Z"),
        assigneeAgentId: agentId,
      },
      {
        id: crossCompanyChildIssueId,
        companyId: otherCompanyId,
        title: "Cross-company live child",
        status: "todo",
        priority: "medium",
        parentId: rootIssueId,
        executionRunId: crossCompanyRunId,
        assigneeAgentId: otherAgentId,
      },
    ]);

    const app = createApp(companyId);
    const withoutSummary = await request(app)
      .get(`/api/companies/${companyId}/issues`)
      .query({ status: "blocked", limit: "20" });

    expect(withoutSummary.status, JSON.stringify(withoutSummary.body)).toBe(200);
    expect(withoutSummary.body).toHaveLength(1);
    expect(withoutSummary.body[0].id).toBe(rootIssueId);
    expect(withoutSummary.body[0].liveDescendantCount).toBeUndefined();

    await db.insert(issues).values({
      id: offPageBlockedId,
      companyId,
      title: "Older blocked issue outside selected page",
      status: "blocked",
      priority: "low",
      updatedAt: new Date("2020-01-01T00:00:00.000Z"),
      assigneeAgentId: agentId,
    });
    const executeSpy = vi.spyOn(db, "execute");
    const descendantQueries = () => executeSpy.mock.calls
      .map(([statement]) => new PgDialect().sqlToQuery(statement))
      .filter(({ sql: text }) => text.includes("target_issues(issue_id)"));
    const withSummary = await request(app)
      .get(`/api/companies/${companyId}/issues`)
      .query({ status: "blocked", includeLiveDescendantSummary: "true", limit: "1" });
    expect(descendantQueries()).toHaveLength(1);
    expect(descendantQueries()[0]!.params).toContain(rootIssueId);
    expect(descendantQueries()[0]!.params).not.toContain(offPageBlockedId);
    executeSpy.mockClear();
    const emptyPage = await request(app)
      .get(`/api/companies/${companyId}/issues`)
      .query({ status: "blocked", includeLiveDescendantSummary: "true", limit: "1", offset: "2" });
    expect(emptyPage.status).toBe(200);
    expect(emptyPage.body).toEqual([]);
    expect(descendantQueries()).toHaveLength(0);
    executeSpy.mockRestore();

    expect(withSummary.status, JSON.stringify(withSummary.body)).toBe(200);
    expect(withSummary.body).toHaveLength(1);
    expect(withSummary.body[0]).toMatchObject({
      id: rootIssueId,
      liveDescendantCount: 1,
    });
  });

  it("does not recurse forever when live descendant summaries encounter a parent cycle", async () => {
    const companyId = randomUUID();
    const agentId = randomUUID();
    const parentIssueId = randomUUID();
    const childIssueId = randomUUID();
    const runId = randomUUID();

    await db.insert(companies).values({
      id: companyId,
      name: "Paperclip",
      issuePrefix: uniqueIssuePrefix(),
      requireBoardApprovalForNewAgents: false,
    });
    await seedCloudTenantMember(companyId);
    await db.insert(agents).values({
      id: agentId,
      companyId,
      name: "Assignee",
      role: "engineer",
      status: "active",
      adapterType: "codex_local",
      adapterConfig: {},
      runtimeConfig: {},
      permissions: {},
    });
    await db.insert(heartbeatRuns).values({
      id: runId,
      companyId,
      agentId,
      status: "running",
      contextSnapshot: { issueId: childIssueId },
    });
    await db.insert(issues).values([
      {
        id: parentIssueId,
        companyId,
        title: "Cycle parent",
        status: "blocked",
        priority: "medium",
        parentId: childIssueId,
        assigneeAgentId: agentId,
      },
      {
        id: childIssueId,
        companyId,
        title: "Cycle live child",
        status: "in_progress",
        priority: "medium",
        parentId: parentIssueId,
        executionRunId: runId,
        assigneeAgentId: agentId,
      },
    ]);

    const app = createApp(companyId);
    const res = await request(app)
      .get(`/api/companies/${companyId}/issues`)
      .query({ status: "blocked", includeLiveDescendantSummary: "true", limit: "20" });

    expect(res.status, JSON.stringify(res.body)).toBe(200);
    expect(res.body).toHaveLength(1);
    expect(res.body[0]).toMatchObject({
      id: parentIssueId,
      liveDescendantCount: 1,
    });
  });
});
