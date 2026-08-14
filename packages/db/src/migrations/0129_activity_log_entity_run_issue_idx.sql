-- The issue-comment attribution read path joins heartbeat_runs to activity_log to
-- determine whether a run is associated with an issue. The join uses an EXISTS
-- subquery keyed on (company_id, entity_type, entity_id, run_id) but the table
-- only had a single-column index on run_id — so every candidate run required a
-- full company-scoped subquery scan. This index covers the exact lookup pattern so
-- PostgreSQL resolves the EXISTS in O(log n) instead of O(n).
--
-- CONCURRENTLY: builds the partial index without holding a write lock on the table,
-- so inserts/updates continue uninterrupted during the build on production data.
-- The Paperclip migration runner detects this form and executes it outside its
-- per-migration BEGIN/COMMIT wrapper, as PostgreSQL requires.
CREATE INDEX CONCURRENTLY IF NOT EXISTS "activity_log_company_entity_run_idx"
  ON "activity_log" USING btree ("company_id", "entity_type", "entity_id", "run_id")
  WHERE "run_id" IS NOT NULL;
