--
-- PostgreSQL database dump
--

\restrict H77M4daUiarkRbKl64d4YR7N99vf7Z0KCbeB4rXnz1FfLwdhFQ9rAO0Qg5UGPtH

-- Dumped from database version 18.1
-- Dumped by pg_dump version 18.6 (Debian 18.6-1.pgdg13+2)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: uplift; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA uplift;


--
-- Name: SCHEMA uplift; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA uplift IS 'Operator-owned uplift objects (Phase 1). Board directive fcf79097 on REVA-17863: agents must not read, edit, or reason over these objects, and must not treat them as budget or enforcement signals. Additive only; no FKs to upstream tables.';


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: audit_chain; Type: TABLE; Schema: uplift; Owner: -
--

CREATE TABLE uplift.audit_chain (
    seq bigint NOT NULL,
    company_id uuid NOT NULL,
    source_table text NOT NULL,
    source_id uuid NOT NULL,
    activity_log_id uuid,
    action text NOT NULL,
    entry_hash text NOT NULL,
    prev_hash text NOT NULL,
    signer_identity_id uuid,
    sig text,
    signed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT audit_chain_source_table_check CHECK ((source_table = ANY (ARRAY['activity_log'::text, 'issue_execution_decisions'::text])))
);


--
-- Name: audit_chain_append(uuid, text, uuid); Type: FUNCTION; Schema: uplift; Owner: -
--

CREATE FUNCTION uplift.audit_chain_append(p_company_id uuid, p_source_table text, p_source_id uuid) RETURNS uplift.audit_chain
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_row       uplift.audit_chain;
  v_action    text;
  v_envelope  jsonb;
  v_prev_hash text;
  v_lock_key  bigint;
BEGIN
  IF p_source_table NOT IN ('activity_log', 'issue_execution_decisions') THEN
    RAISE EXCEPTION 'audit_chain_append: unsupported source_table %', p_source_table;
  END IF;

  v_lock_key := hashtextextended('uplift.audit_chain:' || p_company_id::text, 0);
  PERFORM pg_advisory_xact_lock(v_lock_key);

  IF p_source_table = 'activity_log' THEN
    SELECT al.action, to_jsonb(al)
      INTO v_action, v_envelope
      FROM activity_log al
     WHERE al.id = p_source_id AND al.company_id = p_company_id;

    IF v_envelope IS NOT NULL THEN
      IF v_action NOT IN (
        'issue.created', 'issue.updated', 'issue.productivity_review_created',
        'issue.productivity_review_updated', 'routine.run_triggered', 'git.commit_pushed'
      ) THEN
        RAISE EXCEPTION 'audit_chain_append: action % is out of chain scope', v_action;
      END IF;
      IF v_action = 'issue.updated' AND NOT (v_envelope->'details' ? 'status') THEN
        RAISE EXCEPTION 'audit_chain_append: issue.updated row % has no status transition, out of scope', p_source_id;
      END IF;
    END IF;
  ELSE
    SELECT 'review.decision_recorded', to_jsonb(d)
      INTO v_action, v_envelope
      FROM issue_execution_decisions d
     WHERE d.id = p_source_id AND d.company_id = p_company_id;
  END IF;

  IF v_envelope IS NULL THEN
    RAISE EXCEPTION 'audit_chain_append: source row %/% not found for company %', p_source_table, p_source_id, p_company_id;
  END IF;

  SELECT entry_hash INTO v_prev_hash
    FROM uplift.audit_chain
   WHERE company_id = p_company_id
   ORDER BY seq DESC
   LIMIT 1;

  IF v_prev_hash IS NULL THEN
    v_prev_hash := encode(sha256(convert_to('uplift.audit_chain.genesis:' || p_company_id::text, 'UTF8')), 'hex');
  END IF;

  INSERT INTO uplift.audit_chain (company_id, source_table, source_id, activity_log_id, action, entry_hash, prev_hash)
  VALUES (
    p_company_id, p_source_table, p_source_id,
    CASE WHEN p_source_table = 'activity_log' THEN p_source_id END,
    v_action,
    encode(sha256(convert_to(v_prev_hash || v_envelope::text, 'UTF8')), 'hex'),
    v_prev_hash
  )
  ON CONFLICT ON CONSTRAINT audit_chain_source_uq DO NOTHING
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;


--
-- Name: audit_chain_guard(); Type: FUNCTION; Schema: uplift; Owner: -
--

CREATE FUNCTION uplift.audit_chain_guard() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'uplift.audit_chain is append-only: delete blocked (seq=%)', OLD.seq;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF NEW.seq              <> OLD.seq
       OR NEW.company_id     <> OLD.company_id
       OR NEW.source_table   <> OLD.source_table
       OR NEW.source_id      <> OLD.source_id
       OR NEW.activity_log_id IS DISTINCT FROM OLD.activity_log_id
       OR NEW.action         <> OLD.action
       OR NEW.entry_hash     <> OLD.entry_hash
       OR NEW.prev_hash      <> OLD.prev_hash
       OR NEW.created_at     <> OLD.created_at
    THEN
      RAISE EXCEPTION 'uplift.audit_chain rows are immutable except sig/signed_at/signer_identity_id (seq=%)', OLD.seq;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: agent_daily_rollup; Type: TABLE; Schema: uplift; Owner: -
--

