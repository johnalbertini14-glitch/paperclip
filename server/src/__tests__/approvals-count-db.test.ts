import { randomUUID } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { approvals, companies, createDb } from "@paperclipai/db";
import { getEmbeddedPostgresTestSupport, startEmbeddedPostgresTestDatabase } from "./helpers/embedded-postgres.js";
import { approvalService } from "../services/approvals.js";

const support = await getEmbeddedPostgresTestSupport();
if (!support.supported) console.warn(`Skipping embedded Postgres approval count: ${support.reason}`);

(support.supported ? describe : describe.skip)("pending approval count on embedded Postgres", () => {
  let fixture: Awaited<ReturnType<typeof startEmbeddedPostgresTestDatabase>>;
  let db: ReturnType<typeof createDb>;

  beforeAll(async () => {
    fixture = await startEmbeddedPostgresTestDatabase("paperclip-approvals-count-");
    db = createDb(fixture.connectionString);
  }, 30_000);

  afterAll(async () => {
    await fixture?.cleanup();
  });

  it("counts only matching company pending approvals independently of the 50-row page", async () => {
    const companyId = randomUUID();
    const foreignId = randomUUID();
    await db.insert(companies).values([
      { id: companyId, name: "Approval count", issuePrefix: "ACNT" },
      { id: foreignId, name: "Foreign approval count", issuePrefix: "FCNT" },
    ]);
    await db.insert(approvals).values([
      ...Array.from({ length: 51 }, () => ({ companyId, type: "hire_agent", status: "pending", payload: {} })),
      { companyId, type: "hire_agent", status: "approved", payload: {} },
      { companyId: foreignId, type: "hire_agent", status: "pending", payload: {} },
    ]);
    const service = approvalService(db);
    const first = await service.list(companyId, "pending", { limit: 50, offset: 0 });
    const second = await service.list(companyId, "pending", { limit: 50, offset: 50 });
    expect(first).toHaveLength(50);
    expect(second).toHaveLength(1);
    expect(new Set([...first, ...second].map((row) => row.id)).size).toBe(51);
    expect(await service.count(companyId, "pending")).toBe(51);
    expect(await service.count(companyId)).toBe(52);
    expect(await service.count(foreignId, "pending")).toBe(1);
  }, 90_000);
});
