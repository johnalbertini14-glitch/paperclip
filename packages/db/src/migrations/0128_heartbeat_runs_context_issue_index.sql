-- Issue detail, heartbeat context, and recovery projections resolve runs by the
-- issue id stored in the run context. Keep that JSON expression indexable so
-- these point lookups do not scan an entire company's heartbeat history.
--
-- CONCURRENTLY: builds the index without holding a write lock on the table,
-- so inserts/updates continue uninterrupted during the build on production data.
-- The Paperclip migration runner detects this form and executes it outside its
-- per-migration BEGIN/COMMIT wrapper, as PostgreSQL requires.
CREATE INDEX CONCURRENTLY IF NOT EXISTS "heartbeat_runs_company_context_issue_created_idx"
  ON "heartbeat_runs" USING btree ("company_id", ("context_snapshot"->>'issueId'), "created_at", "id");