CREATE TABLE uplift.agent_daily_rollup (
    day date NOT NULL,
    agent_id uuid NOT NULL,
    adapter_type text DEFAULT 'unknown'::text NOT NULL,
    provider text DEFAULT 'unknown'::text NOT NULL,
    model text DEFAULT 'unknown'::text NOT NULL,
    usage_id text DEFAULT 'run_total'::text NOT NULL,
    input_tokens bigint DEFAULT 0 NOT NULL,
    output_tokens bigint DEFAULT 0 NOT NULL,
    cached_input_tokens bigint DEFAULT 0 NOT NULL,
    tool_calls bigint,
    runs integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE agent_daily_rollup; Type: COMMENT; Schema: uplift; Owner: -
--

COMMENT ON TABLE uplift.agent_daily_rollup IS 'Daily fold of uplift.agent_turn_metrics, written by retention.sh before the 14-day DELETE (spec 1b §7). Retained 400 days. Upsert on the natural PK — the fold is re-runnable.';


--
-- Name: agent_identities; Type: TABLE; Schema: uplift; Owner: -
--

CREATE TABLE uplift.agent_identities (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    identity_scope text NOT NULL,
    persona_key text,
    agent_id uuid,
    key_algorithm text DEFAULT 'ed25519'::text NOT NULL,
    public_key_b64 text NOT NULL,
    private_key_secret_id uuid,
    key_status text DEFAULT 'active'::text NOT NULL,
    superseded_by_identity_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    rotated_at timestamp with time zone,
    revoked_at timestamp with time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT agent_identities_identity_scope_check CHECK ((identity_scope = ANY (ARRAY['persona'::text, 'instance'::text]))),
    CONSTRAINT agent_identities_key_algorithm_check CHECK ((key_algorithm = 'ed25519'::text)),
    CONSTRAINT agent_identities_key_status_check CHECK ((key_status = ANY (ARRAY['active'::text, 'rotated'::text, 'revoked'::text]))),
    CONSTRAINT agent_identities_scope_shape CHECK ((((identity_scope = 'persona'::text) AND (persona_key IS NOT NULL) AND (agent_id IS NULL)) OR ((identity_scope = 'instance'::text) AND (agent_id IS NOT NULL) AND (persona_key IS NULL))))
);


--
-- Name: agent_turn_metrics; Type: TABLE; Schema: uplift; Owner: -
--

CREATE TABLE uplift.agent_turn_metrics (
    id bigint NOT NULL,
    company_id uuid NOT NULL,
    agent_id uuid NOT NULL,
    issue_id uuid,
    heartbeat_run_id uuid NOT NULL,
    cost_event_id uuid,
    granularity text NOT NULL,
    seq integer DEFAULT 0 NOT NULL,
    usage_id text DEFAULT 'run_total'::text NOT NULL,
    usage_source text DEFAULT 'unknown'::text NOT NULL,
    provider text DEFAULT 'unknown'::text NOT NULL,
    model text DEFAULT 'unknown'::text NOT NULL,
    input_tokens bigint DEFAULT 0 NOT NULL,
    output_tokens bigint DEFAULT 0 NOT NULL,
    cached_input_tokens bigint DEFAULT 0 NOT NULL,
    tool_calls integer,
    duration_ms integer,
    occurred_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT agent_turn_metrics_granularity_check CHECK ((granularity = ANY (ARRAY['run'::text, 'turn'::text]))),
    CONSTRAINT agent_turn_metrics_usage_id_check CHECK ((usage_id = ANY (ARRAY['run_total'::text, 'main'::text, 'subagent'::text, 'condenser'::text, 'reviewer'::text, 'unknown'::text])))
);


--
-- Name: TABLE agent_turn_metrics; Type: COMMENT; Schema: uplift; Owner: -
--

COMMENT ON TABLE uplift.agent_turn_metrics IS 'Phase 1b metering sidecar. RETENTION IS MANDATORY, NOT OPTIONAL (spec 1b §7): 14-day window AND 2,000,000 rows AND 500 MB total_relation_size — whichever ceiling trips first. Enforcement: host cron /docker/uplift-otel/bin/retention.sh at 03:10 daily (one-shot docker exec -u node psql), NOT a platform routine (no wake coupling; if ever migrated to a routine, next_run_at MUST be whole-second or the CAS claim silently never fires). Nightly order: (1) fold the day into uplift.agent_daily_rollup, (2) DELETE WHERE created_at < now() - interval ''14 days'', (3) if rows > 2e6 or size > 500 MB, delete oldest-beyond-7-days down to threshold, (4) let autovacuum reclaim. Row size 150-250 B; at ~1k runs/day the 14-day window is ~5 MB, so the row/byte ceilings only bind once turn parsing is enabled. Self-monitored by paperclip_table_bytes{table} with a Grafana alert at 85% of any ceiling. This table is the reason heartbeat_runs (1954 MB) is the cautionary tale: nothing in 1b may become the next one.';


--
-- Name: COLUMN agent_turn_metrics.granularity; Type: COMMENT; Schema: uplift; Owner: -
--

COMMENT ON COLUMN uplift.agent_turn_metrics.granularity IS 'run = one rollup row per finished heartbeat run (always written). turn = per-message rows from the transcript parser (feature-flagged OFF). Invariant checked in shadow: SUM(turn rows) ~= run row, mismatch ratio alerted above 2%.';


--
-- Name: agent_turn_metrics_id_seq; Type: SEQUENCE; Schema: uplift; Owner: -
--

ALTER TABLE uplift.agent_turn_metrics ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME uplift.agent_turn_metrics_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: audit_chain_seq_seq; Type: SEQUENCE; Schema: uplift; Owner: -
--

CREATE SEQUENCE uplift.audit_chain_seq_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: audit_chain_seq_seq; Type: SEQUENCE OWNED BY; Schema: uplift; Owner: -
--

ALTER SEQUENCE uplift.audit_chain_seq_seq OWNED BY uplift.audit_chain.seq;


--
-- Name: budget_hold_anchors; Type: TABLE; Schema: uplift; Owner: -
--

CREATE TABLE uplift.budget_hold_anchors (
    incident_id uuid NOT NULL,
    issue_id uuid NOT NULL,
    comment_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: cost_event_annotations; Type: TABLE; Schema: uplift; Owner: -
--

CREATE TABLE uplift.cost_event_annotations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    cost_event_id uuid NOT NULL,
    kind text NOT NULL,
    exclude_from_enforcement boolean DEFAULT true NOT NULL,
    note text NOT NULL,
    board_anchor text,
    created_by text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: digest_ledger; Type: TABLE; Schema: uplift; Owner: -
--

CREATE TABLE uplift.digest_ledger (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    item_key text NOT NULL,
    item_type text NOT NULL,
    bucket text NOT NULL,
    title text NOT NULL,
    first_surfaced_at timestamp with time zone DEFAULT now() NOT NULL,
    last_surfaced_at timestamp with time zone DEFAULT now() NOT NULL,
    surfaced_count integer DEFAULT 1 NOT NULL,
    disposition text DEFAULT 'pending'::text NOT NULL,
    disposition_note text,
    disposition_by text,
    disposition_at timestamp with time zone,
    digest_run_issue_id uuid,
    evidence jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT digest_ledger_bucket_check CHECK ((bucket = ANY (ARRAY['decision'::text, 'shipped'::text, 'unprocessed'::text])))
);


--
-- Name: TABLE digest_ledger; Type: COMMENT; Schema: uplift; Owner: -
--

COMMENT ON TABLE uplift.digest_ledger IS 'Phase 3 processed-items ledger. Tracks every item the daily digest has ever surfaced, across routine fires, so undispositioned decisions RE-SURFACE automatically (task requirement) instead of depending on an LLM remembering the prior brief. No FK to upstream (matches uplift.stuck_findings/budget_hold_anchors convention) — upstream deletes never block on this table. Upsert path only: INSERT ... ON CONFLICT (company_id, item_key) WHERE disposition=''pending'' DO UPDATE. A human dispositions a row by posting a board comment on the digest execution issue in the form the routine prompt specifies (routine-description.md §Disposition parsing); the NEXT digest fire reads that comment and writes disposition/disposition_note/disposition_by/disposition_at — the ledger itself is written only by the routine''s agent, never directly by a human or another routine.';


--
-- Name: COLUMN digest_ledger.evidence; Type: COMMENT; Schema: uplift; Owner: -
--

COMMENT ON COLUMN uplift.digest_ledger.evidence IS 'Machine-verifiable pointers only: issue identifiers, heartbeat_run_id/cost_event_id/issue_execution_decisions.id, counts. NEVER heartbeat_run_events payload, adapter_config, or any secret-bearing field (same redaction discipline as uplift.stuck_findings.evidence, spec 1c review N8).';


--
-- Name: doc_purge_20260805; Type: TABLE; Schema: uplift; Owner: -
--

CREATE TABLE uplift.doc_purge_20260805 (
    id uuid
);


--
-- Name: execution_events; Type: TABLE; Schema: uplift; Owner: -
--

CREATE TABLE uplift.execution_events (
    id bigint NOT NULL,
    company_id uuid NOT NULL,
    agent_id uuid NOT NULL,
    issue_id uuid,
    heartbeat_run_id uuid NOT NULL,
    seq integer DEFAULT 1 NOT NULL,
    action_type text NOT NULL,
    run_reason text,
    before_commit_oid text,
    after_commit_oid text,
    status text DEFAULT 'recorded'::text NOT NULL,
    next_action text,
    signer_identity_id uuid,
    entry_hash text,
    sig text,
    signed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT execution_events_action_type_check CHECK ((action_type = ANY (ARRAY['code_edit'::text, 'git_commit'::text, 'git_push'::text, 'tool_call'::text, 'status_transition'::text, 'review_verdict'::text, 'other'::text]))),
    CONSTRAINT execution_events_status_check CHECK ((status = ANY (ARRAY['recorded'::text, 'verified'::text, 'disputed'::text])))
);


--
-- Name: execution_events_id_seq; Type: SEQUENCE; Schema: uplift; Owner: -
--

CREATE SEQUENCE uplift.execution_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: execution_events_id_seq; Type: SEQUENCE OWNED BY; Schema: uplift; Owner: -
--

ALTER SEQUENCE uplift.execution_events_id_seq OWNED BY uplift.execution_events.id;


--
-- Name: job_results; Type: TABLE; Schema: uplift; Owner: -
--

CREATE TABLE uplift.job_results (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    issue_id uuid NOT NULL,
    heartbeat_run_id uuid NOT NULL,
    agent_id uuid NOT NULL,
    claimed_status text NOT NULL,
    summary text,
    evidence jsonb DEFAULT '{}'::jsonb NOT NULL,
    after_commit_oid text,
    signer_identity_id uuid NOT NULL,
    entry_hash text NOT NULL,
    sig text,
    signed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: run_issue_map; Type: TABLE; Schema: uplift; Owner: -
--

CREATE TABLE uplift.run_issue_map (
    heartbeat_run_id uuid NOT NULL,
    issue_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE run_issue_map; Type: COMMENT; Schema: uplift; Owner: -
--

COMMENT ON TABLE uplift.run_issue_map IS 'Populate BEFORE heartbeat_runs.context_snapshot is scrubbed (spec 1b §8.3, review F1). Without it, run->issue joins are lost forever for runs that produced no cost_events row. Populated by the idempotent backfill in this file (not by a code hook — patches/10 was cancelled); re-run it before any retention scrub.';


--
-- Name: stuck_findings; Type: TABLE; Schema: uplift; Owner: -
--

CREATE TABLE uplift.stuck_findings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    pattern text NOT NULL,
    agent_id uuid,
    issue_id uuid,
    dedup_key text NOT NULL,
    status text DEFAULT 'open'::text NOT NULL,
    streak_len integer NOT NULL,
    first_seen timestamp with time zone NOT NULL,
    last_seen timestamp with time zone NOT NULL,
    evidence jsonb NOT NULL,
    nudge_comment_id uuid,
    disposition text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE stuck_findings; Type: COMMENT; Schema: uplift; Owner: -
--

COMMENT ON TABLE uplift.stuck_findings IS 'STUCK is a ROW STATE here and nowhere else. It must never be written to issues.status or to agents.paused_at/pause_reason (those belong to the budget engine and would make budget and stuck incidents indistinguishable).';


--
-- Name: COLUMN stuck_findings.evidence; Type: COMMENT; Schema: uplift; Owner: -
--

COMMENT ON COLUMN uplift.stuck_findings.evidence IS 'Whitelisted keys only (event_type, message, level, seq, timestamps, adapterType, promptMetrics) AND a redaction pass stripping key=value pairs and token-like runs ([A-Za-z0-9_-]{20,}) — error messages echo secret-bearing strings verbatim (review N8). NEVER heartbeat_run_events.payload->env and NEVER adapter_config.';


--
-- Name: v_issue_token_efficiency; Type: VIEW; Schema: uplift; Owner: -
--

CREATE VIEW uplift.v_issue_token_efficiency AS
 SELECT i.identifier,
    i.status,
    a.name AS agent,
    a.adapter_type,
    ce.provider,
    ce.model,
    count(DISTINCT ce.heartbeat_run_id) AS runs,
    sum(ce.input_tokens) AS input_tokens,
    sum(ce.output_tokens) AS output_tokens,
    sum(ce.cached_input_tokens) AS cached_input_tokens,
    sum(((ce.input_tokens + ce.cached_input_tokens) + ce.output_tokens)) AS total_tokens_billed_weight,
    sum((ce.input_tokens + ce.output_tokens)) AS total_tokens_uncached
   FROM ((public.cost_events ce
     JOIN public.issues i ON ((i.id = ce.issue_id)))
     JOIN public.agents a ON ((a.id = ce.agent_id)))
  WHERE ((ce.company_id = '28db6ad9-3523-4af5-a3cc-bd827fcea251'::uuid) AND (i.status = 'done'::text) AND (NOT (EXISTS ( SELECT 1
           FROM uplift.cost_event_annotations an
          WHERE ((an.cost_event_id = ce.id) AND an.exclude_from_enforcement)))))
  GROUP BY i.identifier, i.status, a.name, a.adapter_type, ce.provider, ce.model;


--
-- Name: VIEW v_issue_token_efficiency; Type: COMMENT; Schema: uplift; Owner: -
--

COMMENT ON VIEW uplift.v_issue_token_efficiency IS 'Grain: one row per (issue, agent, provider, model). An issue worked by two agents or two models produces two rows — aggregate with count(DISTINCT identifier), never count(*). Source: DB (cost_events), not OTLP.';


--
-- Name: v_adapter_model_efficiency; Type: VIEW; Schema: uplift; Owner: -
--

CREATE VIEW uplift.v_adapter_model_efficiency AS
 SELECT adapter_type,
    provider,
    model,
    count(DISTINCT identifier) AS completed_issues,
    (avg(total_tokens_billed_weight))::bigint AS avg_tokens_billed_weight_per_issue,
    (percentile_cont((0.5)::double precision) WITHIN GROUP (ORDER BY ((total_tokens_billed_weight)::double precision)))::bigint AS p50_tokens_billed_weight_per_issue,
    sum(total_tokens_billed_weight) AS total_tokens_billed_weight,
    sum(total_tokens_uncached) AS total_tokens_uncached
   FROM uplift.v_issue_token_efficiency
  GROUP BY adapter_type, provider, model;


--
-- Name: VIEW v_adapter_model_efficiency; Type: COMMENT; Schema: uplift; Owner: -
--

COMMENT ON VIEW uplift.v_adapter_model_efficiency IS 'completed_issues counts DISTINCT issue identifiers (spec said count(*), which double-counts an issue worked by two agents on the same adapter/provider/model). The avg_/p50_ columns are per underlying (issue,agent,provider,model) ROW, not per distinct issue — read them as per-issue-lane averages.';


--
-- Name: v_agent_daily_tokens; Type: VIEW; Schema: uplift; Owner: -
--

CREATE VIEW uplift.v_agent_daily_tokens AS
 SELECT date_trunc('day'::text, ce.occurred_at) AS day,
    a.name AS agent,
    a.adapter_type,
    ce.provider,
    ce.model,
    ce.billing_type,
    sum(ce.input_tokens) AS input_tokens,
    sum(ce.output_tokens) AS output_tokens,
    sum(ce.cached_input_tokens) AS cached_input_tokens,
    sum(((ce.input_tokens + ce.cached_input_tokens) + ce.output_tokens)) AS total_tokens_billed_weight,
    sum((ce.input_tokens + ce.output_tokens)) AS total_tokens_uncached,
    count(*) AS cost_events
   FROM (public.cost_events ce
     JOIN public.agents a ON ((a.id = ce.agent_id)))
  WHERE ((ce.company_id = '28db6ad9-3523-4af5-a3cc-bd827fcea251'::uuid) AND (NOT (EXISTS ( SELECT 1
           FROM uplift.cost_event_annotations an
          WHERE ((an.cost_event_id = ce.id) AND an.exclude_from_enforcement)))))
  GROUP BY (date_trunc('day'::text, ce.occurred_at)), a.name, a.adapter_type, ce.provider, ce.model, ce.billing_type;


--
-- Name: VIEW v_agent_daily_tokens; Type: COMMENT; Schema: uplift; Owner: -
--

COMMENT ON VIEW uplift.v_agent_daily_tokens IS 'Bucketed on occurred_at (when the usage happened), not created_at (when the ledger row landed). Feeds the textfile bridge series paperclip_tokens_total{agent,adapter,model,kind}. Source: DB.';


--
-- Name: v_document_retention; Type: VIEW; Schema: uplift; Owner: -
--

CREATE VIEW uplift.v_document_retention AS
 SELECT d.id,
    d.title,
    d.updated_at,
    string_agg(DISTINCT i.status, ','::text ORDER BY i.status) AS issue_statuses,
    count(DISTINCT j.issue_id) AS linked_issues,
        CASE
            WHEN (d.title ~~ 'KB/%'::text) THEN 'KEEP_KNOWLEDGE'::text
            WHEN (count(j.issue_id) = 0) THEN 'REVIEW_ORPHAN'::text
            WHEN bool_or((i.status = 'cancelled'::text)) THEN 'KEEP_CANCELLED_MAY_RESUME'::text
            WHEN bool_or((i.status <> 'done'::text)) THEN 'KEEP_LIVE_ISSUE'::text
            WHEN (d.updated_at >= (now() - '30 days'::interval)) THEN 'KEEP_RECENT'::text
            ELSE 'SAFE_TO_DELETE'::text
        END AS disposition
   FROM ((public.documents d
     LEFT JOIN public.issue_documents j ON ((j.document_id = d.id)))
     LEFT JOIN public.issues i ON ((i.id = j.issue_id)))
  WHERE (d.company_id = '28db6ad9-3523-4af5-a3cc-bd827fcea251'::uuid)
  GROUP BY d.id, d.title, d.updated_at;


--
-- Name: VIEW v_document_retention; Type: COMMENT; Schema: uplift; Owner: -
--

COMMENT ON VIEW uplift.v_document_retention IS 'Disposition for every document. SAFE_TO_DELETE requires: not KB-prefixed, linked to at least one issue, EVERY linked issue terminal (done/cancelled), and untouched 30+ days. Continuation Summaries on live issues are load-bearing — heartbeat.js, run-liveness.js and routes/issues.js all read them.';


--
-- Name: v_kb_documents; Type: VIEW; Schema: uplift; Owner: -
--

CREATE VIEW uplift.v_kb_documents AS
 SELECT id,
    title,
    split_part(SUBSTRING(title FROM 4), '/'::text, 1) AS kb_domain,
    SUBSTRING(title FROM 4) AS kb_path,
    latest_revision_number,
    created_by_agent_id,
    updated_by_agent_id,
    ((updated_by_agent_id IS NOT NULL) AND (updated_by_agent_id <> created_by_agent_id)) AS cross_agent_edited,
    "substring"(latest_body, 'confidence:[[:space:]]*([a-z]+)'::text) AS confidence,
    "substring"(latest_body, 'verified_by:[[:space:]]*([^\n]+)'::text) AS verified_by,
    "substring"(latest_body, 'verified_on:[[:space:]]*([0-9-]+)'::text) AS verified_on,
    length(latest_body) AS body_bytes,
    created_at,
    updated_at
   FROM public.documents d
  WHERE ((company_id = '28db6ad9-3523-4af5-a3cc-bd827fcea251'::uuid) AND (title ~~ 'KB/%'::text));


--
-- Name: VIEW v_kb_documents; Type: COMMENT; Schema: uplift; Owner: -
--

COMMENT ON VIEW uplift.v_kb_documents IS 'The a2a shared-knowledge corpus: documents following the KB/<domain>/<topic> title convention. Everything else in `documents` is a work artifact. Provenance is parsed from YAML frontmatter in the body because documents.source_trust is platform-owned quarantine machinery and must not be written to.';


--
-- Name: v_run_metrics; Type: VIEW; Schema: uplift; Owner: -
--

CREATE VIEW uplift.v_run_metrics AS
 SELECT hr.id AS heartbeat_run_id,
    hr.company_id,
    hr.agent_id,
    COALESCE(ce.issue_id, rim.issue_id,
        CASE
            WHEN ((hr.context_snapshot ->> 'issueId'::text) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'::text) THEN ((hr.context_snapshot ->> 'issueId'::text))::uuid
            ELSE NULL::uuid
        END) AS issue_id,
    ce.id AS cost_event_id,
    hr.status AS run_status,
    hr.invocation_source,
    COALESCE((hr.usage_json ->> 'usageSource'::text), 'unknown'::text) AS usage_source,
    COALESCE(ce.provider, 'unknown'::text) AS provider,
    COALESCE(ce.model, 'unknown'::text) AS model,
    COALESCE(ce.input_tokens, 0) AS input_tokens,
    COALESCE(ce.output_tokens, 0) AS output_tokens,
    COALESCE(ce.cached_input_tokens, 0) AS cached_input_tokens,
    ((COALESCE(ce.input_tokens, 0) + COALESCE(ce.cached_input_tokens, 0)) + COALESCE(ce.output_tokens, 0)) AS total_tokens_billed_weight,
    (COALESCE(ce.input_tokens, 0) + COALESCE(ce.output_tokens, 0)) AS total_tokens_uncached,
    ce.cost_cents,
    ce.cost_status,
    ((EXTRACT(epoch FROM (hr.finished_at - hr.started_at)) * (1000)::numeric))::bigint AS duration_ms,
    COALESCE(ce.occurred_at, hr.finished_at) AS occurred_at,
    hr.started_at,
    hr.finished_at,
    hr.created_at AS run_created_at
   FROM ((public.heartbeat_runs hr
     LEFT JOIN public.cost_events ce ON ((ce.heartbeat_run_id = hr.id)))
     LEFT JOIN uplift.run_issue_map rim ON ((rim.heartbeat_run_id = hr.id)))
  WHERE ((hr.company_id = '28db6ad9-3523-4af5-a3cc-bd827fcea251'::uuid) AND (hr.finished_at IS NOT NULL));


--
-- Name: VIEW v_run_metrics; Type: COMMENT; Schema: uplift; Owner: -
--

COMMENT ON VIEW uplift.v_run_metrics IS 'Native-substrate replacement for the cancelled patches/10 metering hook (KB R1). One row per finished run, plus one extra row per additional cost_events row on the same run. Rows with cost_event_id IS NULL are real runs that produced no ledger event — they are the denominator, not noise. issue_id falls back cost_events -> uplift.run_issue_map -> context_snapshot, so it survives a context_snapshot scrub once the run_issue_map backfill has been run.';


--
-- Name: v_usage_id_split; Type: VIEW; Schema: uplift; Owner: -
--

CREATE VIEW uplift.v_usage_id_split AS
 SELECT date_trunc('day'::text, occurred_at) AS day,
    agent_id,
    usage_id,
    model,
    sum(input_tokens) AS input_tokens,
    sum(output_tokens) AS output_tokens,
    sum(cached_input_tokens) AS cached_input_tokens,
    sum(tool_calls) AS tool_calls,
    sum(duration_ms) AS duration_ms,
    count(*) AS turn_rows
   FROM uplift.agent_turn_metrics
  WHERE (granularity = 'turn'::text)
  GROUP BY (date_trunc('day'::text, occurred_at)), agent_id, usage_id, model;


--
-- Name: VIEW v_usage_id_split; Type: COMMENT; Schema: uplift; Owner: -
--

COMMENT ON VIEW uplift.v_usage_id_split IS 'Returns zero rows until experimental.upliftTurnMetrics is enabled and the transcript parser ships. That is expected, not a defect.';


--
-- Name: v_wake_forensics; Type: VIEW; Schema: uplift; Owner: -
--

CREATE VIEW uplift.v_wake_forensics AS
 SELECT w.requested_at,
    a.name AS agent,
    w.source,
    w.status,
    w.coalesced_count,
    (w.payload ->> 'issueId'::text) AS issue_id,
    w.reason,
    w.error,
    (w.claimed_at - w.requested_at) AS queue_latency,
    (w.finished_at - w.claimed_at) AS run_latency,
    hr.status AS run_status,
    hr.exit_code,
    hr.error_code
   FROM ((public.agent_wakeup_requests w
     JOIN public.agents a ON ((a.id = w.agent_id)))
     LEFT JOIN public.heartbeat_runs hr ON ((hr.wakeup_request_id = w.id)))
  WHERE (w.company_id = '28db6ad9-3523-4af5-a3cc-bd827fcea251'::uuid);


--
-- Name: VIEW v_wake_forensics; Type: COMMENT; Schema: uplift; Owner: -
--

COMMENT ON VIEW uplift.v_wake_forensics IS 'Index-supported by agent_wakeup_requests(company_id, requested_at) — always filter on requested_at when querying, the table is ~160 MB. The LEFT JOIN can fan out if one wake maps to several runs (retries); count DISTINCT where that matters.';


--
-- Name: v_wake_storm_daily; Type: VIEW; Schema: uplift; Owner: -
--

CREATE VIEW uplift.v_wake_storm_daily AS
 SELECT date_trunc('day'::text, requested_at) AS day,
    agent,
    source,
    count(*) AS wakes,
    sum(coalesced_count) AS coalesced,
    count(*) FILTER (WHERE (status = 'completed'::text)) AS completed,
    count(*) FILTER (WHERE (status = 'skipped'::text)) AS skipped,
    count(*) FILTER (WHERE (status = ANY (ARRAY['failed'::text, 'timed_out'::text]))) AS failed_or_timed_out,
    count(*) FILTER (WHERE (status <> 'completed'::text)) AS non_completed
   FROM uplift.v_wake_forensics
  GROUP BY (date_trunc('day'::text, requested_at)), agent, source;


--
-- Name: VIEW v_wake_storm_daily; Type: COMMENT; Schema: uplift; Owner: -
--

COMMENT ON VIEW uplift.v_wake_storm_daily IS 'Storm signature: high wakes with skipped ~= wakes and completed ~= 0 (the CMO 6,852/6,852-skipped pattern). non_completed is everything that is not status=completed. Spec 1b §5.3 said "<> finished"; no such status exists in this DB — see the header comment above this view before changing it.';


--
-- Name: audit_chain seq; Type: DEFAULT; Schema: uplift; Owner: -
--

ALTER TABLE ONLY uplift.audit_chain ALTER COLUMN seq SET DEFAULT nextval('uplift.audit_chain_seq_seq'::regclass);


--
-- Name: execution_events id; Type: DEFAULT; Schema: uplift; Owner: -
--

ALTER TABLE ONLY uplift.execution_events ALTER COLUMN id SET DEFAULT nextval('uplift.execution_events_id_seq'::regclass);


--
-- Name: agent_daily_rollup agent_daily_rollup_pkey; Type: CONSTRAINT; Schema: uplift; Owner: -
--

ALTER TABLE ONLY uplift.agent_daily_rollup
    ADD CONSTRAINT agent_daily_rollup_pkey PRIMARY KEY (day, agent_id, adapter_type, provider, model, usage_id);


--
-- Name: agent_identities agent_identities_pkey; Type: CONSTRAINT; Schema: uplift; Owner: -
--

ALTER TABLE ONLY uplift.agent_identities
    ADD CONSTRAINT agent_identities_pkey PRIMARY KEY (id);


--
-- Name: agent_turn_metrics agent_turn_metrics_pkey; Type: CONSTRAINT; Schema: uplift; Owner: -
--

ALTER TABLE ONLY uplift.agent_turn_metrics
    ADD CONSTRAINT agent_turn_metrics_pkey PRIMARY KEY (id);


--
-- Name: audit_chain audit_chain_pkey; Type: CONSTRAINT; Schema: uplift; Owner: -
--

ALTER TABLE ONLY uplift.audit_chain
    ADD CONSTRAINT audit_chain_pkey PRIMARY KEY (seq);


--
-- Name: audit_chain audit_chain_source_uq; Type: CONSTRAINT; Schema: uplift; Owner: -
--

ALTER TABLE ONLY uplift.audit_chain
    ADD CONSTRAINT audit_chain_source_uq UNIQUE (source_table, source_id);


--
-- Name: budget_hold_anchors budget_hold_anchors_pkey; Type: CONSTRAINT; Schema: uplift; Owner: -
--

ALTER TABLE ONLY uplift.budget_hold_anchors
    ADD CONSTRAINT budget_hold_anchors_pkey PRIMARY KEY (incident_id);


--
-- Name: cost_event_annotations cost_event_annotations_pkey; Type: CONSTRAINT; Schema: uplift; Owner: -
--

ALTER TABLE ONLY uplift.cost_event_annotations
    ADD CONSTRAINT cost_event_annotations_pkey PRIMARY KEY (id);


--
-- Name: digest_ledger digest_ledger_pkey; Type: CONSTRAINT; Schema: uplift; Owner: -
--

ALTER TABLE ONLY uplift.digest_ledger
    ADD CONSTRAINT digest_ledger_pkey PRIMARY KEY (id);


--
-- Name: execution_events execution_events_pkey; Type: CONSTRAINT; Schema: uplift; Owner: -
--

ALTER TABLE ONLY uplift.execution_events
    ADD CONSTRAINT execution_events_pkey PRIMARY KEY (id);


--
-- Name: execution_events execution_events_run_seq_uq; Type: CONSTRAINT; Schema: uplift; Owner: -
--

ALTER TABLE ONLY uplift.execution_events
    ADD CONSTRAINT execution_events_run_seq_uq UNIQUE (heartbeat_run_id, seq);


--
-- Name: job_results job_results_one_per_run; Type: CONSTRAINT; Schema: uplift; Owner: -
--

ALTER TABLE ONLY uplift.job_results
    ADD CONSTRAINT job_results_one_per_run UNIQUE (heartbeat_run_id);


--
-- Name: job_results job_results_pkey; Type: CONSTRAINT; Schema: uplift; Owner: -
--

ALTER TABLE ONLY uplift.job_results
    ADD CONSTRAINT job_results_pkey PRIMARY KEY (id);


--
-- Name: run_issue_map run_issue_map_pkey; Type: CONSTRAINT; Schema: uplift; Owner: -
--

ALTER TABLE ONLY uplift.run_issue_map
    ADD CONSTRAINT run_issue_map_pkey PRIMARY KEY (heartbeat_run_id);


--
-- Name: stuck_findings stuck_findings_pkey; Type: CONSTRAINT; Schema: uplift; Owner: -
--

ALTER TABLE ONLY uplift.stuck_findings
    ADD CONSTRAINT stuck_findings_pkey PRIMARY KEY (id);


--
-- Name: agent_identities_active_instance_uq; Type: INDEX; Schema: uplift; Owner: -
--

CREATE UNIQUE INDEX agent_identities_active_instance_uq ON uplift.agent_identities USING btree (company_id, agent_id) WHERE ((identity_scope = 'instance'::text) AND (key_status = 'active'::text));


--
-- Name: agent_identities_active_persona_uq; Type: INDEX; Schema: uplift; Owner: -
--

CREATE UNIQUE INDEX agent_identities_active_persona_uq ON uplift.agent_identities USING btree (company_id, persona_key) WHERE ((identity_scope = 'persona'::text) AND (key_status = 'active'::text));


--
-- Name: agent_identities_company_idx; Type: INDEX; Schema: uplift; Owner: -
--

CREATE INDEX agent_identities_company_idx ON uplift.agent_identities USING btree (company_id, key_status);


--
-- Name: atm_agent_occurred_idx; Type: INDEX; Schema: uplift; Owner: -
--

CREATE INDEX atm_agent_occurred_idx ON uplift.agent_turn_metrics USING btree (agent_id, occurred_at);


--
-- Name: atm_company_occurred_idx; Type: INDEX; Schema: uplift; Owner: -
--

CREATE INDEX atm_company_occurred_idx ON uplift.agent_turn_metrics USING btree (company_id, occurred_at);


--
-- Name: atm_created_at_idx; Type: INDEX; Schema: uplift; Owner: -
--

CREATE INDEX atm_created_at_idx ON uplift.agent_turn_metrics USING btree (created_at);


--
-- Name: atm_issue_idx; Type: INDEX; Schema: uplift; Owner: -
--

CREATE INDEX atm_issue_idx ON uplift.agent_turn_metrics USING btree (issue_id) WHERE (issue_id IS NOT NULL);


--
-- Name: atm_run_seq_usage_idx; Type: INDEX; Schema: uplift; Owner: -
--

CREATE UNIQUE INDEX atm_run_seq_usage_idx ON uplift.agent_turn_metrics USING btree (heartbeat_run_id, granularity, seq, usage_id, model);


--
-- Name: audit_chain_company_seq_idx; Type: INDEX; Schema: uplift; Owner: -
--

CREATE INDEX audit_chain_company_seq_idx ON uplift.audit_chain USING btree (company_id, seq);


--
-- Name: audit_chain_unsigned_idx; Type: INDEX; Schema: uplift; Owner: -
--

CREATE INDEX audit_chain_unsigned_idx ON uplift.audit_chain USING btree (company_id, seq) WHERE (sig IS NULL);


--
-- Name: budget_hold_anchors_issue_idx; Type: INDEX; Schema: uplift; Owner: -
--

CREATE INDEX budget_hold_anchors_issue_idx ON uplift.budget_hold_anchors USING btree (issue_id);


--
-- Name: cost_event_annotations_enforcement_idx; Type: INDEX; Schema: uplift; Owner: -
--

CREATE INDEX cost_event_annotations_enforcement_idx ON uplift.cost_event_annotations USING btree (cost_event_id) WHERE exclude_from_enforcement;


--
-- Name: cost_event_annotations_event_kind_idx; Type: INDEX; Schema: uplift; Owner: -
--

CREATE UNIQUE INDEX cost_event_annotations_event_kind_idx ON uplift.cost_event_annotations USING btree (cost_event_id, kind);


--
-- Name: digest_ledger_active_item_uq; Type: INDEX; Schema: uplift; Owner: -
--

CREATE UNIQUE INDEX digest_ledger_active_item_uq ON uplift.digest_ledger USING btree (company_id, item_key) WHERE (disposition = 'pending'::text);


--
-- Name: digest_ledger_company_bucket_idx; Type: INDEX; Schema: uplift; Owner: -
--

CREATE INDEX digest_ledger_company_bucket_idx ON uplift.digest_ledger USING btree (company_id, bucket, last_surfaced_at);


--
-- Name: digest_ledger_pending_age_idx; Type: INDEX; Schema: uplift; Owner: -
--

CREATE INDEX digest_ledger_pending_age_idx ON uplift.digest_ledger USING btree (company_id, first_surfaced_at) WHERE (disposition = 'pending'::text);


--
-- Name: doc_purge_20260805_pk; Type: INDEX; Schema: uplift; Owner: -
--

CREATE UNIQUE INDEX doc_purge_20260805_pk ON uplift.doc_purge_20260805 USING btree (id);


--
-- Name: execution_events_agent_idx; Type: INDEX; Schema: uplift; Owner: -
--

CREATE INDEX execution_events_agent_idx ON uplift.execution_events USING btree (agent_id, created_at);


--
-- Name: execution_events_company_run_idx; Type: INDEX; Schema: uplift; Owner: -
--

CREATE INDEX execution_events_company_run_idx ON uplift.execution_events USING btree (company_id, heartbeat_run_id);


--
-- Name: execution_events_issue_idx; Type: INDEX; Schema: uplift; Owner: -
--

CREATE INDEX execution_events_issue_idx ON uplift.execution_events USING btree (company_id, issue_id, created_at) WHERE (issue_id IS NOT NULL);


--
-- Name: job_results_company_issue_idx; Type: INDEX; Schema: uplift; Owner: -
--

CREATE INDEX job_results_company_issue_idx ON uplift.job_results USING btree (company_id, issue_id, created_at);


--
-- Name: job_results_unsigned_idx; Type: INDEX; Schema: uplift; Owner: -
--

CREATE INDEX job_results_unsigned_idx ON uplift.job_results USING btree (company_id, created_at) WHERE (sig IS NULL);


--
-- Name: run_issue_map_issue_idx; Type: INDEX; Schema: uplift; Owner: -
--

CREATE INDEX run_issue_map_issue_idx ON uplift.run_issue_map USING btree (issue_id);


--
-- Name: stuck_findings_active_dedup; Type: INDEX; Schema: uplift; Owner: -
--

CREATE UNIQUE INDEX stuck_findings_active_dedup ON uplift.stuck_findings USING btree (dedup_key) WHERE (status = ANY (ARRAY['open'::text, 'nudged'::text, 'stuck'::text]));


--
-- Name: stuck_findings_company_status_idx; Type: INDEX; Schema: uplift; Owner: -
--

CREATE INDEX stuck_findings_company_status_idx ON uplift.stuck_findings USING btree (company_id, status, last_seen);


--
-- Name: audit_chain audit_chain_append_only; Type: TRIGGER; Schema: uplift; Owner: -
--

CREATE TRIGGER audit_chain_append_only BEFORE DELETE OR UPDATE ON uplift.audit_chain FOR EACH ROW EXECUTE FUNCTION uplift.audit_chain_guard();


--
-- Name: agent_identities agent_identities_superseded_by_identity_id_fkey; Type: FK CONSTRAINT; Schema: uplift; Owner: -
--

ALTER TABLE ONLY uplift.agent_identities
    ADD CONSTRAINT agent_identities_superseded_by_identity_id_fkey FOREIGN KEY (superseded_by_identity_id) REFERENCES uplift.agent_identities(id);


--
-- Name: audit_chain audit_chain_signer_identity_id_fkey; Type: FK CONSTRAINT; Schema: uplift; Owner: -
--

ALTER TABLE ONLY uplift.audit_chain
    ADD CONSTRAINT audit_chain_signer_identity_id_fkey FOREIGN KEY (signer_identity_id) REFERENCES uplift.agent_identities(id);


--
-- Name: execution_events execution_events_signer_identity_id_fkey; Type: FK CONSTRAINT; Schema: uplift; Owner: -
--

ALTER TABLE ONLY uplift.execution_events
    ADD CONSTRAINT execution_events_signer_identity_id_fkey FOREIGN KEY (signer_identity_id) REFERENCES uplift.agent_identities(id);


--
-- Name: job_results job_results_signer_identity_id_fkey; Type: FK CONSTRAINT; Schema: uplift; Owner: -
--

ALTER TABLE ONLY uplift.job_results
    ADD CONSTRAINT job_results_signer_identity_id_fkey FOREIGN KEY (signer_identity_id) REFERENCES uplift.agent_identities(id);


--
-- PostgreSQL database dump complete
--

\unrestrict H77M4daUiarkRbKl64d4YR7N99vf7Z0KCbeB4rXnz1FfLwdhFQ9rAO0Qg5UGPtH

