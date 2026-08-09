-- Issue detail, heartbeat context, and recovery projections resolve runs by the
-- issue id stored in the run context. Keep that JSON expression indexable so
-- these point lookups do not scan an entire company's heartbeat history.
CREATE INDEX IF NOT EXISTS "heartbeat_runs_company_context_issue_created_idx"
  ON "heartbeat_runs" USING btree ("company_id", ("context_snapshot"->>'issueId'), "created_at", "id");
