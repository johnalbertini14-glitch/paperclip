import { randomUUID } from "node:crypto";
import { describe, expect, it, beforeAll, afterAll } from "vitest";
import { agents, companies, createDb, heartbeatRunEvents, heartbeatRuns, issues } from "@paperclipai/db";
import {
  getEmbeddedPostgresTestSupport,
  startEmbeddedPostgresTestDatabase,
} from "../__tests__/helpers/embedded-postgres.js";
import { attentionService } from "./attention.js";

// The attention feed builds one newest-run lookup per feed build. Keying that
// lookup by every company run since the oldest exhausted run detoasts the whole
// context_snapshot column on each build (measured 4.9s on a 143k-run company),
// and runRetentionSweep runs it every scheduler tick. These tests pin that the
// lookup is scoped to the ids the failed rows actually resolve to, and that
// scoping does not change which failed rows the feed emits.
const support = await getEmbeddedPostgresTestSupport();
(support.supported ? describe : describe.skip)("attention failed-run newer-run lookup scope", () => {
  let database: Awaited<ReturnType<typeof startEmbeddedPostgresTestDatabase>>;
  let db: ReturnType<typeof createDb>;
  let companyId: string;
  let agentId: string;
  let trackedSql: { text: string; params: unknown[] }[] = [];
  let failedIssueIds: string[] = [];
  let originalUnsafe: unknown;

  const captureSql = (client: unknown) => {
    const unsafe = (client as { unsafe?: unknown }).unsafe;
    if (typeof unsafe !== "function") throw new Error("postgres client exposes no unsafe()");
    (client as { unsafe: unknown }).unsafe = function patchedUnsafe(this: unknown, ...args: unknown[]) {
      if (typeof args[0] === "string") {
        trackedSql.push({ text: args[0], params: Array.isArray(args[1]) ? (args[1] as unknown[]) : [] });
      }
      return (unsafe as (...inner: unknown[]) => unknown).apply(this, args);
    };
  };

  // The newest-run lookup is the only feed query that reads a projected
  // context_snapshot id of a run that is not itself exhausted.
  const newerRunQueries = () => trackedSql.filter(({ text }) =>
    text.includes('"heartbeat_runs"')
    && text.includes("->> 'issueId'")
    && !text.includes('"heartbeat_run_events"'));

  beforeAll(async () => {
    database = await startEmbeddedPostgresTestDatabase("attention-newer-run-scope-");
    db = createDb(database.connectionString);
    const driver = (db as unknown as { $client: unknown }).$client;
    originalUnsafe = (driver as { unsafe: unknown }).unsafe;
    captureSql(driver);

    companyId = randomUUID();
    agentId = randomUUID();
    await db.insert(companies).values({ id: companyId, name: "Attention scope", issuePrefix: "ATTN" });
    await db.insert(agents).values({
      id: agentId,
      companyId,
      name: "Scope agent",
      role: "engineer",
      adapterType: "paperclip_runner",
    });

    const issueA = randomUUID();
    const issueB = randomUUID();
    // The failed run's resolved key is the only id the scoped lookup may bind.
    failedIssueIds = [issueA];
    for (const [id, title] of [[issueA, "Scope issue A"], [issueB, "Scope issue B"]] as const) {
      await db.insert(issues).values({ id, companyId, title, status: "in_progress", assigneeAgentId: agentId });
    }

    // Failed run for issue A: exhausted, so it must reach the feed.
    const failedRunId = randomUUID();
    await db.insert(heartbeatRuns).values({
      id: failedRunId,
      companyId,
      agentId,
      status: "failed",
      contextSnapshot: { issueId: issueA },
      createdAt: new Date("2026-01-01T00:00:00.000Z"),
    });
    await db.insert(heartbeatRunEvents).values({
      companyId,
      runId: failedRunId,
      agentId,
      seq: 1,
      eventType: "lifecycle",
      message: "Bounded retry exhausted after 3 attempts",
    });

    // A newer run on issue B is not a failed row's key: it must not be scanned
    // into the lookup, and it must not suppress any failed row.
    await db.insert(heartbeatRuns).values({
      id: randomUUID(),
      companyId,
      agentId,
      status: "succeeded",
      contextSnapshot: { issueId: issueB },
      createdAt: new Date("2026-01-02T00:00:00.000Z"),
    });

    // A newer run on issue A, for a different agent: same key semantics as the
    // failed row's own key but not this agent, so the failed row still surfaces.
    const otherAgentId = randomUUID();
    await db.insert(agents).values({
      id: otherAgentId,
      companyId,
      name: "Other agent",
      role: "engineer",
      adapterType: "paperclip_runner",
    });
    await db.insert(heartbeatRuns).values({
      id: randomUUID(),
      companyId,
      agentId: otherAgentId,
      status: "succeeded",
      contextSnapshot: { issueId: issueA },
      createdAt: new Date("2026-01-03T00:00:00.000Z"),
    });
  }, 60_000);

  afterAll(async () => {
    const driver = (db as unknown as { $client: unknown }).$client;
    if (driver && originalUnsafe) (driver as { unsafe: unknown }).unsafe = originalUnsafe;
    await database?.cleanup();
  });

  it("scopes the newest-run lookup to the failed runs' issue/task ids", async () => {
    trackedSql = [];
    await attentionService(db as never).list(companyId, { includeDismissed: true, all: true, allowUnscopedAll: true });

    const scoped = newerRunQueries();
    expect(scoped.length).toBeGreaterThan(0);
    for (const { text, params } of scoped) {
      // Each id column is filtered, so the lookup stays answerable by the
      // company_ctx_issue/company_ctx_task indexes instead of detoasting every
      // company run since the oldest exhausted run.
      expect(text).toMatch(/->>\s*'issueId'\s+in\s*\(/i);
      expect(text).toMatch(/->>\s*'taskId'\s+in\s*\(/i);
      // The agent/time filters stay in place.
      expect(text).toMatch(/"agent_id" in \(/i);
      expect(text).toMatch(/"created_at" >/i);
      // The scoped ids are bound parameters, and they are exactly the failed
      // runs' resolved keys.
      const bound = params.filter((value): value is string => typeof value === "string");
      for (const issueId of failedIssueIds) expect(bound).toContain(issueId);
    }
  }, 30_000);

  it("keeps the failed row in the feed and does not let an unrelated newer run suppress it", async () => {
    const feed = await attentionService(db as never).list(companyId, {
      includeDismissed: true,
      all: true,
      allowUnscopedAll: true,
    });
    const failedRunItems = feed.items.filter((item) => item.sourceKind === "failed_run");
    expect(failedRunItems).toHaveLength(1);
    expect(failedRunItems[0]!.subject.kind).toBe("run");
  }, 30_000);

  it("review: null failed key must not admit unrelated nonempty keys", async () => {
    const id = randomUUID();
    await db.insert(heartbeatRuns).values({id, companyId, agentId, status: "failed", contextSnapshot: {}, createdAt: new Date("2026-01-01T00:00:00.000Z")});
    await db.insert(heartbeatRunEvents).values({companyId, runId:id, agentId, seq:1, eventType:"lifecycle", message:"Bounded retry exhausted after 3 attempts"});
    trackedSql = [];
    await attentionService(db as never).list(companyId, {includeDismissed:true, all:true, allowUnscopedAll:true});
    const query = newerRunQueries()[0]!;
    const rows = await (db as any).$client.unsafe(query.text, query.params);
    console.log("REVIEW_QUERY", query.text);
    console.log("REVIEW_ROWS", JSON.stringify(rows));
    const unrelated = rows.filter((r: any) => { const key = r["?column?"]; return key; });
    // Existing fixture has only one newer run for this agent: issue B.
    // No newer run matches failed issue A or the newly added null key.
    expect(rows).toHaveLength(0);
  }, 30_000);
});
