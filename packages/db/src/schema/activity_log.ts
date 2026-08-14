import { pgTable, uuid, text, timestamp, jsonb, index } from "drizzle-orm/pg-core";
import { sql } from "drizzle-orm";
import { companies } from "./companies.js";
import { agents } from "./agents.js";
import { heartbeatRuns } from "./heartbeat_runs.js";

export const activityLog = pgTable(
  "activity_log",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    companyId: uuid("company_id").notNull().references(() => companies.id),
    actorType: text("actor_type").notNull().default("system"),
    actorId: text("actor_id").notNull(),
    action: text("action").notNull(),
    entityType: text("entity_type").notNull(),
    entityId: text("entity_id").notNull(),
    agentId: uuid("agent_id").references(() => agents.id),
    runId: uuid("run_id").references(() => heartbeatRuns.id),
    details: jsonb("details").$type<Record<string, unknown>>(),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => ({
    companyCreatedIdx: index("activity_log_company_created_idx").on(table.companyId, table.createdAt),
    runIdIdx: index("activity_log_run_id_idx").on(table.runId),
    entityIdx: index("activity_log_entity_type_id_idx").on(table.entityType, table.entityId),
    // Covers the EXISTS subquery join used by enrichCommentsWithDerivedAgentAttribution:
    //   activity_log(company_id, entity_type, entity_id, run_id) WHERE run_id IS NOT NULL
    // Partial index matches the IS NOT NULL filter so PostgreSQL uses it for the EXISTS
    // lookup in O(log n) instead of scanning the full company/entity partition.
    companyEntityRunIdx: index("activity_log_company_entity_run_idx").on(
      table.companyId,
      table.entityType,
      table.entityId,
      table.runId,
    ).where(sql`${table.runId} is not null`),
  }),
);
