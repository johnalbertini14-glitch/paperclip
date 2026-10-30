import { randomUUID } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { agents, companies, createDb } from "@paperclipai/db";
import { getEmbeddedPostgresTestSupport, startEmbeddedPostgresTestDatabase } from "../__tests__/helpers/embedded-postgres.js";

// Isolated plan probe for the dashboard's 14-day recovered-run CTE; never connects to production.
const support = await getEmbeddedPostgresTestSupport();
(support.supported ? describe : describe.skip)("dashboard recovered-run plan", () => {
  let database: Awaited<ReturnType<typeof startEmbeddedPostgresTestDatabase>>;
  let db: ReturnType<typeof createDb>;
  const localId = randomUUID();
  const foreignId = randomUUID();
  const agentIds = [randomUUID(), randomUUID()];
  const cutoff = "2026-10-15T00:00:00Z";
  const client = () => (db as unknown as { $client: {
    unsafe: (text: string, params?: unknown[]) => Promise<Record<string, unknown>[]>;
  } }).$client;
  const recovered = (scoped: boolean) => `with recursive recovered_runs(id) as (
    select parent.id from heartbeat_runs child
    join heartbeat_runs parent on parent.id = child.retry_of_run_id
    where child.company_id = $1::uuid ${scoped ? "and parent.company_id = $1::uuid" : ""}
      and child.status = 'succeeded' and child.created_at >= $2::timestamptz
    union
    select parent.id from recovered_runs rr
    join heartbeat_runs child on child.id = rr.id
    join heartbeat_runs parent on parent.id = child.retry_of_run_id
    where child.created_at >= $2::timestamptz
      ${scoped ? "and child.company_id = $1::uuid and parent.company_id = $1::uuid" : ""}
  ) select count(*)::int as recovered from heartbeat_runs run
    where run.company_id = $1::uuid and run.created_at >= $2::timestamptz
      and run.status in ('failed', 'timed_out')
      and run.id in (select id from recovered_runs)`;

  beforeAll(async () => {
    database = await startEmbeddedPostgresTestDatabase("dashboard-recovered-plan-");
    db = createDb(database.connectionString);
    await db.insert(companies).values([
      { id: localId, name: "Local plan", issuePrefix: "DPL" },
      { id: foreignId, name: "Foreign plan", issuePrefix: "DPF" },
    ]);
    await db.insert(agents).values(agentIds.map((id, index) => ({
      id, companyId: index ? foreignId : localId,
      name: `Plan agent ${index}`, role: "engineer", adapterType: "paperclip_runner",
    })));
    // Two companies, two windows, 1,500 direct recoveries and 250 chained recoveries.
    // IDs are deterministic only within this isolated fixture and have no production meaning.
    await client().unsafe(`insert into heartbeat_runs
      (id, company_id, agent_id, status, created_at, retry_of_run_id)
      select md5('dash-base-' || g::text)::uuid,
        case when g % 2 = 0 then $1::uuid else $2::uuid end,
        case when g % 2 = 0 then $3::uuid else $4::uuid end,
        'failed', case when g % 5 = 0 then '2026-10-01'::timestamptz
                       else '2026-10-20'::timestamptz end, null::uuid
      from generate_series(1, 6000) g`, [localId, foreignId, ...agentIds]);
    await client().unsafe(`insert into heartbeat_runs
      (id, company_id, agent_id, status, created_at, retry_of_run_id)
      select md5('dash-retry-' || g::text)::uuid,
        case when g % 2 = 0 then $1::uuid else $2::uuid end,
        case when g % 2 = 0 then $3::uuid else $4::uuid end,
        case when g % 4 = 0 then 'failed' else 'succeeded' end,
        '2026-10-21'::timestamptz, md5('dash-base-' || g::text)::uuid
      from generate_series(1, 3000) g`, [localId, foreignId, ...agentIds]);
    await client().unsafe(`insert into heartbeat_runs
      (id, company_id, agent_id, status, created_at, retry_of_run_id)
      select md5('dash-final-' || g::text)::uuid, $1::uuid, $2::uuid,
        'succeeded', '2026-10-22'::timestamptz, md5('dash-retry-' || g::text)::uuid
      from generate_series(4, 1000, 4) g`, [localId, agentIds[0]]);
    await client().unsafe("analyze heartbeat_runs");
  }, 60_000);

  afterAll(async () => { await database?.cleanup(); });

  it("compares scoped and original plans without changing legitimate recovery counts", async () => {
    const params = [localId, cutoff];
    const oldRows = await client().unsafe(recovered(false), params);
    const scopedRows = await client().unsafe(recovered(true), params);
    expect(scopedRows).toEqual(oldRows);
    for (const [name, query] of [["original", recovered(false)], ["companyScoped", recovered(true)]] as const) {
      const plan = await client().unsafe(`explain (analyze, buffers, format json) ${query}`, params);
      const report = plan[0]?.["QUERY PLAN"] as { "Execution Time": number; Plan: Record<string, unknown> }[];
      console.log(`DASHBOARD_RECOVERED_PLAN ${JSON.stringify({
        name, fixtureRows: 9250, recovered: scopedRows[0]?.recovered,
        executionMs: report[0]?.["Execution Time"],
        sharedHits: report[0]?.Plan["Shared Hit Blocks"],
        sharedReads: report[0]?.Plan["Shared Read Blocks"],
      })}`);
    }
  }, 30_000);

  it("excludes cross-company reference from the seed and recursive recovery chain", async () => {
    const targetId = randomUUID();
    const foreignRetryId = randomUUID();
    const localRetryId = randomUUID();
    await client().unsafe(`insert into heartbeat_runs
      (id, company_id, agent_id, status, created_at, retry_of_run_id) values
      ($1::uuid, $4::uuid, $6::uuid, 'failed', '2026-10-20'::timestamptz, null),
      ($2::uuid, $5::uuid, $7::uuid, 'failed', '2026-10-21'::timestamptz, $1::uuid),
      ($3::uuid, $4::uuid, $6::uuid, 'succeeded', '2026-10-22'::timestamptz, $2::uuid)`,
    [targetId, foreignRetryId, localRetryId, localId, foreignId, ...agentIds]);
    const params = [localId, cutoff];
    const oldCount = Number((await client().unsafe(recovered(false), params))[0]?.recovered);
    const scopedCount = Number((await client().unsafe(recovered(true), params))[0]?.recovered);
    expect(oldCount - scopedCount).toBe(1);
  }, 30_000);
});
