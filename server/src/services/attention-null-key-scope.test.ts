import { randomUUID } from "node:crypto";
import { describe, expect, it, beforeAll, afterAll } from "vitest";
import { agents, companies, createDb, heartbeatRunEvents, heartbeatRuns, issues } from "@paperclipai/db";
import {
  getEmbeddedPostgresTestSupport,
  startEmbeddedPostgresTestDatabase,
} from "../__tests__/helpers/embedded-postgres.js";
import { attentionService } from "./attention.js";

// Regression for the null-key branch of the scoped newest-run lookup.
//
// readRunIssueId reads issueId, falls back to taskId only when issueId is
// absent, and keys any leftover empty string as the null key. A failed run
// whose context carries neither id is keyed `${agentId}:`, so the lookup may
// read that key back, and a newer run that resolves to the same null key must
// suppress it. But a newer run carrying a real issue id or a real task id
// resolves to that id's own key: it belongs to no failed key and must not be
// admitted, or the lookup reverts to reading every company run again.
//
// Fixture: one exhausted failed run per failed key (issue A, and one with no
// ids at all), plus newer runs for the same agent that are either unrelated
// ids or the legitimate null key.
const support = await getEmbeddedPostgresTestSupport();
(support.supported ? describe : describe.skip)("attention newest-run lookup null-key scope", () => {
  let database: Awaited<ReturnType<typeof startEmbeddedPostgresTestDatabase>>;
  let db: ReturnType<typeof createDb>;
  let companyId: string;
  let agentId: string;
  let trackedSql: { text: string; params: unknown[] }[] = [];
  let originalUnsafe: unknown;

  let issueAId = "";
  let issueOnlyRunCreatedAt!: Date;
  let taskOnlyRunCreatedAt!: Date;
  let nullKeyRunCreatedAt!: Date;
  let nullKeyFailedRunId = "";

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

  const newerRunQueries = () => trackedSql.filter(({ text }) =>
    text.includes('"heartbeat_runs"')
    && text.includes("->> 'issueId'")
    && !text.includes('"heartbeat_run_events"'));

  const exhaustedRun = async (contextSnapshot: Record<string, unknown>, createdAt: Date) => {
    const runId = randomUUID();
    await db.insert(heartbeatRuns).values({ id: runId, companyId, agentId, status: "failed", contextSnapshot, createdAt });
    await db.insert(heartbeatRunEvents).values({
      companyId,
      runId,
      agentId,
      seq: 1,
      eventType: "lifecycle",
      message: "Bounded retry exhausted after 3 attempts",
    });
    return runId;
  };

  beforeAll(async () => {
    database = await startEmbeddedPostgresTestDatabase("attention-null-key-scope-");
    db = createDb(database.connectionString);
    const driver = (db as unknown as { $client: unknown }).$client;
    originalUnsafe = (driver as { unsafe: unknown }).unsafe;
    captureSql(driver);

    companyId = randomUUID();
    agentId = randomUUID();
    await db.insert(companies).values({ id: companyId, name: "Attention null-key scope", issuePrefix: "ATTN" });
    await db.insert(agents).values({ id: agentId, companyId, name: "Null-key agent", role: "engineer", adapterType: "paperclip_runner" });

    issueAId = randomUUID();
    await db.insert(issues).values({ id: issueAId, companyId, title: "Null-key scope issue", status: "in_progress", assigneeAgentId: agentId });

    // Two failed keys for this agent: one that resolves to an id, one that
    // resolves to null. The null branch is only reachable because of the second.
    await exhaustedRun({ issueId: issueAId }, new Date("2026-01-01T00:00:00.000Z"));
    nullKeyFailedRunId = await exhaustedRun({}, new Date("2026-01-01T00:00:00.000Z"));

    // Unrelated newer run carrying an issue id: resolves to its own key, so it
    // is neither admitted nor able to suppress either failed row.
    issueOnlyRunCreatedAt = new Date("2026-01-02T00:00:00.000Z");
    await db.insert(heartbeatRuns).values({
      id: randomUUID(),
      companyId,
      agentId,
      status: "succeeded",
      contextSnapshot: { issueId: randomUUID() },
      createdAt: issueOnlyRunCreatedAt,
    });

    // Unrelated newer run carrying only a task id: readRunIssueId falls back to
    // taskId, so this resolves to that task's key, not to the null key.
    taskOnlyRunCreatedAt = new Date("2026-01-03T00:00:00.000Z");
    await db.insert(heartbeatRuns).values({
      id: randomUUID(),
      companyId,
      agentId,
      status: "succeeded",
      contextSnapshot: { taskId: randomUUID() },
      createdAt: taskOnlyRunCreatedAt,
    });

    // Legitimate null key: a newer run with no ids keys `${agentId}:`, the same
    // key as the null-key failed run, so it must suppress that failed row.
    nullKeyRunCreatedAt = new Date("2026-01-04T00:00:00.000Z");
    await db.insert(heartbeatRuns).values({
      id: randomUUID(),
      companyId,
      agentId,
      status: "succeeded",
      contextSnapshot: {},
      createdAt: nullKeyRunCreatedAt,
    });
  }, 60_000);

  afterAll(async () => {
    const driver = (db as unknown as { $client: unknown }).$client;
    if (driver && originalUnsafe) (driver as { unsafe: unknown }).unsafe = originalUnsafe;
    await database?.cleanup();
  });

  it("emits a null branch that requires the projected key to resolve to null", async () => {
    trackedSql = [];
    await attentionService(db as never).list(companyId, { includeDismissed: true, all: true, allowUnscopedAll: true });

    const scoped = newerRunQueries();
    expect(scoped.length).toBeGreaterThan(0);
    for (const { text } of scoped) {
      // The indexable branches stay, so the company/context/created_at indexes
      // can still answer the lookup.
      expect(text).toMatch(/->>\s*'issueId'\s+in\s*\(/i);
      expect(text).toMatch(/->>\s*'taskId'\s+in\s*\(/i);
      expect(text).toMatch(/"agent_id" in \(/i);
      expect(text).toMatch(/"created_at" >/i);
      // The null branch may only admit a row whose own projected ids resolve to
      // the null key: issueId empty, or issueId absent with taskId absent or
      // empty. A bare "issueId is null or ..." sibling disjunct admits every
      // issueId-only and taskId-only run in the company, which is the defect
      // this branch previously had.
      expect(text).toMatch(/->>\s*'issueId'\s*=\s*''\s+or\s+\(\s*.*->>\s*'issueId'\s+is\s+null\s+and\s+\(.*->>\s*'taskId'\s+is\s+null\s+or\s+.*->>\s*'taskId'\s*=\s*''\s*\)\s*\)/i);
      // readRunIssueId falls back to taskId only when issueId is absent, so the
      // issueId-null test is only ever reachable together with an empty taskId.
      expect(text).not.toMatch(/->>\s*'issueId'\s+is\s+null\s+or/i);
      // The taskId-null disjunct itself is required (it is what makes an
      // issueId-less, taskId-less row resolve to null), so it is pinned as
      // nested under the issueId guard rather than banned outright. Row
      // exclusion is proven behaviourally in the next test.
    }
  }, 30_000);

  it("admits only the legitimate null-key run, excluding unrelated issue-only and task-only newer runs", async () => {
    trackedSql = [];
    await attentionService(db as never).list(companyId, { includeDismissed: true, all: true, allowUnscopedAll: true });

    const query = newerRunQueries()[0]!;
    const rows = await (db as unknown as { $client: { unsafe: (text: string, params: unknown[]) => Promise<Record<string, unknown>[]> } })
      .$client.unsafe(query.text, query.params);

    // Both id projections share an unnamed output column, so postgres.js
    // collapses them; a row admitted by the null branch must project null there.
    for (const row of rows) expect(row["?column?"]).toBeNull();
    expect(rows).toHaveLength(1);
    expect(new Date(rows[0]!.created_at as string).getTime()).toBe(nullKeyRunCreatedAt.getTime());
  }, 30_000);

  it("still suppresses the null-key failed run while keeping the keyed failed run in the feed", async () => {
    const feed = await attentionService(db as never).list(companyId, { includeDismissed: true, all: true, allowUnscopedAll: true });
    const failedRunItems = feed.items.filter((item) => item.sourceKind === "failed_run");

    // The null-key failed run is suppressed by the newer null-key run.
    expect(failedRunItems.map((item) => item.dedupKey)).not.toContain(`run:${nullKeyFailedRunId}`);
    // The keyed failed run is still emitted, and the unrelated newer runs that
    // carry their own ids did not suppress it.
    expect(failedRunItems).toHaveLength(1);
    const keyed = failedRunItems[0]!;
    expect(keyed.subject.kind).toBe("run");
    expect((keyed.subject.metadata?.issueId as string | undefined) ?? null).toBe(issueAId);
  }, 30_000);
});