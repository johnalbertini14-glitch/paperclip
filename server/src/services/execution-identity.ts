import { sql, type SQL } from "drizzle-orm";

/** Upstream bd64eb27 / #16291: cast only canonical UUID evidence. */
export function canonicalExecutionUuid(text: SQL): SQL<string | null> {
  return sql<string | null>`case when ${text} ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then (${text})::uuid end`;
}
