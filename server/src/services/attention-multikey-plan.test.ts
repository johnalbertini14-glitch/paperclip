import { randomUUID } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { agents, companies, createDb } from "@paperclipai/db";
import { getEmbeddedPostgresTestSupport, startEmbeddedPostgresTestDatabase } from "../__tests__/helpers/embedded-postgres.js";

// Isolated, repeatable query-plan probe: no production connection or data.
// The baseline projects each matching run; the candidate aggregates by resolved
// agent/key. Both retain company, agent, oldest-failure and key bounds.
const support = await getEmbeddedPostgresTestSupport();
(support.supported ? describe : describe.skip)("attention multi-key projection plan", () => {
  let database: Awaited<ReturnType<typeof startEmbeddedPostgresTestDatabase>>;
  let db: ReturnType<typeof createDb>;
  const companyId = randomUUID();
  const agentIds = Array.from({ length: 8 }, () => randomUUID());
  const issueIds = Array.from({ length: 32 }, () => randomUUID());
  const cutoff = "2026-01-01T00:00:00Z";

  beforeAll(async () => {
    database = await startEmbeddedPostgresTestDatabase("attention-multikey-plan-");
    db = createDb(database.connectionString);
    await db.insert(companies).values({ id: companyId, name: "Attention plan fixture", issuePrefix: "APF" });
    await db.insert(agents).values(agentIds.map((id, index) => ({
      id, companyId, name: `Plan agent ${index}`, role: "engineer", adapterType: "paperclip_runner",
    })));
    const client = (db as unknown as { $client: { unsafe: (text: string, params?: unknown[]) => Promise<unknown[]> } }).$client;
    // Eight agents, 32 keys, 8,000 runs. Alternate issueId and taskId contexts;
    // old unrelated runs force the timestamp bound. No application fixtures touched.
    await client.unsafe(`insert into heartbeat_runs (id, company_id, agent_id, status, context_snapshot, created_at)
      select md5(g::text || $1::text)::uuid, $1::uuid, ($2::uuid[])[1 + (g % 8)], 'succeeded',
        case when g % 2 = 0 then jsonb_build_object('issueId', (($3::uuid[])[1 + (g % 32)])::text)
          else jsonb_build_object('taskId', (($3::uuid[])[1 + (g % 32)])::text) end,
        case when g % 5 = 0 then '2025-12-01'::timestamptz else '2026-01-02'::timestamptz end
      from generate_series(1, 8000) g`, [companyId, agentIds, issueIds]);
    // Unrelated same-company history makes the key selection selective, as it
    // is in a real attention feed where few issues have exhausted runs.
    await client.unsafe(`insert into heartbeat_runs (id, company_id, agent_id, status, context_snapshot, created_at)
      select md5('unrelated-' || g::text || $1::text)::uuid, $1::uuid,
        ($2::uuid[])[1 + (g % 8)], 'succeeded',
        jsonb_build_object('issueId', md5('other-' || g::text)::uuid::text),
        '2026-01-02'::timestamptz
      from generate_series(1, 40000) g`, [companyId, agentIds]);
    await client.unsafe("analyze heartbeat_runs");
  }, 90_000);

  afterAll(async () => { await database?.cleanup(); });

  it("records EXPLAIN ANALYZE and matching grouped semantics for a multi-agent/multi-key fixture", async () => {
    const client = (db as unknown as { $client: { unsafe: (text: string, params?: unknown[]) => Promise<Record<string, unknown>[]> } }).$client;
    const key = "context_snapshot ->> 'issueId'";
    const task = "context_snapshot ->> 'taskId'";
    const where = `from heartbeat_runs where company_id = $1::uuid
      and agent_id = any($2::uuid[]) and created_at > $3::timestamptz
      and (${key} = any($4::text[]) or (${key} is null and ${task} = any($4::text[])))`;
    const params = [companyId, agentIds, cutoff, issueIds];
    const oldSql = `select agent_id, created_at, ${key} as issue_id, ${task} as task_id ${where}`;
    const resolved = `case when ${key} is not null then nullif(${key}, '') else nullif(${task}, '') end`;
    const groupedSql = `select agent_id, ${resolved} as run_key, max(created_at) as latest ${where} group by agent_id, ${resolved}`;
    const unionSql = `select agent_id, run_key, max(created_at) as latest from (
      select agent_id, ${key} as run_key, created_at from heartbeat_runs
        where company_id = $1::uuid and agent_id = any($2::uuid[])
          and created_at > $3::timestamptz and ${key} = any($4::text[])
      union all
      select agent_id, ${task} as run_key, created_at from heartbeat_runs
        where company_id = $1::uuid and agent_id = any($2::uuid[])
          and created_at > $3::timestamptz and ${key} is null and ${task} = any($4::text[])
    ) scoped group by agent_id, run_key`;
    const oldRows = await client.unsafe(oldSql, params);
    const groupedRows = await client.unsafe(groupedSql, params);
    const expected = new Map<string, number>();
    for (const row of oldRows) {
      const mapKey = `${row.agent_id}:${row.issue_id ?? row.task_id ?? ""}`;
      expected.set(mapKey, Math.max(expected.get(mapKey) ?? 0, new Date(String(row.created_at)).getTime()));
    }
    expect(groupedRows.length).toBe(expected.size);
    for (const row of groupedRows) {
      expect(new Date(String(row.latest)).getTime()).toBe(expected.get(`${row.agent_id}:${row.run_key ?? ""}`));
    }
    const unionRows = await client.unsafe(unionSql, params);
    expect(unionRows.length).toBe(expected.size);
    for (const row of unionRows) {
      expect(new Date(String(row.latest)).getTime()).toBe(expected.get(`${row.agent_id}:${row.run_key ?? ""}`));
    }
    for (const [name, query] of [["baseline", oldSql], ["grouped", groupedSql], ["union", unionSql]] as const) {
      const plan = await client.unsafe(`explain (analyze, buffers, format json) ${query}`, params);
      const document = plan[0]?.["QUERY PLAN"] as { Plan: { [key: string]: unknown }; "Execution Time": number }[];
      const nodes: string[] = [];
      const visit = (node: Record<string, unknown>) => {
        nodes.push(`${node["Node Type"]}${node["Index Name"] ? `:${node["Index Name"]}` : ""}`);
        for (const child of (node.Plans ?? []) as Record<string, unknown>[]) visit(child);
      };
      visit(document[0]!.Plan);
      console.log(`ATTENTION_MULTIKEY_PLAN ${JSON.stringify({ name, fixtureRows: 48000, agents: agentIds.length,
        keys: issueIds.length, returnedRows: name === "baseline" ? oldRows.length : groupedRows.length,
        executionMs: document[0]?.["Execution Time"], nodes })}`);
    }
  }, 60_000);

  it("preserves sparse old failures and null-key precedence across companies", async () => {
    const client = (db as unknown as { $client: { unsafe: (text: string, params?: unknown[]) => Promise<Record<string, unknown>[]> } }).$client;
    const otherCompanyId = randomUUID();
    const otherAgentId = randomUUID();
    await db.insert(companies).values({ id: otherCompanyId, name: "Other plan fixture", issuePrefix: "OPF" });
    await db.insert(agents).values({ id: otherAgentId, companyId: otherCompanyId,
      name: "Other agent", role: "engineer", adapterType: "paperclip_runner" });
    const contexts = [
      { agent: agentIds[0], company: companyId, context: { issueId: "", taskId: issueIds[0] }, date: "2026-01-03T00:00:00Z" },
      { agent: agentIds[0], company: companyId, context: { taskId: "" }, date: "2026-01-04T00:00:00Z" },
      { agent: agentIds[0], company: companyId, context: {}, date: "2026-01-05T00:00:00Z" },
      { agent: agentIds[1], company: companyId, context: { issueId: issueIds[0], taskId: issueIds[1] }, date: "2026-01-06T00:00:00Z" },
      { agent: otherAgentId, company: otherCompanyId, context: { issueId: issueIds[0] }, date: "2026-01-07T00:00:00Z" },
    ];
    for (const row of contexts) {
      await client.unsafe(`insert into heartbeat_runs (id, company_id, agent_id, status, context_snapshot, created_at)
        values ($1::uuid, $2::uuid, $3::uuid, 'succeeded', $4::jsonb, $5::timestamptz)`,
        [randomUUID(), row.company, row.agent, JSON.stringify(row.context), row.date]);
    }
    await client.unsafe("analyze heartbeat_runs");
    const key = "context_snapshot ->> 'issueId'";
    const task = "context_snapshot ->> 'taskId'";
    const resolved = `case when ${key} is not null then nullif(${key}, '') else nullif(${task}, '') end`;
    const scope = `company_id = $1::uuid and agent_id = any($2::uuid[])
      and created_at > $3::timestamptz and
      (${key} = any($4::text[]) or (${key} is null and ${task} = any($4::text[]))
       or ${key} = '' or (${key} is null and (${task} is null or ${task} = '')))`;
    const params = [companyId, agentIds, "2024-01-01T00:00:00Z", issueIds];
    const baseline = `select agent_id, created_at, ${resolved} as run_key from heartbeat_runs where ${scope}`;
    const grouped = `select agent_id, ${resolved} as run_key, max(created_at) as latest
      from heartbeat_runs where ${scope} group by agent_id, ${resolved}`;
    const union = `select agent_id, run_key, max(created_at) as latest from (
      select agent_id, ${key} as run_key, created_at from heartbeat_runs
        where company_id = $1::uuid and agent_id = any($2::uuid[])
        and created_at > $3::timestamptz and ${key} = any($4::text[])
      union all
      select agent_id, ${task} as run_key, created_at from heartbeat_runs
        where company_id = $1::uuid and agent_id = any($2::uuid[])
        and created_at > $3::timestamptz and ${key} is null and ${task} = any($4::text[])
      union all
      select agent_id, null::text as run_key, created_at from heartbeat_runs
        where company_id = $1::uuid and agent_id = any($2::uuid[])
        and created_at > $3::timestamptz and
        (${key} = '' or (${key} is null and (${task} is null or ${task} = '')))
    ) scoped group by agent_id, run_key`;
    const raw = await client.unsafe(baseline, params);
    const expected = new Map<string, number>();
    for (const row of raw) {
      const mapKey = `${row.agent_id}:${row.run_key ?? ""}`;
      expected.set(mapKey, Math.max(expected.get(mapKey) ?? 0, new Date(String(row.created_at)).getTime()));
    }
    const nullKey = `${agentIds[0]}:`;
    expect(expected.get(nullKey)).toBe(new Date("2026-01-05").getTime());
    // The new issueId wins over its taskId; that task key may still have older fixture history.
    expect(expected.get(`${agentIds[1]}:${issueIds[1]}`)).toBeLessThan(new Date("2026-01-06T00:00:00Z").getTime());
    expect([...expected.keys()].some((key) => key.startsWith(`${otherAgentId}:`))).toBe(false);
    // Probe each failed agent/key independently. A descending index lookup can
    // stop on its first row; the null key must retain the separate precedence rule.
    const lateral = `select targets.agent_id, targets.run_key, latest.created_at as latest
      from (select agent_id, run_key from unnest($2::uuid[]) agent_id
        cross join unnest(array_append($4::text[], null::text)) run_key) targets
      cross join lateral (
        select created_at from heartbeat_runs
        where company_id = $1::uuid and agent_id = targets.agent_id
          and created_at > $3::timestamptz and (
            (targets.run_key is not null and
              (${key} = targets.run_key or (${key} is null and ${task} = targets.run_key)))
            or (targets.run_key is null and
              (${key} = '' or (${key} is null and (${task} is null or ${task} = ''))))
          ) order by created_at desc limit 1
      ) latest`;
    // Split the indexed issue/task equality probes so the OR cannot select the
    // company-wide created_at index. Keep the unresolved key in a single scan:
    // no context-key equality index can answer a missing/empty key predicate.
    const split = `select agent_id, run_key, max(latest) as latest from (
      select targets.agent_id, targets.run_key, matched.created_at as latest
        from (select agent_id, run_key from unnest($2::uuid[]) agent_id
          cross join unnest($4::text[]) run_key) targets
        cross join lateral (
          select created_at from heartbeat_runs
          where company_id = $1::uuid and agent_id = targets.agent_id
            and created_at > $3::timestamptz and ${key} = targets.run_key
          order by created_at desc limit 1
        ) matched
      union all
      select targets.agent_id, targets.run_key, matched.created_at as latest
        from (select agent_id, run_key from unnest($2::uuid[]) agent_id
          cross join unnest($4::text[]) run_key) targets
        cross join lateral (
          select created_at from heartbeat_runs
          where company_id = $1::uuid and agent_id = targets.agent_id
            and created_at > $3::timestamptz and ${key} is null
            and ${task} = targets.run_key
          order by created_at desc limit 1
        ) matched
      union all
      select agent_id, null::text as run_key, max(created_at) as latest
        from heartbeat_runs where company_id = $1::uuid
          and agent_id = any($2::uuid[]) and created_at > $3::timestamptz
          and (${key} = '' or (${key} is null and (${task} is null or ${task} = '')))
        group by agent_id
    ) scoped group by agent_id, run_key`;
    for (const [name, query] of [["baseline", baseline], ["grouped", grouped], ["union", union], ["lateral", lateral], ["split", split]] as const) {
      const rows = await client.unsafe(query, params);
      if (name !== "baseline") {
        expect(rows.length).toBe(expected.size);
        for (const row of rows) {
          expect(new Date(String(row.latest)).getTime()).toBe(expected.get(`${row.agent_id}:${row.run_key ?? ""}`));
        }
      }
      const plan = await client.unsafe(`explain (analyze, buffers, format json) ${query}`, params);
      const document = plan[0]?.["QUERY PLAN"] as { Plan: Record<string, unknown>; "Execution Time": number }[];
      const nodes: string[] = [];
      const visit = (node: Record<string, unknown>) => {
        nodes.push(`${node["Node Type"]}${node["Index Name"] ? `:${node["Index Name"]}` : ""}`);
        for (const child of (node.Plans ?? []) as Record<string, unknown>[]) visit(child);
      };
      visit(document[0]!.Plan);
      console.log(`ATTENTION_SPARSE_NULL_PLAN ${JSON.stringify({ name, returnedRows: rows.length,
        executionMs: document[0]?.["Execution Time"], nodes })}`);
    }
  }, 60_000);
});
