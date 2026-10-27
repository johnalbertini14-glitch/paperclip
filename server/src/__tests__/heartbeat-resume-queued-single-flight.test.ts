import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createDb } from "@paperclipai/db";
import { getEmbeddedPostgresTestSupport, startEmbeddedPostgresTestDatabase } from "./helpers/embedded-postgres.js";
import { heartbeatService } from "../services/heartbeat.js";

// The periodic scheduler starts a recovery chain every tick without waiting for
// the previous one. Under load those chains overlap, and every concurrent sweep
// revisits the same blocked stranded queue under its issue lock until the
// waiters hold the whole connection pool. One service instance must therefore
// share the sweep already in flight with concurrent callers, while a later call
// still runs its own sweep.
const support = await getEmbeddedPostgresTestSupport();
const suite = support.supported ? describe : describe.skip;

suite("heartbeat resumeQueuedRuns single flight", () => {
  let db: ReturnType<typeof createDb>;
  let temporary: Awaited<ReturnType<typeof startEmbeddedPostgresTestDatabase>>;
  let trackedSql: string[] = [];
  let originalUnsafe: unknown;

  beforeAll(async () => {
    temporary = await startEmbeddedPostgresTestDatabase("resume-single-flight-");
    db = createDb(temporary.connectionString);
    const driver = (db as unknown as { $client: { unsafe: (...args: unknown[]) => unknown } }).$client;
    originalUnsafe = driver.unsafe;
    driver.unsafe = function patchedUnsafe(this: unknown, ...args: unknown[]) {
      if (typeof args[0] === "string") trackedSql.push(args[0]);
      return (originalUnsafe as (...inner: unknown[]) => unknown).apply(this, args);
    };
  }, 60_000);

  afterAll(async () => {
    const driver = (db as unknown as { $client: { unsafe: unknown; end: (opts: { timeout: number }) => Promise<void> } }).$client;
    if (driver && originalUnsafe) driver.unsafe = originalUnsafe;
    await driver?.end({ timeout: 0 });
    await temporary?.cleanup();
  });

  // The stranded-queue lookup is the only resumeQueuedRuns query that joins a
  // deferred wake to its issue by the payload issue id.
  const strandedQueueSweeps = () => trackedSql.filter((text) =>
    text.includes('"agent_wakeup_requests"')
    && text.includes("->>'issueId'")
    && text.includes("wakeCommentIds"));

  it("runs one sweep for concurrent callers and a new sweep for a later call", async () => {
    const heartbeat = heartbeatService(db);
    trackedSql = [];
    const [first, second] = await Promise.allSettled([heartbeat.resumeQueuedRuns(), heartbeat.resumeQueuedRuns()]);
    expect(first.status).toBe("fulfilled");
    expect(second.status).toBe("fulfilled");
    expect(strandedQueueSweeps()).toHaveLength(1);

    await heartbeat.resumeQueuedRuns();
    expect(strandedQueueSweeps()).toHaveLength(2);
  }, 30_000);

  it("keeps separate service instances independent", async () => {
    trackedSql = [];
    await Promise.all([heartbeatService(db).resumeQueuedRuns(), heartbeatService(db).resumeQueuedRuns()]);
    expect(strandedQueueSweeps()).toHaveLength(2);
  }, 30_000);
});
