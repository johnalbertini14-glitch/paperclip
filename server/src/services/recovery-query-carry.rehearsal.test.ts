import { randomUUID } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { eq } from "drizzle-orm";
import { agents, companies, createDb, heartbeatRuns, issueRecoveryActions, issues } from "@paperclipai/db";
import { getEmbeddedPostgresTestSupport, startEmbeddedPostgresTestDatabase } from "../__tests__/helpers/embedded-postgres.js";
import { conversationRecoveryActionPredicate } from "./conversation-continuation.js";
import { settleUnrecoverableExecutions } from "./execution-recovery-resolution.js";

const support = await getEmbeddedPostgresTestSupport();
(support.supported ? describe : describe.skip)("v1023 recovery query carry", () => {
  let fixture: Awaited<ReturnType<typeof startEmbeddedPostgresTestDatabase>>;
  let db: ReturnType<typeof createDb>;
  let validActionId: string;
  let foreignActionId: string;

  beforeAll(async () => {
    fixture = await startEmbeddedPostgresTestDatabase("recovery-query-carry-");
    db = createDb(fixture.connectionString);
    const companyId = randomUUID();
    const otherCompanyId = randomUUID();
    const agentId = randomUUID();
    const issueId = randomUUID();
    const foreignIssueId = randomUUID();
    const runId = randomUUID();
    await db.insert(companies).values([
      { id: companyId, name: "Recovery query fixture", issuePrefix: "RQ" },
      { id: otherCompanyId, name: "Foreign recovery fixture", issuePrefix: "FRQ" },
    ]);
    await db.insert(agents).values({ id: agentId, companyId, name: "Query agent", role: "engineer", adapterType: "claude_local" });
    await db.insert(issues).values([
      { id: issueId, companyId, title: "Source issue", status: "in_progress", assigneeAgentId: agentId },
      { id: foreignIssueId, companyId: otherCompanyId, title: "Foreign issue", status: "in_progress" },
    ]);
    await db.insert(heartbeatRuns).values({
      id: runId, companyId, agentId, status: "failed", runtimeMode: "legacy", nativeIssueId: issueId,
      runnerProfileJson: { adapterDispatch: { adapterType: "claude_local" } },
      resultJson: { conversationContinuation: "continue_conversation_v1" }, contextSnapshot: { issueId },
    });
    validActionId = randomUUID();
    foreignActionId = randomUUID();
    const base = { kind: "active_run_watchdog" as const, status: "resolved" as const,
      cause: "legacy_execution_requires_reconciliation", nextAction: "Review without replay" };
    await db.insert(issueRecoveryActions).values([
      { ...base, id: validActionId, companyId, sourceIssueId: issueId, fingerprint: runId, evidence: { runId } },
      { ...base, id: randomUUID(), companyId, sourceIssueId: issueId, fingerprint: "malformed", evidence: { runId: "not-a-uuid" } },
      { ...base, id: randomUUID(), companyId, sourceIssueId: issueId, fingerprint: "upper", evidence: { runId: runId.toUpperCase() } },
      { ...base, id: foreignActionId, companyId: otherCompanyId, sourceIssueId: foreignIssueId, fingerprint: runId, evidence: { runId } },
    ]);
  }, 90_000);
  afterAll(async () => { await (db as any)?.$client?.end?.(); await fixture?.cleanup(); });

  it("matches only canonical company/issue-bound evidence without raising on malformed JSON", async () => {
    const rows = await db.select({ id: issueRecoveryActions.id }).from(issueRecoveryActions)
      .where(conversationRecoveryActionPredicate());
    expect(rows.map(row => row.id)).toEqual([validActionId]);
    expect(rows.some(row => row.id === foreignActionId)).toBe(false);
  });

  it("executes the guarded lateral recovery lookup with malformed retained evidence", async () => {
    await expect(settleUnrecoverableExecutions(db)).resolves.toBeUndefined();
    const [retained] = await db.select().from(issueRecoveryActions).where(eq(issueRecoveryActions.id, validActionId));
    expect(retained?.companyId).toBeDefined();
  });
});
