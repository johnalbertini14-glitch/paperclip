--
-- PostgreSQL database dump
--

\restrict kruxrSR3rfDfiu7HBsx07WzR94MUWxeagqxAabjIq5AneSX2n7E1c2fMtTGaKWV

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
-- Name: drizzle; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA drizzle;


--
-- Name: uplift; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA uplift;


--
-- Name: SCHEMA uplift; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA uplift IS 'Operator-owned uplift objects (Phase 1). Board directive fcf79097 on REVA-17863: agents must not read, edit, or reason over these objects, and must not treat them as budget or enforcement signals. Additive only; no FKs to upstream tables.';


--
-- Name: fuzzystrmatch; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS fuzzystrmatch WITH SCHEMA public;


--
-- Name: EXTENSION fuzzystrmatch; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION fuzzystrmatch IS 'determine similarities and distance between strings';


--
-- Name: pg_trgm; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;


--
-- Name: EXTENSION pg_trgm; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_trgm IS 'text similarity measurement and index searching based on trigrams';


--
-- Name: freeze_reva29375_block_agent_execution(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.freeze_reva29375_block_agent_execution() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
begin
  -- Explicitly approved durable disk-capacity control root.
  if new.id = 'b144ea5c-9216-464b-91ee-4ad044e5363f'::uuid then
    return new;
  end if;

  -- Approved operations may create incident/follow-up cards. Preserve their
  -- provenance by requiring an ancestor that is either the approved durable
  -- controls root or a native approved routine/review execution.
  if new.parent_id is not null and exists (
    with recursive lineage(id, parent_id, origin_kind) as (
      select i.id, i.parent_id, i.origin_kind
        from public.issues i
       where i.id = new.parent_id
      union
      select p.id, p.parent_id, p.origin_kind
        from public.issues p
        join lineage l on p.id = l.parent_id
    )
    select 1
      from lineage
     where id = 'b144ea5c-9216-464b-91ee-4ad044e5363f'::uuid
        or origin_kind in ('routine_execution', 'issue_productivity_review')
  ) then
    return new;
  end if;

  raise exception $m$REVA-29375 freeze: Paperclips Set Up (d15b63fa) is report-only for agents. Creating unassigned reports is allowed; agent assignment/checkout/execution of reports is not. Approved ops routines and their provenance-linked descendants are exempt. Hermes owns Paperclip fixes.$m$;
  return null;
end;
$_$;


--
-- Name: paperclip_bump_issue_status_version(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.paperclip_bump_issue_status_version() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
	IF NEW."status" IS DISTINCT FROM OLD."status" THEN
		NEW."status_version" := OLD."status_version" + 1;
	END IF;
	RETURN NEW;
END;
$$;


--
-- Name: paperclip_company_secret_versions_fingerprint_compat(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.paperclip_company_secret_versions_fingerprint_compat() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.fingerprint_sha256 IS NULL OR NEW.fingerprint_sha256 = '' THEN
    NEW.fingerprint_sha256 := NEW.value_sha256;
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: FUNCTION paperclip_company_secret_versions_fingerprint_compat(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.paperclip_company_secret_versions_fingerprint_compat() IS 'REVA-10194 compatibility shim: fill company_secret_versions.fingerprint_sha256 from value_sha256 for runtimes that do not know the fingerprint column.';


--
-- Name: paperclip_company_secrets_key_compat(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.paperclip_company_secrets_key_compat() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.key IS NULL OR NEW.key = '' THEN
    NEW.key := NEW.name;
  ELSIF TG_OP = 'UPDATE'
    AND OLD.key IS NOT DISTINCT FROM OLD.name
    AND NEW.key IS NOT DISTINCT FROM OLD.key
    AND NEW.name IS DISTINCT FROM OLD.name THEN
    NEW.key := NEW.name;
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: FUNCTION paperclip_company_secrets_key_compat(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.paperclip_company_secrets_key_compat() IS 'REVA-10194 compatibility shim: fill company_secrets.key from name for runtimes that do not know the key column.';


--
-- Name: paperclip_temp_guard_stale_review_wait_20260717(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.paperclip_temp_guard_stale_review_wait_20260717() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_body text;
  v_issue_id uuid;
  v_company_id uuid;
  v_status text;
  v_execution_status text;
  v_identifier text;
  v_replacement constant text := '- Resume executor work on the requested changes. Post a concise evidence comment, then transition the issue to `done` so native review resumes; if that transition fails, record the exact error as an explicit blocker.';
  v_invalid constant text := '- Wait for reviewer feedback or approval before continuing executor work.';
BEGIN
  IF TG_TABLE_NAME = 'documents' THEN
    v_body := NEW.latest_body;
    v_company_id := NEW.company_id;
    SELECT i.id,i.status,i.execution_state->>'status',i.identifier
      INTO v_issue_id,v_status,v_execution_status,v_identifier
    FROM issue_documents idoc
    JOIN issues i ON i.id=idoc.issue_id
    WHERE idoc.document_id=NEW.id AND idoc.key='continuation-summary'
    LIMIT 1;
  ELSIF TG_TABLE_NAME = 'document_revisions' THEN
    v_body := NEW.body;
    v_company_id := NEW.company_id;
    SELECT i.id,i.status,i.execution_state->>'status',i.identifier
      INTO v_issue_id,v_status,v_execution_status,v_identifier
    FROM issue_documents idoc
    JOIN issues i ON i.id=idoc.issue_id
    WHERE idoc.document_id=NEW.document_id AND idoc.key='continuation-summary'
    LIMIT 1;
  ELSE
    RETURN NEW;
  END IF;

  IF v_issue_id IS NULL AND NEW.title = 'Continuation Summary' THEN
    v_identifier := substring(v_body from '- Issue: ([A-Z]+-[0-9]+)');
    IF v_identifier IS NOT NULL THEN
      SELECT i.id,i.status,i.execution_state->>'status'
        INTO v_issue_id,v_status,v_execution_status
      FROM issues i
      WHERE i.company_id=v_company_id AND i.identifier=v_identifier
      LIMIT 1;
    END IF;
  END IF;

  IF v_issue_id IS NOT NULL
     AND v_status='in_progress'
     AND v_execution_status='changes_requested'
     AND position(v_invalid in coalesce(v_body,''))>0 THEN
    v_body := replace(v_body,v_invalid,v_replacement);
    IF TG_TABLE_NAME='documents' THEN
      NEW.latest_body := v_body;
      INSERT INTO activity_log
        (id,company_id,actor_type,actor_id,action,entity_type,entity_id,details)
      VALUES
        (gen_random_uuid(),v_company_id,'user','local-board','issue.continuation_summary_hotpatch_rewrite','issue',v_issue_id,
         jsonb_build_object('identifier',v_identifier,'temporaryGuard','paperclip_temp_guard_stale_review_wait_20260717','operation',TG_OP));
    ELSE
      NEW.body := v_body;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: remove_deleted_agent_from_inbox_policy_allowlists(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.remove_deleted_agent_from_inbox_policy_allowlists() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
	UPDATE "user_inbox_agent_policies"
	SET
		"allowed_agent_ids" = "allowed_agent_ids" - OLD."id"::text,
		"updated_at" = now()
	WHERE "allowed_agent_ids" ? OLD."id"::text;
	RETURN OLD;
END;
$$;


--
-- Name: sync_ai_provider_default(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_ai_provider_default() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO ai_provider_defaults (company_id, user_id, provider, grant_id, updated_at)
    VALUES (NEW.company_id, NEW.user_id, NEW.provider, NEW.grant_id, NEW.updated_at)
    ON CONFLICT (company_id, user_id, provider) DO NOTHING;
  ELSE
    INSERT INTO ai_provider_defaults (company_id, user_id, provider, grant_id, updated_at)
    VALUES (NEW.company_id, NEW.user_id, NEW.provider, NEW.grant_id, NEW.updated_at)
    ON CONFLICT (company_id, user_id, provider) DO UPDATE
    SET grant_id = EXCLUDED.grant_id, updated_at = EXCLUDED.updated_at;
  END IF;
  RETURN NEW;
END $$;


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
-- Name: __drizzle_migrations; Type: TABLE; Schema: drizzle; Owner: -
--

CREATE TABLE drizzle.__drizzle_migrations (
    id integer NOT NULL,
    hash text NOT NULL,
    created_at bigint
);


--
-- Name: __drizzle_migrations_id_seq; Type: SEQUENCE; Schema: drizzle; Owner: -
--

CREATE SEQUENCE drizzle.__drizzle_migrations_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: __drizzle_migrations_id_seq; Type: SEQUENCE OWNED BY; Schema: drizzle; Owner: -
--

ALTER SEQUENCE drizzle.__drizzle_migrations_id_seq OWNED BY drizzle.__drizzle_migrations.id;


--
-- Name: account; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.account (
    id text NOT NULL,
    account_id text NOT NULL,
    provider_id text NOT NULL,
    user_id text NOT NULL,
    access_token text,
    refresh_token text,
    id_token text,
    access_token_expires_at timestamp with time zone,
    refresh_token_expires_at timestamp with time zone,
    scope text,
    password text,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    issuer text NOT NULL
);


--
-- Name: activity_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.activity_log (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    actor_type text DEFAULT 'system'::text NOT NULL,
    actor_id text NOT NULL,
    action text NOT NULL,
    entity_type text NOT NULL,
    entity_id text NOT NULL,
    agent_id uuid,
    details jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    run_id uuid,
    responsible_user_id text
);


--
-- Name: adapter_auth_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.adapter_auth_sessions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    environment_id uuid NOT NULL,
    adapter_type text NOT NULL,
    started_by_user_id text NOT NULL,
    provider_lease_id text,
    status text DEFAULT 'starting'::text NOT NULL,
    expires_at timestamp with time zone,
    finished_at timestamp with time zone,
    failure_reason text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    promotion_expires_at timestamp with time zone,
    public_session_id character varying(128) NOT NULL,
    bound_at timestamp with time zone,
    result_claim jsonb,
    ai_connection jsonb,
    connection_id uuid,
    connection_grant_id uuid,
    connection_method text
);


--
-- Name: agent_api_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_api_keys (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    agent_id uuid NOT NULL,
    company_id uuid NOT NULL,
    name text NOT NULL,
    key_hash text NOT NULL,
    last_used_at timestamp with time zone,
    revoked_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    scope_config jsonb,
    responsible_user_id text
);


--
-- Name: agent_config_revisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_config_revisions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    agent_id uuid NOT NULL,
    created_by_agent_id uuid,
    created_by_user_id text,
    source text DEFAULT 'patch'::text NOT NULL,
    rolled_back_from_revision_id uuid,
    changed_keys jsonb DEFAULT '[]'::jsonb NOT NULL,
    before_config jsonb NOT NULL,
    after_config jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: agent_instruction_heads; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_instruction_heads (
    company_id uuid NOT NULL,
    agent_id uuid NOT NULL,
    entry_file text NOT NULL,
    revision_id uuid NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: agent_instruction_revisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_instruction_revisions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    agent_id uuid NOT NULL,
    entry_file text NOT NULL,
    content_base64 text NOT NULL,
    content_hash text NOT NULL,
    byte_length integer NOT NULL,
    parent_revision_id uuid,
    base_revision_id uuid,
    restored_from_revision_id uuid,
    actor_agent_id uuid,
    actor_user_id text,
    responsible_user_id text,
    source_run_id uuid,
    source text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: agent_instruction_working_copies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_instruction_working_copies (
    run_id uuid NOT NULL,
    company_id uuid NOT NULL,
    agent_id uuid NOT NULL,
    responsible_user_id text NOT NULL,
    entry_file text NOT NULL,
    base_revision_id uuid,
    base_hash text NOT NULL,
    local_root text NOT NULL,
    execution_root text NOT NULL,
    location text NOT NULL,
    state text DEFAULT 'prepared'::text NOT NULL,
    candidate_base64 text,
    candidate_hash text,
    error_code text,
    error_message text,
    receipt jsonb,
    process_stopped_at timestamp with time zone,
    attempts integer DEFAULT 0 NOT NULL,
    next_attempt_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: agent_memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_memberships (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    agent_id uuid NOT NULL,
    user_id text NOT NULL,
    state text DEFAULT 'joined'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    starred_at timestamp with time zone
);


--
-- Name: agent_runtime_state; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_runtime_state (
    agent_id uuid NOT NULL,
    company_id uuid NOT NULL,
    adapter_type text NOT NULL,
    session_id text,
    state_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    last_run_id uuid,
    last_run_status text,
    total_input_tokens bigint DEFAULT 0 NOT NULL,
    total_output_tokens bigint DEFAULT 0 NOT NULL,
    total_cached_input_tokens bigint DEFAULT 0 NOT NULL,
    total_cost_cents bigint DEFAULT 0 NOT NULL,
    last_error text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: agent_session_goal_actions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_session_goal_actions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    session_id uuid NOT NULL,
    request_id text NOT NULL,
    action text NOT NULL,
    payload_json jsonb NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    result_json jsonb,
    error text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    delivered_at timestamp with time zone,
    completed_at timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: agent_task_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_task_sessions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    agent_id uuid NOT NULL,
    adapter_type text NOT NULL,
    task_key text NOT NULL,
    session_params_json jsonb,
    session_display_id text,
    last_run_id uuid,
    last_error text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    goal_capability_json jsonb,
    goal_json jsonb,
    goal_status text,
    goal_desired_state text,
    goal_source_id text,
    goal_source_cursor bigint,
    goal_revision integer DEFAULT 0 NOT NULL,
    goal_observed_at timestamp with time zone
);


--
-- Name: agent_wakeup_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_wakeup_requests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    agent_id uuid NOT NULL,
    source text NOT NULL,
    trigger_detail text,
    reason text,
    payload jsonb,
    status text DEFAULT 'queued'::text NOT NULL,
    coalesced_count integer DEFAULT 0 NOT NULL,
    requested_by_actor_type text,
    requested_by_actor_id text,
    idempotency_key text,
    run_id uuid,
    requested_at timestamp with time zone DEFAULT now() NOT NULL,
    claimed_at timestamp with time zone,
    finished_at timestamp with time zone,
    error text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: agents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agents (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    name text NOT NULL,
    role text DEFAULT 'general'::text NOT NULL,
    title text,
    status text DEFAULT 'idle'::text NOT NULL,
    reports_to uuid,
    capabilities text,
    adapter_type text DEFAULT 'process'::text NOT NULL,
    adapter_config jsonb DEFAULT '{}'::jsonb NOT NULL,
    budget_monthly_cents integer DEFAULT 0 NOT NULL,
    spent_monthly_cents integer DEFAULT 0 NOT NULL,
    last_heartbeat_at timestamp with time zone,
    metadata jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    runtime_config jsonb DEFAULT '{}'::jsonb NOT NULL,
    permissions jsonb DEFAULT '{}'::jsonb NOT NULL,
    icon text,
    pause_reason text,
    paused_at timestamp with time zone,
    default_environment_id uuid,
    session_token_ceiling integer,
    error_reason text,
    appearance jsonb
);


--
-- Name: COLUMN agents.session_token_ceiling; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.agents.session_token_ceiling IS 'Max cumulative input+output tokens per adapter session. NULL = no ceiling.';


--
-- Name: ai_connection_defaults; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_connection_defaults (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    user_id text NOT NULL,
    provider text NOT NULL,
    method text NOT NULL,
    grant_id uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ai_connection_defaults_method_check CHECK ((method = ANY (ARRAY['subscription'::text, 'api_key'::text]))),
    CONSTRAINT ai_connection_defaults_provider_check CHECK ((provider = ANY (ARRAY['anthropic'::text, 'openai'::text, 'openrouter'::text, 'xai'::text])))
);


--
-- Name: ai_connection_pools; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_connection_pools (
    id uuid NOT NULL,
    company_id uuid NOT NULL,
    plugin_key text NOT NULL,
    config jsonb NOT NULL,
    revision integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: ai_connection_router_cursors; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_connection_router_cursors (
    pool_id uuid NOT NULL,
    company_id uuid NOT NULL,
    last_member_id text,
    version integer DEFAULT 0 NOT NULL
);


--
-- Name: ai_connection_task_pins; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_connection_task_pins (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    pool_id uuid NOT NULL,
    agent_id uuid NOT NULL,
    task_key text NOT NULL,
    selection jsonb NOT NULL,
    member jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: ai_provider_defaults; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_provider_defaults (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    user_id text NOT NULL,
    provider text NOT NULL,
    grant_id uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ai_provider_defaults_provider_check CHECK ((provider = ANY (ARRAY['anthropic'::text, 'openai'::text, 'openrouter'::text, 'xai'::text])))
);


--
-- Name: announcement_dismissals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.announcement_dismissals (
    user_id text NOT NULL,
    announcement_id text NOT NULL,
    dismissed_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: announcement_publications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.announcement_publications (
    announcement_id text NOT NULL
);


--
-- Name: approval_comments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.approval_comments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    approval_id uuid NOT NULL,
    author_agent_id uuid,
    author_user_id text,
    body text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: approvals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.approvals (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    type text NOT NULL,
    requested_by_agent_id uuid,
    requested_by_user_id text,
    status text DEFAULT 'pending'::text NOT NULL,
    payload jsonb NOT NULL,
    decision_note text,
    decided_by_user_id text,
    decided_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: assets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.assets (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    provider text NOT NULL,
    object_key text NOT NULL,
    content_type text NOT NULL,
    byte_size bigint NOT NULL,
    sha256 text NOT NULL,
    original_filename text,
    created_by_agent_id uuid,
    created_by_user_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: board_api_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.board_api_keys (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id text NOT NULL,
    name text NOT NULL,
    key_hash text NOT NULL,
    last_used_at timestamp with time zone,
    revoked_at timestamp with time zone,
    expires_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: browser_use_browsers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.browser_use_browsers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    session_id uuid NOT NULL,
    provider_browser_id uuid NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    expires_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: browser_use_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.browser_use_runs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    session_id uuid NOT NULL,
    heartbeat_run_id uuid NOT NULL,
    invocation_id uuid NOT NULL,
    provider_run_id uuid,
    status text DEFAULT 'creating'::text NOT NULL,
    detached_until timestamp with time zone,
    recovery_cursor text,
    event_cursor integer DEFAULT 0 NOT NULL,
    events_drained integer DEFAULT 0 NOT NULL,
    accounted_cents integer DEFAULT 0 NOT NULL,
    progress text,
    result jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: browser_use_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.browser_use_sessions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    issue_id uuid NOT NULL,
    agent_id uuid NOT NULL,
    connection_id uuid NOT NULL,
    grant_id uuid NOT NULL,
    provider_session_id uuid,
    status text DEFAULT 'starting'::text NOT NULL,
    idle_deadline timestamp with time zone,
    stop_requested text,
    error text,
    lease_token uuid,
    lease_until timestamp with time zone,
    next_poll_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: browser_use_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.browser_use_settings (
    grant_id uuid NOT NULL,
    company_id uuid NOT NULL,
    allowed_profile_ids jsonb DEFAULT '[]'::jsonb NOT NULL,
    max_cost_usd text
);


--
-- Name: budget_incidents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.budget_incidents (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    policy_id uuid NOT NULL,
    scope_type text NOT NULL,
    scope_id uuid NOT NULL,
    metric text NOT NULL,
    window_kind text NOT NULL,
    window_start timestamp with time zone NOT NULL,
    window_end timestamp with time zone NOT NULL,
    threshold_type text NOT NULL,
    amount_limit integer NOT NULL,
    amount_observed integer NOT NULL,
    status text DEFAULT 'open'::text NOT NULL,
    approval_id uuid,
    resolved_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: budget_policies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.budget_policies (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    scope_type text NOT NULL,
    scope_id uuid NOT NULL,
    metric text DEFAULT 'billed_cents'::text NOT NULL,
    window_kind text NOT NULL,
    amount integer DEFAULT 0 NOT NULL,
    warn_percent integer DEFAULT 80 NOT NULL,
    hard_stop_enabled boolean DEFAULT true NOT NULL,
    notify_enabled boolean DEFAULT true NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_by_user_id text,
    updated_by_user_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: built_in_managed_resources; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.built_in_managed_resources (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    bundle_key text NOT NULL,
    resource_kind text NOT NULL,
    resource_key text NOT NULL,
    resource_id uuid NOT NULL,
    stock_version text NOT NULL,
    stock_hash text NOT NULL,
    defaults_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: case_attachments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.case_attachments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    case_id uuid NOT NULL,
    asset_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: case_documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.case_documents (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    case_id uuid NOT NULL,
    document_id uuid NOT NULL,
    key text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: case_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.case_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    case_id uuid NOT NULL,
    kind text NOT NULL,
    actor_type text NOT NULL,
    actor_user_id text,
    actor_agent_id uuid,
    run_id uuid,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT case_events_actor_type_check CHECK ((actor_type = ANY (ARRAY['user'::text, 'agent'::text, 'system'::text]))),
    CONSTRAINT case_events_kind_check CHECK ((kind = ANY (ARRAY['created'::text, 'updated'::text, 'fields_changed'::text, 'status_changed'::text, 'issue_linked'::text, 'issue_unlinked'::text, 'document_revised'::text, 'child_linked'::text, 'attachment_added'::text, 'label_added'::text, 'label_removed'::text])))
);


--
-- Name: case_issue_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.case_issue_links (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    case_id uuid NOT NULL,
    issue_id uuid NOT NULL,
    role text NOT NULL,
    created_by_run_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT case_issue_links_role_check CHECK ((role = ANY (ARRAY['origin'::text, 'work'::text, 'reference'::text])))
);


--
-- Name: case_labels; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.case_labels (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    case_id uuid NOT NULL,
    label_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: cases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cases (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    project_id uuid,
    case_number integer NOT NULL,
    identifier text NOT NULL,
    case_type text NOT NULL,
    key text,
    title text NOT NULL,
    summary text,
    status text DEFAULT 'draft'::text NOT NULL,
    fields jsonb DEFAULT '{}'::jsonb NOT NULL,
    parent_case_id uuid,
    created_by_agent_id uuid,
    created_by_user_id text,
    completed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT cases_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'in_progress'::text, 'in_review'::text, 'approved'::text, 'done'::text, 'cancelled'::text])))
);


--
-- Name: chat_actions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_actions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    endpoint_id uuid NOT NULL,
    delivery_id uuid,
    conversation_id uuid,
    principal_id uuid,
    kind text NOT NULL,
    provider_action_id text NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    status text DEFAULT 'received'::text NOT NULL,
    result jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: chat_agent_routes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_agent_routes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    source_endpoint_id uuid NOT NULL,
    destination_endpoint_id uuid NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    trigger_mode text DEFAULT 'explicit_mention'::text NOT NULL,
    max_hops integer DEFAULT 1 NOT NULL,
    created_by_user_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chat_agent_routes_hops_check CHECK (((max_hops >= 1) AND (max_hops <= 8)))
);


--
-- Name: chat_completion_deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_completion_deliveries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    task_id uuid NOT NULL,
    status_version integer NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    next_attempt_at timestamp with time zone DEFAULT now() NOT NULL,
    target_run_id uuid,
    response_comment_id uuid,
    error text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: chat_conversations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_conversations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    endpoint_id uuid NOT NULL,
    resource_id uuid,
    issue_id uuid NOT NULL,
    external_conversation_id text NOT NULL,
    external_thread_id text DEFAULT ''::text NOT NULL,
    external_label text NOT NULL,
    provider_url text,
    is_direct_message boolean DEFAULT false NOT NULL,
    state text DEFAULT 'active'::text NOT NULL,
    last_activity_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    session_generation integer DEFAULT 1 NOT NULL,
    communication_guidance text,
    CONSTRAINT chat_conversations_state_check CHECK ((state = ANY (ARRAY['active'::text, 'waiting'::text, 'completed'::text, 'unavailable'::text, 'endpoint_removed'::text])))
);


--
-- Name: chat_deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_deliveries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    endpoint_id uuid NOT NULL,
    conversation_id uuid,
    principal_id uuid,
    provider_event_id text NOT NULL,
    deduplication_key text NOT NULL,
    event_kind text NOT NULL,
    normalized_event jsonb NOT NULL,
    state text DEFAULT 'received'::text NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    redacted_error text,
    next_attempt_at timestamp with time zone,
    received_at timestamp with time zone DEFAULT now() NOT NULL,
    processed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chat_deliveries_state_check CHECK ((state = ANY (ARRAY['received'::text, 'filtered'::text, 'processing'::text, 'processed'::text, 'retry'::text, 'failed'::text])))
);


--
-- Name: chat_discord_command_owners; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_discord_command_owners (
    application_id text NOT NULL,
    company_id uuid NOT NULL,
    endpoint_id uuid NOT NULL,
    action_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chat_discord_command_owners_application_check CHECK ((application_id ~ '^[1-9][0-9]{16,19}$'::text))
);


--
-- Name: chat_endpoint_leases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_endpoint_leases (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    endpoint_id uuid NOT NULL,
    lease_key text NOT NULL,
    token text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: chat_endpoint_resources; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_endpoint_resources (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    endpoint_id uuid NOT NULL,
    type text NOT NULL,
    provider_resource_id text NOT NULL,
    parent_provider_resource_id text,
    label text NOT NULL,
    detail text,
    provider_url text,
    availability text DEFAULT 'available'::text NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chat_endpoint_resources_availability_check CHECK ((availability = ANY (ARRAY['available'::text, 'unavailable'::text, 'removed'::text])))
);


--
-- Name: chat_endpoints; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_endpoints (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    connection_id uuid NOT NULL,
    provider text NOT NULL,
    public_id text NOT NULL,
    assigned_agent_id uuid NOT NULL,
    sponsor_user_id text,
    status text DEFAULT 'draft'::text NOT NULL,
    deployment_mode text DEFAULT 'direct'::text NOT NULL,
    provider_account_id text,
    provider_account_label text,
    bot_external_id text,
    bot_username text,
    bot_display_name text,
    bot_avatar_url text,
    allow_direct_messages boolean DEFAULT true NOT NULL,
    allow_group_chats boolean DEFAULT false NOT NULL,
    allow_unlinked_people boolean DEFAULT true NOT NULL,
    concurrency_policy text DEFAULT 'queue'::text NOT NULL,
    capabilities jsonb DEFAULT '{"cards": false, "files": false, "modals": false, "actions": false, "threads": false, "reactions": false, "messageEdits": false, "slashCommands": false, "directMessages": false, "messageDeletes": false, "nativeStreaming": false, "ephemeralMessages": false, "proactiveDirectMessages": false}'::jsonb NOT NULL,
    setup jsonb DEFAULT '{"step": "provider_setup"}'::jsonb NOT NULL,
    health_message text,
    last_event_at timestamp with time zone,
    last_publication_at timestamp with time zone,
    last_error text,
    activated_at timestamp with time zone,
    archived_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    publication_mode text DEFAULT 'automatic'::text NOT NULL,
    external_execution_policy text DEFAULT 'restricted'::text NOT NULL,
    communication_instructions text DEFAULT ''::text NOT NULL,
    CONSTRAINT chat_endpoints_concurrency_check CHECK ((concurrency_policy = ANY (ARRAY['burst'::text, 'queue'::text, 'debounce'::text, 'drop'::text, 'concurrent'::text]))),
    CONSTRAINT chat_endpoints_deployment_check CHECK ((deployment_mode = ANY (ARRAY['direct'::text, 'relay'::text]))),
    CONSTRAINT chat_endpoints_email_policy_check CHECK (((provider <> 'agentmail'::text) OR ((publication_mode = 'explicit'::text) AND (external_execution_policy = 'agent'::text)))),
    CONSTRAINT chat_endpoints_execution_policy_check CHECK ((external_execution_policy = ANY (ARRAY['restricted'::text, 'agent'::text]))),
    CONSTRAINT chat_endpoints_provider_check CHECK ((provider = ANY (ARRAY['slack'::text, 'github'::text, 'discord'::text, 'microsoft-teams'::text, 'telegram'::text, 'agentmail'::text, 'imessage-photon'::text]))),
    CONSTRAINT chat_endpoints_publication_mode_check CHECK ((publication_mode = ANY (ARRAY['automatic'::text, 'explicit'::text]))),
    CONSTRAINT chat_endpoints_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'verifying'::text, 'active'::text, 'paused'::text, 'attention'::text, 'revoked'::text, 'archived'::text])))
);


--
-- Name: chat_external_principals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_external_principals (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    provider text NOT NULL,
    provider_account_id text NOT NULL,
    external_id text NOT NULL,
    kind text DEFAULT 'user'::text NOT NULL,
    display_name text,
    handle text,
    avatar_url text,
    is_bot boolean DEFAULT false NOT NULL,
    last_seen_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chat_external_principals_kind_check CHECK ((kind = ANY (ARRAY['user'::text, 'bot'::text, 'app'::text, 'system'::text]))),
    CONSTRAINT chat_external_principals_provider_check CHECK ((provider = ANY (ARRAY['slack'::text, 'github'::text, 'discord'::text, 'microsoft-teams'::text, 'telegram'::text, 'agentmail'::text, 'imessage-photon'::text])))
);


--
-- Name: chat_github_configurations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_github_configurations (
    endpoint_id uuid NOT NULL,
    company_id uuid NOT NULL,
    revision integer DEFAULT 1 NOT NULL,
    configuration jsonb NOT NULL,
    updated_by_user_id text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chat_github_config_revision_check CHECK ((revision > 0))
);


--
-- Name: chat_github_registrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_github_registrations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    endpoint_id uuid NOT NULL,
    user_id text NOT NULL,
    state_hash text NOT NULL,
    trusted_origin text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    consumed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chat_github_registration_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'exchanging'::text, 'completed'::text, 'failed'::text])))
);


--
-- Name: chat_github_reviews; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_github_reviews (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    endpoint_id uuid NOT NULL,
    issue_id uuid NOT NULL,
    run_id uuid,
    repository_id text NOT NULL,
    repository text NOT NULL,
    pull_number integer NOT NULL,
    head_sha text NOT NULL,
    delivery_id text NOT NULL,
    configuration_revision integer NOT NULL,
    policy_snapshot jsonb NOT NULL,
    event jsonb NOT NULL,
    state text DEFAULT 'queued'::text NOT NULL,
    assessment jsonb,
    conclusion text,
    check_id text,
    check_url text,
    summary_id text,
    summary_url text,
    publication_receipts jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chat_github_review_pull_number_check CHECK ((pull_number > 0)),
    CONSTRAINT chat_github_review_state_check CHECK ((state = ANY (ARRAY['queued'::text, 'running'::text, 'completed'::text, 'incomplete'::text, 'error'::text, 'superseded'::text, 'manual_required'::text])))
);


--
-- Name: chat_identity_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_identity_links (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    endpoint_id uuid NOT NULL,
    principal_id uuid NOT NULL,
    paperclip_user_id text,
    status text DEFAULT 'pending'::text NOT NULL,
    confirmation_token_hash text,
    expires_at timestamp with time zone,
    confirmed_at timestamp with time zone,
    revoked_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chat_identity_links_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'linked'::text, 'revoked'::text, 'expired'::text])))
);


--
-- Name: chat_message_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_message_links (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    endpoint_id uuid NOT NULL,
    conversation_id uuid NOT NULL,
    delivery_id uuid,
    publication_id uuid,
    comment_id uuid,
    provider_message_id text NOT NULL,
    direction text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chat_message_links_direction_check CHECK ((direction = ANY (ARRAY['inbound'::text, 'outbound'::text])))
);


--
-- Name: chat_publications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_publications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    endpoint_id uuid NOT NULL,
    conversation_id uuid NOT NULL,
    issue_id uuid NOT NULL,
    comment_id uuid,
    idempotency_key text NOT NULL,
    payload jsonb NOT NULL,
    state text DEFAULT 'pending'::text NOT NULL,
    provider_message_id text,
    provider_url text,
    attempts integer DEFAULT 0 NOT NULL,
    redacted_error text,
    next_attempt_at timestamp with time zone,
    published_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chat_publications_state_check CHECK ((state = ANY (ARRAY['pending'::text, 'streaming'::text, 'published'::text, 'retry'::text, 'delivery_unknown'::text, 'failed'::text, 'cancelled'::text, 'awaiting_consent'::text])))
);


--
-- Name: chat_sdk_state; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_sdk_state (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    endpoint_id uuid NOT NULL,
    state_key text NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    value jsonb NOT NULL,
    expires_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: chat_task_handoffs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_task_handoffs (
    task_id uuid NOT NULL,
    company_id uuid NOT NULL,
    conversation_id uuid NOT NULL,
    agent_id uuid NOT NULL,
    session_generation integer NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: chat_teams_file_transfers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_teams_file_transfers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    endpoint_id uuid NOT NULL,
    conversation_id uuid NOT NULL,
    publication_id uuid NOT NULL,
    issue_id uuid NOT NULL,
    comment_id uuid NOT NULL,
    attachment_id uuid NOT NULL,
    principal_id uuid NOT NULL,
    authorized_user_id text,
    runtime_generation integer NOT NULL,
    credential_fingerprint text NOT NULL,
    conversation_generation integer NOT NULL,
    source_digest text NOT NULL,
    authority_digest text NOT NULL,
    tenant_id uuid NOT NULL,
    bot_app_id uuid NOT NULL,
    aad_object_id uuid NOT NULL,
    provider_conversation_id text NOT NULL,
    provider_user_id text NOT NULL,
    sha256 text NOT NULL,
    byte_size integer NOT NULL,
    filename text NOT NULL,
    token_sha256 text NOT NULL,
    phase text DEFAULT 'consent_pending'::text NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    attempt_id uuid,
    attempt_expires_at timestamp with time zone,
    consent_message_id text,
    file_info_message_id text,
    response_activity_id text,
    response_digest text,
    private_state jsonb NOT NULL,
    reason text,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chat_teams_file_transfers_attempt_check CHECK (((attempt_id IS NULL) = (attempt_expires_at IS NULL))),
    CONSTRAINT chat_teams_file_transfers_bounds_check CHECK (((version > 0) AND (runtime_generation >= 0) AND (conversation_generation > 0) AND (byte_size > 0) AND (byte_size < 62914560))),
    CONSTRAINT chat_teams_file_transfers_hash_check CHECK (((source_digest ~ '^[a-f0-9]{64}$'::text) AND (authority_digest ~ '^[a-f0-9]{64}$'::text) AND (sha256 ~ '^[a-f0-9]{64}$'::text) AND (token_sha256 ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT chat_teams_file_transfers_phase_check CHECK ((phase = ANY (ARRAY['consent_pending'::text, 'consent_sending'::text, 'consent_unknown'::text, 'awaiting_consent'::text, 'upload_pending'::text, 'uploading'::text, 'upload_unknown'::text, 'file_info_pending'::text, 'file_info_sending'::text, 'file_info_unknown'::text, 'delivered'::text, 'declined'::text, 'expired'::text, 'cancelled'::text, 'conflict'::text])))
);


--
-- Name: chat_telegram_draft_ids; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.chat_telegram_draft_ids
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    MAXVALUE 2147483647
    CACHE 1;


--
-- Name: cli_auth_challenges; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cli_auth_challenges (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    secret_hash text NOT NULL,
    command text NOT NULL,
    client_name text,
    requested_access text DEFAULT 'board'::text NOT NULL,
    requested_company_id uuid,
    pending_key_hash text NOT NULL,
    pending_key_name text NOT NULL,
    approved_by_user_id text,
    board_api_key_id uuid,
    approved_at timestamp with time zone,
    cancelled_at timestamp with time zone,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: companies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.companies (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    description text,
    status text DEFAULT 'active'::text NOT NULL,
    budget_monthly_cents integer DEFAULT 0 NOT NULL,
    spent_monthly_cents integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    issue_prefix text DEFAULT 'PAP'::text NOT NULL,
    issue_counter integer DEFAULT 0 NOT NULL,
    require_board_approval_for_new_agents boolean DEFAULT false NOT NULL,
    pause_reason text,
    paused_at timestamp with time zone,
    feedback_data_sharing_enabled boolean DEFAULT false NOT NULL,
    feedback_data_sharing_consent_at timestamp with time zone,
    feedback_data_sharing_consent_by_user_id text,
    feedback_data_sharing_terms_version text,
    default_responsible_user_id text,
    interaction_resolver_governance jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: company_logos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.company_logos (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    asset_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: company_memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.company_memberships (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    principal_type text NOT NULL,
    principal_id text NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    membership_role text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: company_onboarding_seeds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.company_onboarding_seeds (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    revision text NOT NULL,
    mission text,
    agent_name text,
    agent_role text,
    first_task_title text,
    first_task_details text,
    goal_id uuid,
    agent_id uuid,
    issue_id uuid,
    applied_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: company_secret_bindings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.company_secret_bindings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    secret_id uuid NOT NULL,
    target_type text NOT NULL,
    target_id text NOT NULL,
    config_path text NOT NULL,
    version_selector text DEFAULT 'latest'::text NOT NULL,
    required boolean DEFAULT true NOT NULL,
    label text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    projection_class text DEFAULT 'unclassified'::text NOT NULL,
    projection_allowlist_key text
);


--
-- Name: company_secret_proposals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.company_secret_proposals (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    kind text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    proposed_name text,
    proposed_key text,
    proposed_description text,
    justification text NOT NULL,
    value_ciphertext jsonb,
    value_fingerprint_sha256 text,
    value_length integer,
    secret_id uuid,
    secret_proposal_id uuid,
    target_type text,
    target_id uuid,
    config_path text,
    projection_class text DEFAULT 'unclassified'::text NOT NULL,
    binding_target_policy_snapshot text,
    proposer_ancestor_ids_snapshot jsonb,
    target_ancestor_ids_snapshot jsonb,
    proposed_by_agent_id uuid NOT NULL,
    origin_issue_id uuid,
    origin_run_id uuid NOT NULL,
    resolved_by_user_id text,
    resolved_at timestamp with time zone,
    resolution_reason text,
    created_secret_id uuid,
    applied_binding_config_path text,
    ciphertext_scrubbed_at timestamp with time zone,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    interaction_id uuid,
    CONSTRAINT company_secret_proposals_kind_check CHECK ((kind = ANY (ARRAY['secret'::text, 'binding'::text]))),
    CONSTRAINT company_secret_proposals_projection_check CHECK ((projection_class = 'unclassified'::text)),
    CONSTRAINT company_secret_proposals_shape_check CHECK ((((kind = 'secret'::text) AND (proposed_name IS NOT NULL) AND (proposed_key IS NOT NULL) AND (secret_id IS NULL) AND (secret_proposal_id IS NULL) AND (target_type IS NULL) AND (target_id IS NULL) AND (config_path IS NULL)) OR ((kind = 'binding'::text) AND ((((secret_id IS NOT NULL))::integer + ((secret_proposal_id IS NOT NULL))::integer) = 1) AND (target_type = 'agent'::text) AND (target_id IS NOT NULL) AND (config_path IS NOT NULL)))),
    CONSTRAINT company_secret_proposals_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'approved'::text, 'rejected'::text, 'withdrawn'::text, 'expired'::text])))
);


--
-- Name: company_secret_provider_configs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.company_secret_provider_configs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    provider text NOT NULL,
    display_name text NOT NULL,
    status text DEFAULT 'ready'::text NOT NULL,
    is_default boolean DEFAULT false NOT NULL,
    config jsonb DEFAULT '{}'::jsonb NOT NULL,
    health_status text,
    health_checked_at timestamp with time zone,
    health_message text,
    health_details jsonb,
    disabled_at timestamp with time zone,
    created_by_agent_id uuid,
    created_by_user_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: company_secret_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.company_secret_versions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    secret_id uuid NOT NULL,
    version integer NOT NULL,
    material jsonb NOT NULL,
    value_sha256 text NOT NULL,
    created_by_agent_id uuid,
    created_by_user_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    revoked_at timestamp with time zone,
    provider_version_ref text,
    status text DEFAULT 'current'::text NOT NULL,
    fingerprint_sha256 text NOT NULL,
    rotation_job_id text
);


--
-- Name: company_secrets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.company_secrets (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    name text NOT NULL,
    provider text DEFAULT 'local_encrypted'::text NOT NULL,
    external_ref text,
    latest_version integer DEFAULT 1 NOT NULL,
    description text,
    created_by_agent_id uuid,
    created_by_user_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    key text NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    managed_mode text DEFAULT 'paperclip_managed'::text NOT NULL,
    provider_config_id uuid,
    provider_metadata jsonb,
    last_resolved_at timestamp with time zone,
    last_rotated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    scope text DEFAULT 'company'::text NOT NULL,
    owner_user_id text,
    user_secret_definition_id uuid,
    ai_session_epoch integer DEFAULT 0 NOT NULL,
    CONSTRAINT company_secrets_scope_shape_check CHECK ((((scope = 'company'::text) AND (owner_user_id IS NULL) AND (user_secret_definition_id IS NULL)) OR ((scope = 'user'::text) AND (owner_user_id IS NOT NULL) AND (user_secret_definition_id IS NOT NULL))))
);


--
-- Name: company_skill_comments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.company_skill_comments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    company_skill_id uuid NOT NULL,
    parent_comment_id uuid,
    author_agent_id uuid,
    author_user_id text,
    body text NOT NULL,
    deleted_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: company_skill_policies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.company_skill_policies (
    company_id uuid NOT NULL,
    schema_version integer DEFAULT 1 NOT NULL,
    revision integer NOT NULL,
    default_effect text NOT NULL,
    rules jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT company_skill_policies_default_effect_check CHECK ((default_effect = ANY (ARRAY['allow'::text, 'deny'::text]))),
    CONSTRAINT company_skill_policies_revision_check CHECK ((revision > 0)),
    CONSTRAINT company_skill_policies_schema_version_check CHECK ((schema_version = 1))
);


--
-- Name: company_skill_source_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.company_skill_source_entries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    source_id uuid NOT NULL,
    path text NOT NULL,
    name text NOT NULL,
    description text,
    skill_id uuid,
    selection text DEFAULT 'new'::text NOT NULL,
    present boolean DEFAULT true NOT NULL,
    error text,
    inspection jsonb
);


--
-- Name: company_skill_sources; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.company_skill_sources (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    repository_id text,
    repository_url text NOT NULL,
    full_name text NOT NULL,
    tracking_ref text NOT NULL,
    connection_id uuid,
    excluded_folders jsonb DEFAULT '[]'::jsonb NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    revision integer DEFAULT 0 NOT NULL,
    last_attempt_at timestamp with time zone,
    last_success_at timestamp with time zone,
    last_scan_commit text,
    last_error text,
    lease_token uuid,
    lease_expires_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: company_skill_stars; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.company_skill_stars (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    company_skill_id uuid NOT NULL,
    agent_id uuid,
    user_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: company_skill_test_inputs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.company_skill_test_inputs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    skill_id uuid NOT NULL,
    name text NOT NULL,
    content text NOT NULL,
    created_by text,
    deleted_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: company_skill_test_run_templates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.company_skill_test_run_templates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    name text NOT NULL,
    description text,
    body text NOT NULL,
    created_by_agent_id uuid,
    created_by_user_id text,
    updated_by_agent_id uuid,
    updated_by_user_id text,
    deleted_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: company_skill_test_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.company_skill_test_runs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    skill_id uuid NOT NULL,
    input_id uuid,
    input_snapshot text NOT NULL,
    skill_version_id uuid NOT NULL,
    agent_id uuid NOT NULL,
    agent_config_snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
    issue_id uuid NOT NULL,
    status text DEFAULT 'queued'::text NOT NULL,
    output_document_key text DEFAULT 'output'::text NOT NULL,
    output_snapshot text DEFAULT ''::text NOT NULL,
    error text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    superseded_at timestamp with time zone,
    harness_issue_expires_at timestamp with time zone,
    harness_issue_deleted_at timestamp with time zone,
    template_id text,
    template_name text,
    template_body text,
    rendered_template_body text,
    harness_issue_description text DEFAULT ''::text NOT NULL
);


--
-- Name: company_skill_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.company_skill_versions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    company_skill_id uuid NOT NULL,
    revision_number integer NOT NULL,
    label text,
    file_inventory jsonb DEFAULT '[]'::jsonb NOT NULL,
    author_agent_id uuid,
    author_user_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    release_id text,
    release_name text,
    released_at timestamp with time zone
);


--
-- Name: company_skills; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.company_skills (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    key text NOT NULL,
    slug text NOT NULL,
    name text NOT NULL,
    description text,
    markdown text NOT NULL,
    source_type text DEFAULT 'local_path'::text NOT NULL,
    source_locator text,
    source_ref text,
    trust_level text DEFAULT 'markdown_only'::text NOT NULL,
    compatibility text DEFAULT 'compatible'::text NOT NULL,
    file_inventory jsonb DEFAULT '[]'::jsonb NOT NULL,
    metadata jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    icon_url text,
    color text,
    tagline text,
    author_name text,
    homepage_url text,
    categories text[] DEFAULT '{}'::text[] NOT NULL,
    sharing_scope text DEFAULT 'company'::text NOT NULL,
    public_share_token text,
    forked_from_skill_id uuid,
    forked_from_company_id uuid,
    star_count integer DEFAULT 0 NOT NULL,
    install_count integer DEFAULT 0 NOT NULL,
    fork_count integer DEFAULT 0 NOT NULL,
    current_version_id uuid,
    folder_id uuid
);


--
-- Name: company_transfer_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.company_transfer_runs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid,
    direction text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    actor_key text NOT NULL,
    container_ref jsonb NOT NULL,
    idempotency_key text NOT NULL,
    manifest_sha256 text,
    manifest jsonb,
    chunk_count integer DEFAULT 0 NOT NULL,
    blob_count integer DEFAULT 0 NOT NULL,
    completed_parts jsonb DEFAULT '[]'::jsonb NOT NULL,
    error text,
    started_at timestamp with time zone,
    finished_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: company_user_sidebar_preferences; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.company_user_sidebar_preferences (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    user_id text NOT NULL,
    project_order jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: completion_contracts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.completion_contracts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    issue_id uuid NOT NULL,
    revision integer NOT NULL,
    schema_version text NOT NULL,
    policy_version text NOT NULL,
    risk text NOT NULL,
    completion_authority text NOT NULL,
    incomplete_criteria_policy text NOT NULL,
    contract_json jsonb NOT NULL,
    canonical_sha256 text NOT NULL,
    created_by_actor_type text NOT NULL,
    created_by_actor_id text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    supersedes_contract_id uuid
);


--
-- Name: connection_event_deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.connection_event_deliveries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    provider text NOT NULL,
    provider_delivery_id text NOT NULL,
    event text NOT NULL,
    action text,
    installation_id text,
    repository_id text,
    normalized_payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    status text DEFAULT 'received'::text NOT NULL,
    attempts integer DEFAULT 1 NOT NULL,
    last_error text,
    provider_created_at timestamp with time zone,
    processed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: connection_grant_delegations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.connection_grant_delegations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    grant_id uuid NOT NULL,
    agent_id uuid NOT NULL,
    created_by_user_id text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: connection_grant_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.connection_grant_members (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    grant_id uuid NOT NULL,
    subject_type text NOT NULL,
    subject_id text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT connection_grant_members_subject_type_check CHECK ((subject_type = 'user'::text))
);


--
-- Name: connection_grants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.connection_grants (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    connection_id uuid NOT NULL,
    kind text NOT NULL,
    subject_user_id text,
    provider_tenant jsonb,
    credential_secret_refs jsonb DEFAULT '[]'::jsonb NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    is_default boolean DEFAULT false NOT NULL,
    created_by_agent_id uuid,
    created_by_user_id text,
    revoked_at timestamp with time zone,
    revoked_by_agent_id uuid,
    revoked_by_user_id text,
    last_used_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    external_credential jsonb,
    subject_agent_id uuid,
    CONSTRAINT connection_grants_credential_source_one_of_check CHECK (((external_credential IS NULL) OR (jsonb_array_length(credential_secret_refs) = 0))),
    CONSTRAINT connection_grants_default_check CHECK (((is_default = false) OR (kind = 'organization'::text))),
    CONSTRAINT connection_grants_kind_check CHECK ((kind = ANY (ARRAY['organization'::text, 'user'::text, 'agent'::text]))),
    CONSTRAINT connection_grants_status_check CHECK ((status = ANY (ARRAY['active'::text, 'revoked'::text, 'expired'::text, 'needs_reauthorization'::text]))),
    CONSTRAINT connection_grants_subject_check CHECK ((((kind = 'user'::text) AND (subject_user_id IS NOT NULL) AND (subject_agent_id IS NULL)) OR ((kind = 'agent'::text) AND (subject_agent_id IS NOT NULL) AND (subject_user_id IS NULL)) OR ((kind = 'organization'::text) AND (subject_user_id IS NULL) AND (subject_agent_id IS NULL))))
);


--
-- Name: connection_intent_deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.connection_intent_deliveries (
    interaction_id uuid NOT NULL,
    company_id uuid NOT NULL,
    next_attempt_at timestamp with time zone DEFAULT now() NOT NULL,
    delivered_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: connection_token_issuances; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.connection_token_issuances (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    application_id uuid,
    connection_id uuid NOT NULL,
    agent_id uuid NOT NULL,
    run_id uuid,
    issue_id uuid,
    project_id uuid,
    responsible_user_id text,
    path text NOT NULL,
    requested_scope jsonb DEFAULT '[]'::jsonb NOT NULL,
    issued_scope jsonb DEFAULT '[]'::jsonb NOT NULL,
    ttl_seconds integer,
    expires_at timestamp with time zone,
    token_hash text,
    outcome text NOT NULL,
    error_code text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT connection_token_issuances_outcome_check CHECK ((outcome = ANY (ARRAY['success'::text, 'denied'::text, 'rate_limited'::text, 'use_env_lease'::text, 'upstream_error'::text, 'failure'::text]))),
    CONSTRAINT connection_token_issuances_path_check CHECK ((path = ANY (ARRAY['exchange'::text, 'oauth_access'::text, 'static'::text]))),
    CONSTRAINT connection_token_issuances_token_hash_format CHECK (((token_hash IS NULL) OR (token_hash ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT connection_token_issuances_ttl_bounds CHECK (((ttl_seconds IS NULL) OR ((ttl_seconds >= 1) AND (ttl_seconds <= 900))))
);


--
-- Name: cost_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cost_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    agent_id uuid NOT NULL,
    issue_id uuid,
    project_id uuid,
    goal_id uuid,
    billing_code text,
    provider text NOT NULL,
    model text NOT NULL,
    input_tokens integer DEFAULT 0 NOT NULL,
    output_tokens integer DEFAULT 0 NOT NULL,
    cost_cents integer NOT NULL,
    occurred_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    heartbeat_run_id uuid,
    biller text DEFAULT 'unknown'::text NOT NULL,
    billing_type text DEFAULT 'unknown'::text NOT NULL,
    cached_input_tokens integer DEFAULT 0 NOT NULL,
    cost_status text DEFAULT 'reported'::text NOT NULL
);


--
-- Name: decision_archive_notification_outbox; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.decision_archive_notification_outbox (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    source_kind text NOT NULL,
    source_id text NOT NULL,
    archive_version integer NOT NULL,
    origin_agent_id uuid NOT NULL,
    origin_issue_id uuid NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    attempt_count integer DEFAULT 0 NOT NULL,
    last_attempt_at timestamp with time zone,
    delivered_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT decision_archive_notification_outbox_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'delivering'::text, 'delivered'::text])))
);


--
-- Name: decision_bundles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.decision_bundles (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    title text NOT NULL,
    summary text NOT NULL,
    origin_agent_id uuid NOT NULL,
    origin_issue_id uuid NOT NULL,
    origin_run_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: decision_effect_executions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.decision_effect_executions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    decision_id uuid NOT NULL,
    effect_index integer NOT NULL,
    effect_type text NOT NULL,
    target_issue_id uuid NOT NULL,
    status text DEFAULT 'claimed'::text NOT NULL,
    result jsonb,
    error text,
    activity_log_id uuid,
    executed_at timestamp with time zone
);


--
-- Name: decision_queue_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.decision_queue_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    queue_id uuid NOT NULL,
    source_kind text NOT NULL,
    source_id text NOT NULL,
    added_by_type text NOT NULL,
    added_by_agent_id uuid,
    added_by_user_id text,
    added_by_run_id uuid,
    added_by_agent_api_key_id uuid,
    responsible_user_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT decision_queue_items_actor_check CHECK ((((added_by_type = 'agent'::text) AND (added_by_agent_id IS NOT NULL) AND (added_by_user_id IS NULL)) OR ((added_by_type = 'user'::text) AND (added_by_agent_id IS NULL) AND (added_by_user_id IS NOT NULL)) OR ((added_by_type = 'system'::text) AND (added_by_agent_id IS NULL) AND (added_by_user_id IS NULL))))
);


--
-- Name: decision_queues; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.decision_queues (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    key text NOT NULL,
    title text NOT NULL,
    description text,
    created_by_type text NOT NULL,
    created_by_agent_id uuid,
    created_by_user_id text,
    created_by_run_id uuid,
    created_by_agent_api_key_id uuid,
    retention_days integer,
    seed_rules jsonb DEFAULT '[]'::jsonb NOT NULL,
    seed_rules_enabled boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT decision_queues_creator_check CHECK ((((created_by_type = 'agent'::text) AND (created_by_agent_id IS NOT NULL) AND (created_by_user_id IS NULL)) OR ((created_by_type = 'user'::text) AND (created_by_agent_id IS NULL) AND (created_by_user_id IS NOT NULL)) OR ((created_by_type = 'system'::text) AND (created_by_agent_id IS NULL) AND (created_by_user_id IS NULL)))),
    CONSTRAINT decision_queues_retention_days_check CHECK (((retention_days IS NULL) OR ((retention_days >= 1) AND (retention_days <= 3650))))
);


--
-- Name: decision_retention; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.decision_retention (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    source_kind text NOT NULL,
    source_id text NOT NULL,
    source_activity_at timestamp with time zone NOT NULL,
    keep boolean DEFAULT false NOT NULL,
    archived_at timestamp with time zone,
    archived_reason text,
    archived_by_type text,
    archived_by_agent_id uuid,
    archived_by_user_id text,
    archived_by_run_id uuid,
    version integer DEFAULT 1 NOT NULL,
    archive_version integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT decision_retention_archive_actor_check CHECK ((((archived_at IS NULL) AND (archived_by_type IS NULL) AND (archived_by_agent_id IS NULL) AND (archived_by_user_id IS NULL)) OR ((archived_at IS NOT NULL) AND (archived_by_type = 'system'::text) AND (archived_by_agent_id IS NULL) AND (archived_by_user_id IS NULL)) OR ((archived_at IS NOT NULL) AND (archived_by_type = 'agent'::text) AND (archived_by_agent_id IS NOT NULL) AND (archived_by_user_id IS NULL)) OR ((archived_at IS NOT NULL) AND (archived_by_type = 'user'::text) AND (archived_by_agent_id IS NULL) AND (archived_by_user_id IS NOT NULL))))
);


--
-- Name: decision_target_issues; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.decision_target_issues (
    decision_id uuid NOT NULL,
    issue_id uuid NOT NULL,
    company_id uuid NOT NULL
);


--
-- Name: decision_training_examples; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.decision_training_examples (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    source_kind text NOT NULL,
    source_id uuid NOT NULL,
    issue_id uuid NOT NULL,
    cutoff_at timestamp with time zone NOT NULL,
    notes text DEFAULT ''::text NOT NULL,
    notes_history jsonb DEFAULT '[]'::jsonb NOT NULL,
    decision_outcome text,
    snapshot jsonb NOT NULL,
    created_by_user_id text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    retention_policy text DEFAULT 'scrub_deleted_comments_v1'::text NOT NULL,
    CONSTRAINT decision_training_examples_source_kind_check CHECK ((source_kind = ANY (ARRAY['interaction'::text, 'approval'::text, 'execution_decision'::text])))
);


--
-- Name: decision_triage; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.decision_triage (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    source_kind text NOT NULL,
    source_id text NOT NULL,
    decide_by text,
    decide_by_date date,
    snoozed_until timestamp with time zone,
    set_by_type text NOT NULL,
    set_by_agent_id uuid,
    set_by_user_id text,
    set_by_run_id uuid,
    set_by_agent_api_key_id uuid,
    responsible_user_id text,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT decision_triage_actor_check CHECK ((((set_by_type = 'agent'::text) AND (set_by_agent_id IS NOT NULL) AND (set_by_user_id IS NULL)) OR ((set_by_type = 'user'::text) AND (set_by_agent_id IS NULL) AND (set_by_user_id IS NOT NULL)))),
    CONSTRAINT decision_triage_decide_by_check CHECK ((((decide_by IS NULL) AND (decide_by_date IS NULL)) OR ((decide_by = ANY (ARRAY['today'::text, 'this_week'::text, 'whenever'::text])) AND (decide_by_date IS NULL)) OR ((decide_by = 'date'::text) AND (decide_by_date IS NOT NULL))))
);


--
-- Name: decision_triage_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.decision_triage_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    queue_id uuid,
    source_kind text,
    source_id text,
    action text NOT NULL,
    actor_type text NOT NULL,
    actor_agent_id uuid,
    actor_user_id text,
    actor_run_id uuid,
    agent_api_key_id uuid,
    responsible_user_id text,
    details jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT decision_triage_events_actor_check CHECK ((((actor_type = 'agent'::text) AND (actor_agent_id IS NOT NULL) AND (actor_user_id IS NULL)) OR ((actor_type = 'user'::text) AND (actor_agent_id IS NULL) AND (actor_user_id IS NOT NULL)) OR ((actor_type = 'system'::text) AND (actor_agent_id IS NULL) AND (actor_user_id IS NULL))))
);


--
-- Name: decisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.decisions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    bundle_id uuid,
    origin_agent_id uuid NOT NULL,
    origin_issue_id uuid NOT NULL,
    origin_run_id uuid NOT NULL,
    rule_key text,
    title text NOT NULL,
    body text NOT NULL,
    options jsonb NOT NULL,
    inputs jsonb,
    status text DEFAULT 'open'::text NOT NULL,
    execution_status text,
    chosen_option_id text,
    input_values jsonb,
    decided_by_user_id text,
    decided_at timestamp with time zone,
    expires_at timestamp with time zone NOT NULL,
    idempotency_key text,
    signed_spec text NOT NULL,
    target_snapshots jsonb NOT NULL,
    continuation_policy text DEFAULT 'none'::text NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: document_annotation_anchor_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.document_annotation_anchor_snapshots (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    thread_id uuid NOT NULL,
    document_id uuid NOT NULL,
    from_revision_id uuid,
    from_revision_number integer,
    to_revision_id uuid,
    to_revision_number integer CONSTRAINT document_annotation_anchor_snapshot_to_revision_number_not_null NOT NULL,
    previous_anchor jsonb NOT NULL,
    next_anchor jsonb,
    anchor_state text NOT NULL,
    anchor_confidence text NOT NULL,
    failure_reason text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: document_annotation_comments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.document_annotation_comments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    thread_id uuid NOT NULL,
    issue_id uuid,
    document_id uuid NOT NULL,
    body text NOT NULL,
    author_type text NOT NULL,
    author_agent_id uuid,
    author_user_id text,
    created_by_run_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    issue_comment_id uuid,
    routine_id uuid,
    source_trust jsonb,
    case_id uuid,
    CONSTRAINT document_annotation_comments_exactly_one_owner_chk CHECK ((num_nonnulls(issue_id, routine_id, case_id) = 1))
);


--
-- Name: document_annotation_threads; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.document_annotation_threads (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    issue_id uuid,
    document_id uuid NOT NULL,
    document_key text NOT NULL,
    status text DEFAULT 'open'::text NOT NULL,
    anchor_state text DEFAULT 'active'::text NOT NULL,
    original_revision_id uuid,
    original_revision_number integer NOT NULL,
    current_revision_id uuid,
    current_revision_number integer NOT NULL,
    selected_text text NOT NULL,
    prefix_text text DEFAULT ''::text NOT NULL,
    suffix_text text DEFAULT ''::text NOT NULL,
    normalized_start integer NOT NULL,
    normalized_end integer NOT NULL,
    markdown_start integer NOT NULL,
    markdown_end integer NOT NULL,
    anchor_confidence text DEFAULT 'exact'::text NOT NULL,
    anchor_selector jsonb NOT NULL,
    created_by_agent_id uuid,
    created_by_user_id text,
    resolved_by_agent_id uuid,
    resolved_by_user_id text,
    resolved_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    routine_id uuid,
    case_id uuid,
    CONSTRAINT document_annotation_threads_exactly_one_owner_chk CHECK ((num_nonnulls(issue_id, routine_id, case_id) = 1))
);


--
-- Name: document_memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.document_memberships (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    document_id uuid NOT NULL,
    user_id text NOT NULL,
    starred_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: document_revisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.document_revisions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    document_id uuid NOT NULL,
    revision_number integer NOT NULL,
    body text NOT NULL,
    change_summary text,
    created_by_agent_id uuid,
    created_by_user_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    title text,
    format text DEFAULT 'markdown'::text NOT NULL,
    created_by_run_id uuid
);


--
-- Name: documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.documents (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    title text,
    format text DEFAULT 'markdown'::text NOT NULL,
    latest_body text NOT NULL,
    latest_revision_id uuid,
    latest_revision_number integer DEFAULT 1 NOT NULL,
    created_by_agent_id uuid,
    created_by_user_id text,
    updated_by_agent_id uuid,
    updated_by_user_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    locked_at timestamp with time zone,
    locked_by_agent_id uuid,
    locked_by_user_id text,
    source_trust jsonb
);


--
-- Name: email_endpoints; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_endpoints (
    endpoint_id uuid NOT NULL,
    company_id uuid NOT NULL,
    receive_mode text NOT NULL,
    webhook_id text,
    owned_api_key_id text,
    activation_at timestamp with time zone,
    sync_checkpoint timestamp with time zone,
    last_sync_at timestamp with time zone,
    CONSTRAINT email_endpoints_receive_mode_check CHECK ((receive_mode = ANY (ARRAY['websocket'::text, 'webhook'::text])))
);


--
-- Name: email_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_messages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    endpoint_id uuid NOT NULL,
    conversation_id uuid NOT NULL,
    provider_message_id text NOT NULL,
    envelope jsonb NOT NULL,
    text text NOT NULL,
    full_text text DEFAULT ''::text NOT NULL,
    direction text NOT NULL,
    automatic boolean DEFAULT false NOT NULL,
    attachment_ids jsonb DEFAULT '[]'::jsonb NOT NULL,
    "timestamp" timestamp with time zone NOT NULL,
    CONSTRAINT email_messages_direction_check CHECK ((direction = ANY (ARRAY['inbound'::text, 'outbound'::text])))
);


--
-- Name: email_sends; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_sends (
    publication_id uuid NOT NULL,
    company_id uuid NOT NULL,
    endpoint_id uuid NOT NULL,
    request jsonb NOT NULL,
    actor jsonb NOT NULL,
    digest text NOT NULL,
    outcome text DEFAULT 'queued'::text NOT NULL,
    first_attempt_at timestamp with time zone,
    CONSTRAINT email_sends_outcome_check CHECK ((outcome = ANY (ARRAY['queued'::text, 'sent'::text, 'delivered'::text, 'failed'::text, 'uncertain'::text])))
);


--
-- Name: environment_custom_image_setup_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.environment_custom_image_setup_sessions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    environment_id uuid NOT NULL,
    template_id uuid,
    promoted_template_id uuid,
    provider text NOT NULL,
    provider_lease_id text,
    environment_lease_id uuid,
    status text DEFAULT 'starting'::text NOT NULL,
    started_by_user_id text,
    started_by_agent_id uuid,
    base_template_ref text,
    expires_at timestamp with time zone,
    finished_at timestamp with time zone,
    failure_reason text,
    connection_summary jsonb,
    connection_secret_ref text,
    metadata jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: environment_custom_image_templates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.environment_custom_image_templates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    environment_id uuid NOT NULL,
    provider text NOT NULL,
    template_kind text DEFAULT 'unknown'::text NOT NULL,
    template_ref text NOT NULL,
    source_template_ref text,
    source_environment_config_fingerprint text,
    status text DEFAULT 'active'::text NOT NULL,
    created_by_user_id text,
    created_by_agent_id uuid,
    captured_at timestamp with time zone,
    last_used_at timestamp with time zone,
    superseded_by_template_id uuid,
    metadata jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: environment_leases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.environment_leases (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    environment_id uuid,
    execution_workspace_id uuid,
    issue_id uuid,
    heartbeat_run_id uuid,
    status text DEFAULT 'active'::text NOT NULL,
    lease_policy text DEFAULT 'ephemeral'::text NOT NULL,
    provider text,
    provider_lease_id text,
    acquired_at timestamp with time zone DEFAULT now() NOT NULL,
    last_used_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone,
    released_at timestamp with time zone,
    failure_reason text,
    cleanup_status text,
    metadata jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: environments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.environments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    description text,
    driver text DEFAULT 'local'::text NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    config jsonb DEFAULT '{}'::jsonb NOT NULL,
    metadata jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    env_vars jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: execution_workspace_runtime_leases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.execution_workspace_runtime_leases (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    execution_workspace_id uuid CONSTRAINT execution_workspace_runtime_lea_execution_workspace_id_not_null NOT NULL,
    owner_key text NOT NULL,
    owner_issue_id uuid,
    owner_run_id uuid,
    owner_agent_id uuid,
    last_action text NOT NULL,
    claimed_at timestamp with time zone DEFAULT now() NOT NULL,
    renewed_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    metadata jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: execution_workspaces; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.execution_workspaces (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    project_id uuid NOT NULL,
    project_workspace_id uuid,
    source_issue_id uuid,
    mode text NOT NULL,
    strategy_type text NOT NULL,
    name text NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    cwd text,
    repo_url text,
    base_ref text,
    branch_name text,
    provider_type text DEFAULT 'local_fs'::text NOT NULL,
    provider_ref text,
    derived_from_execution_workspace_id uuid,
    last_used_at timestamp with time zone DEFAULT now() NOT NULL,
    opened_at timestamp with time zone DEFAULT now() NOT NULL,
    closed_at timestamp with time zone,
    cleanup_eligible_at timestamp with time zone,
    cleanup_reason text,
    metadata jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: external_object_mentions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.external_object_mentions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    source_issue_id uuid NOT NULL,
    source_kind text NOT NULL,
    source_record_id uuid,
    document_key text,
    property_key text,
    matched_text_redacted text,
    sanitized_display_url text,
    canonical_identity_hash text,
    canonical_identity jsonb,
    object_id uuid,
    provider_key text,
    detector_key text,
    object_type text,
    confidence text DEFAULT 'exact'::text NOT NULL,
    created_by_plugin_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: external_objects; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.external_objects (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    provider_key text NOT NULL,
    plugin_id uuid,
    object_type text NOT NULL,
    external_id text NOT NULL,
    sanitized_canonical_url text,
    canonical_identity_hash text,
    display_title text,
    status_key text,
    status_label text,
    status_category text DEFAULT 'unknown'::text NOT NULL,
    status_tone text DEFAULT 'neutral'::text NOT NULL,
    liveness text DEFAULT 'unknown'::text NOT NULL,
    is_terminal boolean DEFAULT false NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    remote_version text,
    etag text,
    last_resolved_at timestamp with time zone,
    last_changed_at timestamp with time zone,
    last_error_at timestamp with time zone,
    next_refresh_at timestamp with time zone,
    last_error_code text,
    last_error_message text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    display_key text,
    icon_key text,
    status_icon_key text,
    refresh_started_at timestamp with time zone,
    refresh_token uuid
);


--
-- Name: feedback_exports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.feedback_exports (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    feedback_vote_id uuid NOT NULL,
    issue_id uuid NOT NULL,
    project_id uuid,
    author_user_id text NOT NULL,
    target_type text NOT NULL,
    target_id text NOT NULL,
    vote text NOT NULL,
    status text DEFAULT 'local_only'::text NOT NULL,
    destination text,
    export_id text,
    consent_version text,
    schema_version text DEFAULT 'paperclip-feedback-envelope-v2'::text NOT NULL,
    bundle_version text DEFAULT 'paperclip-feedback-bundle-v2'::text NOT NULL,
    payload_version text DEFAULT 'paperclip-feedback-v1'::text NOT NULL,
    payload_digest text,
    payload_snapshot jsonb,
    target_summary jsonb NOT NULL,
    redaction_summary jsonb,
    attempt_count integer DEFAULT 0 NOT NULL,
    last_attempted_at timestamp with time zone,
    exported_at timestamp with time zone,
    failure_reason text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: feedback_votes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.feedback_votes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    issue_id uuid NOT NULL,
    target_type text NOT NULL,
    target_id text NOT NULL,
    author_user_id text NOT NULL,
    vote text NOT NULL,
    reason text,
    shared_with_labs boolean DEFAULT false NOT NULL,
    shared_at timestamp with time zone,
    consent_version text,
    redaction_summary jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: finance_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.finance_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    agent_id uuid,
    issue_id uuid,
    project_id uuid,
    goal_id uuid,
    heartbeat_run_id uuid,
    cost_event_id uuid,
    billing_code text,
    description text,
    event_kind text NOT NULL,
    direction text DEFAULT 'debit'::text NOT NULL,
    biller text NOT NULL,
    provider text,
    execution_adapter_type text,
    pricing_tier text,
    region text,
    model text,
    quantity integer,
    unit text,
    amount_cents integer NOT NULL,
    currency text DEFAULT 'USD'::text NOT NULL,
    estimated boolean DEFAULT false NOT NULL,
    external_invoice_id text,
    metadata_json jsonb,
    occurred_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: folders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.folders (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    kind text NOT NULL,
    name text NOT NULL,
    color text,
    "position" integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    parent_id uuid,
    slug text NOT NULL,
    system_key text
);


--
-- Name: goals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.goals (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    title text NOT NULL,
    description text,
    level text DEFAULT 'task'::text NOT NULL,
    status text DEFAULT 'planned'::text NOT NULL,
    parent_id uuid,
    owner_agent_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: heartbeat_run_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.heartbeat_run_events (
    id bigint NOT NULL,
    company_id uuid NOT NULL,
    run_id uuid NOT NULL,
    agent_id uuid NOT NULL,
    seq bigint NOT NULL,
    event_type text NOT NULL,
    stream text,
    level text,
    color text,
    message text,
    payload jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    source_instance_id text,
    source_event_id text,
    source_seq bigint,
    source_payload_sha256 text,
    protocol_schema_version integer
);


--
-- Name: heartbeat_run_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.heartbeat_run_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: heartbeat_run_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.heartbeat_run_events_id_seq OWNED BY public.heartbeat_run_events.id;


--
-- Name: heartbeat_run_watchdog_decisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.heartbeat_run_watchdog_decisions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    run_id uuid NOT NULL,
    evaluation_issue_id uuid,
    decision text NOT NULL,
    snoozed_until timestamp with time zone,
    reason text,
    created_by_agent_id uuid,
    created_by_user_id text,
    created_by_run_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: heartbeat_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.heartbeat_runs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    agent_id uuid NOT NULL,
    invocation_source text DEFAULT 'on_demand'::text NOT NULL,
    status text DEFAULT 'queued'::text NOT NULL,
    started_at timestamp with time zone,
    finished_at timestamp with time zone,
    error text,
    external_run_id text,
    context_snapshot jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    trigger_detail text,
    wakeup_request_id uuid,
    exit_code integer,
    signal text,
    usage_json jsonb,
    result_json jsonb,
    session_id_before text,
    session_id_after text,
    log_store text,
    log_ref text,
    log_bytes bigint,
    log_sha256 text,
    log_compressed boolean DEFAULT false NOT NULL,
    stdout_excerpt text,
    stderr_excerpt text,
    error_code text,
    process_pid integer,
    process_started_at timestamp with time zone,
    retry_of_run_id uuid,
    process_loss_retry_count integer DEFAULT 0 NOT NULL,
    issue_comment_status text DEFAULT 'not_applicable'::text NOT NULL,
    issue_comment_satisfied_by_comment_id uuid,
    issue_comment_retry_queued_at timestamp with time zone,
    process_group_id integer,
    liveness_state text,
    liveness_reason text,
    continuation_attempt integer DEFAULT 0 NOT NULL,
    last_useful_action_at timestamp with time zone,
    next_action text,
    scheduled_retry_at timestamp with time zone,
    scheduled_retry_attempt integer DEFAULT 0 NOT NULL,
    scheduled_retry_reason text,
    last_output_at timestamp with time zone,
    last_output_seq integer DEFAULT 0 NOT NULL,
    last_output_stream text,
    last_output_bytes bigint,
    responsible_user_id text,
    runtime_mode text DEFAULT 'legacy'::text NOT NULL,
    runtime_mode_resolver_version text,
    runtime_mode_reason text,
    runtime_mode_resolved_at timestamp with time zone,
    runner_profile_json jsonb,
    runner_instance_id uuid,
    native_session_id uuid,
    native_issue_id uuid,
    driver_kind text,
    driver_version text,
    completion_contract_id uuid,
    completion_contract_sha256 text,
    next_event_seq bigint DEFAULT 1 NOT NULL,
    native_phase text,
    native_phase_updated_at timestamp with time zone,
    active_identity_context_id uuid,
    execution_control_deadline_at timestamp with time zone,
    execution_status_delivery_id uuid,
    controller_boot_id uuid,
    controller_lease_expires_at timestamp with time zone,
    execution_stage text
);


--
-- Name: inbox_dismissals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inbox_dismissals (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    user_id text NOT NULL,
    item_key text NOT NULL,
    dismissed_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    kind text DEFAULT 'dismiss'::text NOT NULL,
    snoozed_until timestamp with time zone,
    CONSTRAINT inbox_dismissals_kind_check CHECK ((kind = ANY (ARRAY['dismiss'::text, 'snooze'::text]))),
    CONSTRAINT inbox_dismissals_kind_snooze_until_check CHECK ((((kind = 'dismiss'::text) AND (snoozed_until IS NULL)) OR ((kind = 'snooze'::text) AND (snoozed_until IS NOT NULL))))
);


--
-- Name: instance_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.instance_settings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    singleton_key text DEFAULT 'default'::text NOT NULL,
    experimental jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    general jsonb DEFAULT '{}'::jsonb NOT NULL,
    default_environment_id uuid
);


--
-- Name: instance_user_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.instance_user_roles (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id text NOT NULL,
    role text DEFAULT 'instance_admin'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: invites; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invites (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid,
    invite_type text DEFAULT 'company_join'::text NOT NULL,
    token_hash text NOT NULL,
    allowed_join_types text DEFAULT 'both'::text NOT NULL,
    defaults_payload jsonb,
    expires_at timestamp with time zone NOT NULL,
    invited_by_user_id text,
    revoked_at timestamp with time zone,
    accepted_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: issue_approvals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.issue_approvals (
    company_id uuid NOT NULL,
    issue_id uuid NOT NULL,
    approval_id uuid NOT NULL,
    linked_by_agent_id uuid,
    linked_by_user_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: issue_attachments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.issue_attachments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    issue_id uuid NOT NULL,
    asset_id uuid NOT NULL,
    issue_comment_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    originating_run_id uuid
);


--
-- Name: issue_comments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.issue_comments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    issue_id uuid NOT NULL,
    author_agent_id uuid,
    author_user_id text,
    body text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by_run_id uuid,
    author_type text,
    presentation jsonb,
    metadata jsonb,
    deleted_at timestamp with time zone,
    deleted_by_type text,
    deleted_by_agent_id uuid,
    deleted_by_user_id text,
    deleted_by_run_id uuid,
    source_trust jsonb,
    derived_author_agent_id uuid,
    derived_created_by_run_id uuid,
    derived_author_source text,
    on_behalf_of_user_id text,
    client_request_id text,
    conversation_session_generation integer
);


--
-- Name: issue_create_idempotency_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.issue_create_idempotency_keys (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    idempotency_key text NOT NULL,
    issue_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: issue_documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.issue_documents (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    issue_id uuid NOT NULL,
    document_id uuid NOT NULL,
    key text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: issue_execution_decisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.issue_execution_decisions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    issue_id uuid NOT NULL,
    stage_id uuid NOT NULL,
    stage_type text NOT NULL,
    actor_agent_id uuid,
    actor_user_id text,
    outcome text NOT NULL,
    body text NOT NULL,
    created_by_run_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: issue_inbox_archives; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.issue_inbox_archives (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    issue_id uuid NOT NULL,
    user_id text NOT NULL,
    archived_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    archived_by_actor_type text DEFAULT 'user'::text NOT NULL,
    archived_by_agent_id uuid,
    archived_by_run_id uuid,
    CONSTRAINT issue_inbox_archives_archived_by_actor_type_check CHECK ((archived_by_actor_type = ANY (ARRAY['user'::text, 'agent'::text])))
);


--
-- Name: issue_labels; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.issue_labels (
    issue_id uuid NOT NULL,
    label_id uuid NOT NULL,
    company_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: issue_plan_decompositions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.issue_plan_decompositions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    source_issue_id uuid NOT NULL,
    accepted_plan_revision_id uuid NOT NULL,
    accepted_interaction_id uuid,
    status text DEFAULT 'in_flight'::text NOT NULL,
    request_fingerprint text NOT NULL,
    requested_child_count integer DEFAULT 0 NOT NULL,
    requested_children jsonb DEFAULT '[]'::jsonb NOT NULL,
    child_issue_ids jsonb DEFAULT '[]'::jsonb NOT NULL,
    owner_agent_id uuid,
    owner_user_id text,
    owner_run_id uuid,
    completed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: issue_question_response_deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.issue_question_response_deliveries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    issue_id uuid NOT NULL,
    interaction_id uuid NOT NULL,
    source_run_id uuid,
    target_run_id uuid,
    target_turn_id text,
    correlation_id text NOT NULL,
    payload_sha256 text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    delivery_mode text,
    attempt_count integer DEFAULT 0 NOT NULL,
    error_count integer DEFAULT 0 NOT NULL,
    last_attempt_at timestamp with time zone,
    acknowledged_at timestamp with time zone,
    last_error_code text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT issue_question_response_deliveries_mode_check CHECK (((delivery_mode IS NULL) OR (delivery_mode = ANY (ARRAY['steered'::text, 'coalesced'::text, 'wake_fallback'::text])))),
    CONSTRAINT issue_question_response_deliveries_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'delivering'::text, 'delivered'::text, 'fallback_queued'::text, 'failed'::text])))
);


--
-- Name: issue_read_states; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.issue_read_states (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    issue_id uuid NOT NULL,
    user_id text NOT NULL,
    last_read_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: issue_recovery_actions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.issue_recovery_actions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    source_issue_id uuid NOT NULL,
    recovery_issue_id uuid,
    kind text NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    owner_type text DEFAULT 'agent'::text NOT NULL,
    owner_agent_id uuid,
    owner_user_id text,
    previous_owner_agent_id uuid,
    return_owner_agent_id uuid,
    cause text NOT NULL,
    fingerprint text NOT NULL,
    evidence jsonb DEFAULT '{}'::jsonb NOT NULL,
    next_action text NOT NULL,
    wake_policy jsonb,
    monitor_policy jsonb,
    attempt_count integer DEFAULT 0 NOT NULL,
    max_attempts integer,
    timeout_at timestamp with time zone,
    last_attempt_at timestamp with time zone,
    outcome text,
    resolution_note text,
    resolved_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    review_epoch_key text,
    corrective_wakeup_request_id uuid,
    corrective_run_id uuid
);


--
-- Name: issue_reference_mentions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.issue_reference_mentions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    source_issue_id uuid NOT NULL,
    target_issue_id uuid NOT NULL,
    source_kind text NOT NULL,
    source_record_id uuid,
    document_key text,
    matched_text text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: issue_relations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.issue_relations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    issue_id uuid NOT NULL,
    related_issue_id uuid NOT NULL,
    type text NOT NULL,
    created_by_agent_id uuid,
    created_by_user_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: issue_thread_interactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.issue_thread_interactions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    issue_id uuid NOT NULL,
    kind text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    continuation_policy text DEFAULT 'wake_assignee'::text NOT NULL,
    source_comment_id uuid,
    source_run_id uuid,
    title text,
    summary text,
    created_by_agent_id uuid,
    created_by_user_id text,
    resolved_by_agent_id uuid,
    resolved_by_user_id text,
    payload jsonb NOT NULL,
    result jsonb,
    resolved_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    idempotency_key text,
    requested_resolver_policy text DEFAULT 'anyone'::text NOT NULL,
    effective_resolver_policy text DEFAULT 'anyone'::text NOT NULL,
    resolved_by_run_id uuid,
    addressee_agent_id uuid,
    resolver_policy_provenance text DEFAULT 'inherited'::text NOT NULL,
    effective_resolver_policy_source text DEFAULT 'requested'::text CONSTRAINT issue_thread_interactions_effective_resolver_policy_so_not_null NOT NULL,
    addressee_user_id text,
    source_identity_context_id uuid,
    origin_comment_ids jsonb DEFAULT '[]'::jsonb NOT NULL
);


--
-- Name: issue_tree_hold_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.issue_tree_hold_members (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    hold_id uuid NOT NULL,
    issue_id uuid NOT NULL,
    parent_issue_id uuid,
    depth integer DEFAULT 0 NOT NULL,
    issue_identifier text,
    issue_title text NOT NULL,
    issue_status text NOT NULL,
    assignee_agent_id uuid,
    assignee_user_id text,
    active_run_id uuid,
    active_run_status text,
    skipped boolean DEFAULT false NOT NULL,
    skip_reason text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: issue_tree_holds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.issue_tree_holds (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    root_issue_id uuid NOT NULL,
    mode text NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    reason text,
    release_policy jsonb,
    created_by_actor_type text DEFAULT 'system'::text NOT NULL,
    created_by_agent_id uuid,
    created_by_user_id text,
    created_by_run_id uuid,
    released_at timestamp with time zone,
    released_by_actor_type text,
    released_by_agent_id uuid,
    released_by_user_id text,
    released_by_run_id uuid,
    release_reason text,
    release_metadata jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: issue_watchdogs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.issue_watchdogs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    issue_id uuid NOT NULL,
    watchdog_agent_id uuid NOT NULL,
    instructions text,
    status text DEFAULT 'active'::text NOT NULL,
    watchdog_issue_id uuid,
    last_observed_fingerprint text,
    last_reviewed_fingerprint text,
    last_triggered_at timestamp with time zone,
    last_completed_at timestamp with time zone,
    trigger_count integer DEFAULT 0 NOT NULL,
    created_by_agent_id uuid,
    created_by_user_id text,
    created_by_run_id uuid,
    updated_by_agent_id uuid,
    updated_by_user_id text,
    updated_by_run_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    last_observed_stop_snapshot jsonb,
    last_reviewed_stop_snapshot jsonb
);


--
-- Name: issue_work_products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.issue_work_products (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    project_id uuid,
    issue_id uuid NOT NULL,
    execution_workspace_id uuid,
    runtime_service_id uuid,
    type text NOT NULL,
    provider text NOT NULL,
    external_id text,
    title text NOT NULL,
    url text,
    status text NOT NULL,
    review_state text DEFAULT 'none'::text NOT NULL,
    is_primary boolean DEFAULT false NOT NULL,
    health_status text DEFAULT 'unknown'::text NOT NULL,
    summary text,
    metadata jsonb,
    created_by_run_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    source_trust jsonb
);


--
-- Name: issues; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.issues (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    project_id uuid,
    goal_id uuid,
    parent_id uuid,
    title text NOT NULL,
    description text,
    status text DEFAULT 'backlog'::text NOT NULL,
    priority text DEFAULT 'medium'::text NOT NULL,
    assignee_agent_id uuid,
    created_by_agent_id uuid,
    created_by_user_id text,
    request_depth integer DEFAULT 0 NOT NULL,
    billing_code text,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    cancelled_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    issue_number integer,
    identifier text,
    hidden_at timestamp with time zone,
    checkout_run_id uuid,
    execution_run_id uuid,
    execution_agent_name_key text,
    execution_locked_at timestamp with time zone,
    assignee_user_id text,
    assignee_adapter_overrides jsonb,
    execution_workspace_settings jsonb,
    project_workspace_id uuid,
    execution_workspace_id uuid,
    execution_workspace_preference text,
    origin_kind text DEFAULT 'manual'::text NOT NULL,
    origin_id text,
    origin_run_id text,
    execution_policy jsonb,
    execution_state jsonb,
    origin_fingerprint text DEFAULT 'default'::text NOT NULL,
    monitor_next_check_at timestamp with time zone,
    monitor_wake_requested_at timestamp with time zone,
    monitor_last_triggered_at timestamp with time zone,
    monitor_attempt_count integer DEFAULT 0 NOT NULL,
    monitor_notes text,
    monitor_scheduled_by text,
    work_mode text DEFAULT 'standard'::text NOT NULL,
    source_trust jsonb,
    responsible_user_id text,
    harness_kind text,
    unblock_descriptor jsonb,
    blocked_transition_at timestamp with time zone,
    blocked_owner_notified_at timestamp with time zone,
    review_epoch_id uuid,
    review_policy text,
    status_version bigint DEFAULT 0 NOT NULL,
    last_status_decision_id uuid,
    origin_identity_context_id uuid,
    continuation_identity_context_id uuid,
    conversation_agent_id uuid,
    conversation_user_id text,
    conversation_state text,
    conversation_session_generation integer DEFAULT 0 NOT NULL,
    conversation_boundary_comment_id uuid,
    title_needs_generation boolean DEFAULT false NOT NULL,
    CONSTRAINT issues_conversation_identity_check CHECK ((((conversation_agent_id IS NULL) AND (conversation_user_id IS NULL) AND (conversation_state IS NULL)) OR ((conversation_agent_id IS NOT NULL) AND (conversation_user_id IS NOT NULL) AND (assignee_agent_id = conversation_agent_id) AND (assignee_agent_id IS NOT NULL) AND (assignee_user_id IS NULL) AND (conversation_state IS NOT NULL) AND (conversation_state = ANY (ARRAY['active'::text, 'waiting'::text])) AND (status <> ALL (ARRAY['done'::text, 'cancelled'::text])))))
);


--
-- Name: join_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.join_requests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    invite_id uuid NOT NULL,
    company_id uuid NOT NULL,
    request_type text NOT NULL,
    status text DEFAULT 'pending_approval'::text NOT NULL,
    request_ip text NOT NULL,
    requesting_user_id text,
    request_email_snapshot text,
    agent_name text,
    adapter_type text,
    capabilities text,
    agent_defaults_payload jsonb,
    created_agent_id uuid,
    approved_by_user_id text,
    approved_at timestamp with time zone,
    rejected_by_user_id text,
    rejected_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    claim_secret_hash text,
    claim_secret_expires_at timestamp with time zone,
    claim_secret_consumed_at timestamp with time zone
);


--
-- Name: labels; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.labels (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    name text NOT NULL,
    color text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: managed_agent_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.managed_agent_profiles (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    profile_key text NOT NULL,
    display_name text NOT NULL,
    service text DEFAULT 'anthropic_managed_agents'::text NOT NULL,
    anthropic_agent_id text NOT NULL,
    agent_version text NOT NULL,
    environment_id text NOT NULL,
    beta_version text DEFAULT 'managed-agents-2026-04-01'::text NOT NULL,
    default_model text DEFAULT 'claude-sonnet-5'::text NOT NULL,
    default_max_list_cost_cents integer DEFAULT 100 NOT NULL,
    api_key_secret_id uuid NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    retention_acknowledged boolean DEFAULT false NOT NULL,
    qualification jsonb DEFAULT '{}'::jsonb NOT NULL,
    qualified_at timestamp with time zone,
    qualified_revision text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT managed_agent_profiles_beta_check CHECK ((beta_version = 'managed-agents-2026-04-01'::text)),
    CONSTRAINT managed_agent_profiles_positive_budget_check CHECK ((default_max_list_cost_cents > 0)),
    CONSTRAINT managed_agent_profiles_qualified_revision_check CHECK ((((qualified_at IS NULL) AND (qualified_revision IS NULL)) OR ((qualified_at IS NOT NULL) AND (qualification <> '{}'::jsonb) AND (qualified_revision ~ '^sha256:[0-9a-f]{64}$'::text)))),
    CONSTRAINT managed_agent_profiles_service_check CHECK ((service = 'anthropic_managed_agents'::text))
);


--
-- Name: native_run_finalizations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.native_run_finalizations (
    run_id uuid NOT NULL,
    company_id uuid NOT NULL,
    issue_id uuid NOT NULL,
    phase text NOT NULL,
    attempt integer DEFAULT 0 NOT NULL,
    lease_owner text,
    lease_expires_at timestamp with time zone,
    result_id uuid,
    assessment_id uuid,
    decision_id uuid,
    failure_code text,
    failure_detail jsonb,
    next_attempt_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    controller_boot_id text,
    controller_pid integer,
    controller_process_started_at timestamp with time zone,
    controller_generation integer DEFAULT 0 NOT NULL,
    recovery_state text,
    recovery_request_id text,
    recovery_history jsonb DEFAULT '[]'::jsonb NOT NULL,
    control_deadline_at timestamp with time zone,
    CONSTRAINT native_run_finalizations_assessment_requires_result_check CHECK (((assessment_id IS NULL) OR (result_id IS NOT NULL))),
    CONSTRAINT native_run_finalizations_decision_requires_assessment_check CHECK (((decision_id IS NULL) OR (assessment_id IS NOT NULL)))
);


--
-- Name: native_run_results; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.native_run_results (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    issue_id uuid NOT NULL,
    run_id uuid NOT NULL,
    turn_id text,
    completion_contract_id uuid NOT NULL,
    caller_result_id text,
    caller_dedupe_key text,
    server_fingerprint text NOT NULL,
    schema_status text NOT NULL,
    rejection_code text,
    result_json jsonb NOT NULL,
    canonical_sha256 text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: pipeline_automation_executions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pipeline_automation_executions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    case_id uuid NOT NULL,
    automation_id text NOT NULL,
    triggering_event_id uuid NOT NULL,
    routine_id uuid NOT NULL,
    status text NOT NULL,
    execution_issue_id uuid,
    error text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    retry_of_execution_id uuid,
    generation integer DEFAULT 1 NOT NULL,
    CONSTRAINT pipeline_automation_executions_status_check CHECK ((status = ANY (ARRAY['succeeded'::text, 'failed'::text])))
);


--
-- Name: pipeline_case_blockers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pipeline_case_blockers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    case_id uuid NOT NULL,
    blocked_by_case_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT pipeline_case_blockers_no_self_block_check CHECK ((case_id <> blocked_by_case_id))
);


--
-- Name: pipeline_case_documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pipeline_case_documents (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    case_id uuid NOT NULL,
    document_id uuid NOT NULL,
    key text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: pipeline_case_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pipeline_case_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    case_id uuid NOT NULL,
    type text NOT NULL,
    actor_type text NOT NULL,
    actor_user_id text,
    actor_agent_id uuid,
    run_id uuid,
    from_stage_id uuid,
    to_stage_id uuid,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT pipeline_case_events_actor_type_check CHECK ((actor_type = ANY (ARRAY['user'::text, 'agent'::text, 'system'::text]))),
    CONSTRAINT pipeline_case_events_agent_run_check CHECK (((actor_type <> 'agent'::text) OR (run_id IS NOT NULL))),
    CONSTRAINT pipeline_case_events_type_check CHECK ((type = ANY (ARRAY['ingested'::text, 'updated'::text, 'claimed'::text, 'lease_released'::text, 'lease_expired'::text, 'transitioned'::text, 'transition_forced'::text, 'transition_suggested'::text, 'suggestion_resolved'::text, 'review_decided'::text, 'conversation_opened'::text, 'issue_linked'::text, 'issue_unlinked'::text, 'automation_executed'::text, 'automation_failed'::text, 'automation_retry_requested'::text, 'automation_effects_retired'::text, 'automation_retry_dispatched'::text, 'blockers_set'::text, 'blockers_resolved'::text, 'children_terminal'::text, 'upstream_drift'::text, 'drift_acknowledged'::text])))
);


--
-- Name: pipeline_case_issue_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pipeline_case_issue_links (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    case_id uuid NOT NULL,
    issue_id uuid NOT NULL,
    role text NOT NULL,
    created_by_run_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    automation_attempt_id uuid,
    retired_at timestamp with time zone,
    retired_by_attempt_id uuid,
    retired_reason text,
    CONSTRAINT pipeline_case_issue_links_role_check CHECK ((role = ANY (ARRAY['origin'::text, 'conversation'::text, 'work'::text, 'automation'::text])))
);


--
-- Name: pipeline_cases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pipeline_cases (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    pipeline_id uuid NOT NULL,
    stage_id uuid NOT NULL,
    case_key text NOT NULL,
    title text NOT NULL,
    summary text,
    fields jsonb DEFAULT '{}'::jsonb NOT NULL,
    workspace_ref jsonb,
    parent_case_id uuid,
    version integer DEFAULT 1 NOT NULL,
    pending_suggestion jsonb,
    lease_owner_type text,
    lease_agent_id uuid,
    lease_user_id text,
    lease_token uuid,
    lease_expires_at timestamp with time zone,
    terminal_kind text,
    terminal_at timestamp with time zone,
    child_count integer DEFAULT 0 NOT NULL,
    terminal_child_count integer DEFAULT 0 NOT NULL,
    created_by_user_id text,
    created_by_agent_id uuid,
    origin_run_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    parent_case_version integer,
    request_key text,
    automation_attempt_id uuid,
    retired_at timestamp with time zone,
    retired_by_attempt_id uuid,
    retired_reason text,
    hidden_from_board_at timestamp with time zone,
    CONSTRAINT pipeline_cases_lease_owner_type_check CHECK (((lease_owner_type IS NULL) OR (lease_owner_type = ANY (ARRAY['user'::text, 'agent'::text])))),
    CONSTRAINT pipeline_cases_terminal_kind_check CHECK (((terminal_kind IS NULL) OR (terminal_kind = ANY (ARRAY['done'::text, 'cancelled'::text]))))
);


--
-- Name: pipeline_documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pipeline_documents (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    pipeline_id uuid NOT NULL,
    document_id uuid NOT NULL,
    key text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: pipeline_stages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pipeline_stages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    pipeline_id uuid NOT NULL,
    key text NOT NULL,
    name text NOT NULL,
    kind text NOT NULL,
    "position" integer NOT NULL,
    config jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT pipeline_stages_kind_check CHECK ((kind = ANY (ARRAY['working'::text, 'review'::text, 'done'::text, 'cancelled'::text])))
);


--
-- Name: pipeline_transitions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pipeline_transitions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    pipeline_id uuid NOT NULL,
    from_stage_id uuid NOT NULL,
    to_stage_id uuid NOT NULL,
    label text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: pipelines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pipelines (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    project_id uuid,
    key text NOT NULL,
    name text NOT NULL,
    description text,
    enforce_transitions boolean DEFAULT false NOT NULL,
    created_by_user_id text,
    created_by_agent_id uuid,
    archived_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: plugin_company_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.plugin_company_settings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    plugin_id uuid NOT NULL,
    settings_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    last_error text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    enabled boolean DEFAULT true NOT NULL
);


--
-- Name: plugin_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.plugin_config (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    plugin_id uuid NOT NULL,
    config_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    last_error text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    company_id uuid NOT NULL
);


--
-- Name: plugin_database_namespaces; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.plugin_database_namespaces (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    plugin_id uuid NOT NULL,
    plugin_key text NOT NULL,
    namespace_name text NOT NULL,
    namespace_mode text DEFAULT 'schema'::text NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: plugin_entities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.plugin_entities (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    plugin_id uuid NOT NULL,
    entity_type text NOT NULL,
    scope_kind text NOT NULL,
    scope_id text,
    external_id text,
    title text,
    status text,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    company_id uuid
);


--
-- Name: plugin_job_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.plugin_job_runs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    job_id uuid NOT NULL,
    plugin_id uuid NOT NULL,
    trigger text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    duration_ms integer,
    error text,
    logs jsonb DEFAULT '[]'::jsonb NOT NULL,
    started_at timestamp with time zone,
    finished_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    company_id uuid
);


--
-- Name: plugin_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.plugin_jobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    plugin_id uuid NOT NULL,
    job_key text NOT NULL,
    schedule text NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    last_run_at timestamp with time zone,
    next_run_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: plugin_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.plugin_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    plugin_id uuid NOT NULL,
    level text DEFAULT 'info'::text NOT NULL,
    message text NOT NULL,
    meta jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    company_id uuid
);


--
-- Name: plugin_managed_resources; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.plugin_managed_resources (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    plugin_id uuid NOT NULL,
    plugin_key text NOT NULL,
    resource_kind text NOT NULL,
    resource_key text NOT NULL,
    resource_id uuid NOT NULL,
    defaults_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: plugin_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.plugin_migrations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    plugin_id uuid NOT NULL,
    plugin_key text NOT NULL,
    namespace_name text NOT NULL,
    migration_key text NOT NULL,
    checksum text NOT NULL,
    plugin_version text NOT NULL,
    status text NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    applied_at timestamp with time zone,
    error_message text
);


--
-- Name: plugin_state; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.plugin_state (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    plugin_id uuid NOT NULL,
    scope_kind text NOT NULL,
    scope_id text,
    namespace text DEFAULT 'default'::text NOT NULL,
    state_key text NOT NULL,
    value_json jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: plugin_webhook_deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.plugin_webhook_deliveries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    plugin_id uuid NOT NULL,
    webhook_key text NOT NULL,
    external_id text,
    status text DEFAULT 'pending'::text NOT NULL,
    duration_ms integer,
    error text,
    payload jsonb NOT NULL,
    headers jsonb DEFAULT '{}'::jsonb NOT NULL,
    started_at timestamp with time zone,
    finished_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    company_id uuid
);


--
-- Name: plugins; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.plugins (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    plugin_key text NOT NULL,
    package_name text NOT NULL,
    package_path text,
    version text NOT NULL,
    api_version integer DEFAULT 1 NOT NULL,
    categories jsonb DEFAULT '[]'::jsonb NOT NULL,
    manifest_json jsonb NOT NULL,
    status text DEFAULT 'installed'::text NOT NULL,
    install_order integer,
    last_error text,
    installed_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: principal_permission_grants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.principal_permission_grants (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    principal_type text NOT NULL,
    principal_id text NOT NULL,
    permission_key text NOT NULL,
    scope jsonb,
    granted_by_user_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: project_goals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.project_goals (
    project_id uuid NOT NULL,
    goal_id uuid NOT NULL,
    company_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: project_memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.project_memberships (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    project_id uuid NOT NULL,
    user_id text NOT NULL,
    state text DEFAULT 'joined'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    starred_at timestamp with time zone
);


--
-- Name: project_workspaces; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.project_workspaces (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    project_id uuid NOT NULL,
    name text NOT NULL,
    cwd text,
    repo_url text,
    repo_ref text,
    metadata jsonb,
    is_primary boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    source_type text DEFAULT 'local_path'::text NOT NULL,
    default_ref text,
    visibility text DEFAULT 'default'::text NOT NULL,
    setup_command text,
    cleanup_command text,
    remote_provider text,
    remote_workspace_ref text,
    shared_workspace_key text
);


--
-- Name: projects; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.projects (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    goal_id uuid,
    name text NOT NULL,
    description text,
    status text DEFAULT 'backlog'::text NOT NULL,
    lead_agent_id uuid,
    target_date date,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    color text,
    archived_at timestamp with time zone,
    execution_workspace_policy jsonb,
    pause_reason text,
    paused_at timestamp with time zone,
    env jsonb,
    icon text
);


--
-- Name: provider_trace_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.provider_trace_records (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    run_id uuid NOT NULL,
    status text DEFAULT 'capturing'::text NOT NULL,
    provider text NOT NULL,
    trace_ref text NOT NULL,
    frame_count integer DEFAULT 0 NOT NULL,
    byte_count bigint DEFAULT 0 NOT NULL,
    digest text,
    reason text,
    requested_by text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    deleted_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: remote_agent_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.remote_agent_profiles (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    profile_key text NOT NULL,
    display_name text NOT NULL,
    service text NOT NULL,
    configuration jsonb DEFAULT '{}'::jsonb NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    retention_acknowledged boolean DEFAULT false NOT NULL,
    qualification jsonb DEFAULT '{}'::jsonb NOT NULL,
    qualified_at timestamp with time zone,
    qualified_revision text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT remote_agent_profiles_qualified_revision_check CHECK ((((qualified_at IS NULL) AND (qualified_revision IS NULL)) OR ((qualified_at IS NOT NULL) AND (qualification <> '{}'::jsonb) AND (qualified_revision ~ '^sha256:[0-9a-f]{64}$'::text)))),
    CONSTRAINT remote_agent_profiles_service_check CHECK ((service = 'aws_bedrock_agentcore_harness'::text))
);


--
-- Name: resource_lifecycle_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resource_lifecycle_events (
    id bigint NOT NULL,
    company_id uuid NOT NULL,
    resource_type text NOT NULL,
    resource_id uuid NOT NULL,
    action text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT resource_lifecycle_events_action_check CHECK (((action = 'create'::text) OR ((resource_type = 'agent'::text) AND (action = ANY (ARRAY['pause'::text, 'resume'::text, 'terminate'::text]))))),
    CONSTRAINT resource_lifecycle_events_resource_type_check CHECK ((resource_type = ANY (ARRAY['agent'::text, 'project'::text])))
);


--
-- Name: resource_lifecycle_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.resource_lifecycle_events ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.resource_lifecycle_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: routine_documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.routine_documents (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    routine_id uuid NOT NULL,
    document_id uuid NOT NULL,
    key text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: routine_revisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.routine_revisions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    routine_id uuid NOT NULL,
    revision_number integer NOT NULL,
    title text NOT NULL,
    description text,
    snapshot jsonb NOT NULL,
    change_summary text,
    restored_from_revision_id uuid,
    created_by_agent_id uuid,
    created_by_user_id text,
    created_by_run_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    responsible_user_id text
);


--
-- Name: routine_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.routine_runs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    routine_id uuid NOT NULL,
    trigger_id uuid,
    source text NOT NULL,
    status text DEFAULT 'received'::text NOT NULL,
    triggered_at timestamp with time zone DEFAULT now() NOT NULL,
    idempotency_key text,
    trigger_payload jsonb,
    linked_issue_id uuid,
    coalesced_into_run_id uuid,
    failure_reason text,
    completed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    dispatch_fingerprint text,
    routine_revision_id uuid,
    responsible_user_id text
);


--
-- Name: routine_triggers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.routine_triggers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    routine_id uuid NOT NULL,
    kind text NOT NULL,
    label text,
    enabled boolean DEFAULT true NOT NULL,
    cron_expression text,
    timezone text,
    next_run_at timestamp with time zone,
    last_fired_at timestamp with time zone,
    public_id text,
    secret_id uuid,
    signing_mode text,
    replay_window_sec integer,
    last_rotated_at timestamp with time zone,
    last_result text,
    created_by_agent_id uuid,
    created_by_user_id text,
    updated_by_agent_id uuid,
    updated_by_user_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    setup_pending boolean DEFAULT false NOT NULL,
    archived boolean DEFAULT false NOT NULL,
    last_webhook_delivery jsonb
);


--
-- Name: routine_webhook_test_receipts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.routine_webhook_test_receipts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    trigger_id uuid NOT NULL,
    delivery_key_hash text NOT NULL,
    received_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: routines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.routines (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    project_id uuid,
    goal_id uuid,
    parent_issue_id uuid,
    title text NOT NULL,
    description text,
    assignee_agent_id uuid,
    priority text DEFAULT 'medium'::text NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    concurrency_policy text DEFAULT 'coalesce_if_active'::text NOT NULL,
    catch_up_policy text DEFAULT 'skip_missed'::text NOT NULL,
    created_by_agent_id uuid,
    created_by_user_id text,
    updated_by_agent_id uuid,
    updated_by_user_id text,
    last_triggered_at timestamp with time zone,
    last_enqueued_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    variables jsonb DEFAULT '[]'::jsonb NOT NULL,
    latest_revision_id uuid,
    latest_revision_number integer DEFAULT 1 NOT NULL,
    env jsonb,
    origin_kind text DEFAULT 'manual'::text NOT NULL,
    origin_id text,
    responsible_user_id text,
    activity_gate_policy text DEFAULT 'always'::text NOT NULL,
    activity_gate_scope text DEFAULT 'company'::text NOT NULL,
    folder_id uuid
);


--
-- Name: run_identity_contexts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.run_identity_contexts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    run_id uuid NOT NULL,
    revision integer NOT NULL,
    responsible_user_id text,
    message_id uuid,
    parent_context_id uuid,
    cause text NOT NULL,
    correlation_id text NOT NULL,
    status text DEFAULT 'accepted'::text NOT NULL,
    accepted_at timestamp with time zone,
    github jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: runner_api_response_reservations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.runner_api_response_reservations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    run_id uuid,
    asset_id uuid,
    reserved_bytes bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: secret_access_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_access_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    secret_id uuid,
    version integer,
    provider text NOT NULL,
    actor_type text NOT NULL,
    actor_id text,
    consumer_type text NOT NULL,
    consumer_id text NOT NULL,
    config_path text,
    issue_id uuid,
    heartbeat_run_id uuid,
    plugin_id uuid,
    outcome text NOT NULL,
    error_code text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    user_secret_definition_id uuid,
    secret_scope text DEFAULT 'company'::text NOT NULL,
    responsible_user_id text,
    credential_owner_user_id text,
    credential_subject_type text,
    credential_subject_id text
);


--
-- Name: session; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.session (
    id text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    token text NOT NULL,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    ip_address text,
    user_agent text,
    user_id text NOT NULL
);


--
-- Name: smoke_run_steps; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.smoke_run_steps (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    run_id uuid NOT NULL,
    path text NOT NULL,
    scenario_step text NOT NULL,
    status text NOT NULL,
    detail text,
    screenshot_artifact_ref jsonb,
    duration_ms integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: smoke_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.smoke_runs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    trigger text NOT NULL,
    status text DEFAULT 'running'::text NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    finished_at timestamp with time zone,
    summary jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: status_card_updates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.status_card_updates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    card_id uuid NOT NULL,
    kind text NOT NULL,
    trigger text NOT NULL,
    generation_issue_id uuid,
    run_id uuid,
    changes jsonb DEFAULT '[]'::jsonb NOT NULL,
    input_tokens integer DEFAULT 0 NOT NULL,
    output_tokens integer DEFAULT 0 NOT NULL,
    cost_cents integer DEFAULT 0 NOT NULL,
    model text,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    finished_at timestamp with time zone,
    status text NOT NULL,
    error text,
    query_version integer,
    change_summary text
);


--
-- Name: status_cards; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.status_cards (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    created_by_user_id text,
    created_by_agent_id uuid,
    title text,
    title_pinned boolean DEFAULT false NOT NULL,
    interest_prompt text NOT NULL,
    queries jsonb DEFAULT '[]'::jsonb NOT NULL,
    query_version integer DEFAULT 0 NOT NULL,
    query_compiled_at timestamp with time zone,
    query_compiled_by_agent_id uuid,
    refresh_policy jsonb NOT NULL,
    state text DEFAULT 'compiling'::text NOT NULL,
    pending_change_count integer DEFAULT 0 NOT NULL,
    last_change_at timestamp with time zone,
    fingerprint jsonb,
    fingerprint_at timestamp with time zone,
    document_id uuid,
    last_update_run_kind text,
    last_generated_at timestamp with time zone,
    last_model text,
    generating_issue_id uuid,
    failure_reason text,
    next_eval_at timestamp with time zone,
    archived_at timestamp with time zone,
    archived_by_user_id text,
    archived_by_agent_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    pending_change_hash text,
    agent_id uuid,
    mentioned_issue_ids jsonb DEFAULT '[]'::jsonb NOT NULL
);


--
-- Name: status_decision_effects; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.status_decision_effects (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    issue_id uuid NOT NULL,
    decision_id uuid NOT NULL,
    ordinal integer NOT NULL,
    effect_kind text NOT NULL,
    target_type text NOT NULL,
    target_id text,
    idempotency_key text NOT NULL,
    payload jsonb NOT NULL,
    delivery_state text DEFAULT 'pending'::text NOT NULL,
    attempt_count integer DEFAULT 0 NOT NULL,
    next_attempt_at timestamp with time zone,
    last_error text,
    delivered_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: status_decisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.status_decisions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    issue_id uuid NOT NULL,
    run_id uuid NOT NULL,
    assessment_id uuid NOT NULL,
    decision_version bigint NOT NULL,
    policy_version text NOT NULL,
    from_status text NOT NULL,
    to_status text NOT NULL,
    reason_code text NOT NULL,
    decision_json jsonb NOT NULL,
    decision_digest text NOT NULL,
    application_state text DEFAULT 'proposed'::text NOT NULL,
    supersedes_decision_id uuid,
    applied_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: summary_slots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.summary_slots (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    scope_kind text NOT NULL,
    scope_id uuid,
    slot_key text NOT NULL,
    document_id uuid,
    status text DEFAULT 'idle'::text NOT NULL,
    generating_issue_id uuid,
    last_generated_at timestamp with time zone,
    last_generated_by_agent_id uuid,
    last_model text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    failure_reason text
);


--
-- Name: tool_access_audit_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tool_access_audit_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    connection_id uuid,
    catalog_entry_id uuid,
    actor_type text DEFAULT 'system'::text NOT NULL,
    actor_id text,
    action text NOT NULL,
    outcome text NOT NULL,
    reason_code text,
    details jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    gateway_id uuid,
    gateway_token_id uuid,
    gateway_public_id text,
    client_name text,
    correlation_id text
);


--
-- Name: tool_action_deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tool_action_deliveries (
    action_request_id uuid NOT NULL,
    company_id uuid NOT NULL,
    issue_id uuid NOT NULL,
    interaction_id uuid NOT NULL,
    delivered_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: tool_action_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tool_action_requests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    invocation_id uuid NOT NULL,
    issue_id uuid,
    interaction_id uuid,
    approval_id uuid,
    status text DEFAULT 'pending'::text NOT NULL,
    canonical_arguments_hash text NOT NULL,
    canonical_arguments_summary jsonb NOT NULL,
    signed_arguments text,
    preview_markdown text,
    requested_by_agent_id uuid,
    requested_by_user_id text,
    resolved_by_agent_id uuid,
    resolved_by_user_id text,
    decided_by_agent_id uuid,
    decided_by_user_id text,
    decided_at timestamp with time zone,
    expires_at timestamp with time zone,
    resolved_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: tool_applications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tool_applications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    name text NOT NULL,
    type text NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    application_key text,
    description text,
    plugin_id uuid,
    owner_agent_id uuid,
    owner_user_id text,
    archived_at timestamp with time zone
);


--
-- Name: tool_call_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tool_call_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    event_type text NOT NULL,
    actor_type text DEFAULT 'system'::text NOT NULL,
    actor_id text,
    agent_id uuid,
    run_id uuid,
    issue_id uuid,
    application_id uuid,
    connection_id uuid,
    catalog_entry_id uuid,
    invocation_id uuid,
    action_request_id uuid,
    runtime_slot_id uuid,
    tool_name text,
    decision text,
    matched_policy_ids jsonb DEFAULT '[]'::jsonb NOT NULL,
    reason_code text,
    outcome text DEFAULT 'pending'::text NOT NULL,
    latency_ms integer,
    arguments_summary jsonb,
    request_hash text,
    request_summary jsonb,
    result_hash text,
    result_summary jsonb,
    result_size_bytes integer,
    redaction_plan jsonb,
    rate_limit_state jsonb,
    metadata jsonb,
    error_code text,
    error_message text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    gateway_id uuid,
    gateway_token_id uuid,
    gateway_public_id text,
    client_subject_type text,
    client_subject_id text,
    client_name text,
    mcp_session_id text,
    correlation_id text,
    policy_explanation jsonb,
    credential_scope_summary jsonb,
    header_policy_summary jsonb
);


--
-- Name: tool_catalog_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tool_catalog_entries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    connection_id uuid NOT NULL,
    name text NOT NULL,
    title text,
    description text,
    input_schema jsonb DEFAULT '{}'::jsonb NOT NULL,
    annotations jsonb DEFAULT '{}'::jsonb NOT NULL,
    risk_level text DEFAULT 'read'::text NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    version_hash text NOT NULL,
    first_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    last_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    quarantined_at timestamp with time zone,
    quarantine_reason text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    application_id uuid,
    entry_kind text DEFAULT 'tool'::text NOT NULL,
    tool_name text NOT NULL,
    output_schema jsonb,
    is_read_only boolean DEFAULT true NOT NULL,
    is_write boolean DEFAULT false NOT NULL,
    is_destructive boolean DEFAULT false NOT NULL,
    version text,
    schema_hash text,
    reviewed_at timestamp with time zone,
    reviewed_by_agent_id uuid,
    reviewed_by_user_id text
);


--
-- Name: tool_connection_app_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tool_connection_app_snapshots (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    connection_id uuid NOT NULL,
    user_id text NOT NULL,
    credential_key text NOT NULL,
    toolkit text NOT NULL,
    status text NOT NULL,
    accounts jsonb DEFAULT '[]'::jsonb NOT NULL,
    checked_at timestamp with time zone DEFAULT now() NOT NULL,
    error_at timestamp with time zone
);


--
-- Name: tool_connection_app_syncs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tool_connection_app_syncs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    connection_id uuid NOT NULL,
    user_id text NOT NULL,
    credential_key text NOT NULL,
    lease_id uuid NOT NULL,
    status text NOT NULL,
    checked integer DEFAULT 0 NOT NULL,
    total integer DEFAULT 0 NOT NULL,
    failed integer DEFAULT 0 NOT NULL,
    last_completed_at timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: tool_connection_installs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tool_connection_installs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    connection_id uuid NOT NULL,
    target_type text NOT NULL,
    target_id text NOT NULL,
    created_by_agent_id uuid,
    created_by_user_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT tool_connection_installs_target_type_check CHECK ((target_type = ANY (ARRAY['company'::text, 'agent'::text])))
);


--
-- Name: tool_connections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tool_connections (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    application_id uuid NOT NULL,
    name text NOT NULL,
    transport text NOT NULL,
    status text DEFAULT 'draft'::text NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    config jsonb DEFAULT '{}'::jsonb NOT NULL,
    credential_refs jsonb DEFAULT '[]'::jsonb NOT NULL,
    health_status text DEFAULT 'unchecked'::text NOT NULL,
    health_message text,
    last_health_at timestamp with time zone,
    last_catalog_refresh_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    connection_kind text DEFAULT 'managed'::text NOT NULL,
    transport_config jsonb DEFAULT '{}'::jsonb NOT NULL,
    credential_secret_refs jsonb DEFAULT '[]'::jsonb NOT NULL,
    health_checked_at timestamp with time zone,
    last_error text,
    created_by_agent_id uuid,
    created_by_user_id text,
    uid text NOT NULL,
    ownership text DEFAULT 'customer'::text NOT NULL,
    auth_kind text DEFAULT 'none'::text NOT NULL,
    credential_policy text DEFAULT 'shared'::text NOT NULL,
    credential_source text DEFAULT 'paperclip_vault'::text NOT NULL,
    external_credential jsonb,
    connection_purpose text DEFAULT 'tool'::text NOT NULL,
    agent_instructions jsonb,
    CONSTRAINT tool_connections_auth_kind_check CHECK ((auth_kind = ANY (ARRAY['oauth'::text, 'api_key'::text, 'none'::text]))),
    CONSTRAINT tool_connections_channel_transport_check CHECK ((((connection_purpose = 'tool'::text) AND (transport <> ALL (ARRAY['chat_sdk'::text, 'runtime_auth'::text]))) OR ((connection_purpose = 'channel'::text) AND ((transport = 'chat_sdk'::text) OR ((transport = 'rest_api'::text) AND ((config ->> 'provider'::text) = 'agentmail'::text)))) OR ((connection_purpose = 'ai'::text) AND (transport = 'runtime_auth'::text)))),
    CONSTRAINT tool_connections_credential_policy_check CHECK ((credential_policy = ANY (ARRAY['shared'::text, 'per_user'::text, 'per_user_with_fallback'::text, 'per_agent'::text]))),
    CONSTRAINT tool_connections_credential_source_check CHECK ((credential_source = ANY (ARRAY['paperclip_vault'::text, 'vercel_connect'::text]))),
    CONSTRAINT tool_connections_credential_source_one_of_check CHECK ((((credential_source = 'paperclip_vault'::text) AND (external_credential IS NULL)) OR ((credential_source = 'vercel_connect'::text) AND (external_credential IS NOT NULL) AND (jsonb_array_length(credential_refs) = 0) AND (jsonb_array_length(credential_secret_refs) = 0)))),
    CONSTRAINT tool_connections_ownership_check CHECK ((ownership = ANY (ARRAY['platform_shared'::text, 'platform_provisioned'::text, 'customer'::text, 'dcr'::text]))),
    CONSTRAINT tool_connections_purpose_check CHECK ((connection_purpose = ANY (ARRAY['tool'::text, 'channel'::text, 'ai'::text]))),
    CONSTRAINT tool_connections_transport_check CHECK ((transport = ANY (ARRAY['mcp_remote'::text, 'rest_api'::text, 'local_stdio'::text, 'chat_sdk'::text, 'runtime_auth'::text])))
);


--
-- Name: tool_gateway_rate_limit_counters; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tool_gateway_rate_limit_counters (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    counter_key text NOT NULL,
    window_start_at timestamp with time zone NOT NULL,
    window_ms integer NOT NULL,
    "limit" integer NOT NULL,
    count integer DEFAULT 0 NOT NULL,
    reset_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT tool_gateway_rate_limit_counters_window_bounds CHECK (((window_ms > 0) AND ("limit" > 0) AND (count >= 0)))
);


--
-- Name: tool_gateway_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tool_gateway_sessions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    agent_id uuid NOT NULL,
    run_id uuid NOT NULL,
    issue_id uuid,
    project_id uuid,
    token_hash text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    last_used_at timestamp with time zone,
    revoked_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    gateway_id uuid,
    gateway_token_id uuid,
    gateway_public_id text,
    client_subject_type text,
    client_subject_id text,
    client_name text,
    mcp_session_id text,
    correlation_id text
);


--
-- Name: tool_invocations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tool_invocations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    idempotency_key text,
    actor_type text DEFAULT 'system'::text NOT NULL,
    actor_id text,
    agent_id uuid,
    issue_id uuid,
    run_id uuid,
    application_id uuid,
    connection_id uuid,
    catalog_entry_id uuid,
    tool_name text NOT NULL,
    arguments_hash text,
    arguments_summary jsonb,
    policy_decision text,
    matched_policy_ids jsonb DEFAULT '[]'::jsonb NOT NULL,
    approval_state text DEFAULT 'not_required'::text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    upstream_request_id text,
    result_hash text,
    result_summary jsonb,
    result_size_bytes integer,
    result_artifact_id uuid,
    error_code text,
    error_message text,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    catalog_version_hash text,
    catalog_schema_hash text,
    provider_type text,
    application_key text,
    upstream_tool_name text,
    risk_level text,
    gateway_id uuid,
    gateway_token_id uuid,
    gateway_public_id text,
    client_subject_type text,
    client_subject_id text,
    client_name text,
    mcp_session_id text,
    correlation_id text,
    policy_explanation jsonb,
    credential_scope_summary jsonb,
    header_policy_summary jsonb
);


--
-- Name: tool_mcp_gateway_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tool_mcp_gateway_tokens (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    gateway_id uuid NOT NULL,
    name text NOT NULL,
    token_hash text NOT NULL,
    expires_at timestamp with time zone,
    last_used_at timestamp with time zone,
    revoked_at timestamp with time zone,
    created_by_agent_id uuid,
    created_by_user_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    token_prefix text DEFAULT ''::text NOT NULL,
    subject_type text DEFAULT 'gateway_client'::text NOT NULL,
    subject_id text,
    client_label text DEFAULT ''::text NOT NULL,
    owner_note text DEFAULT ''::text NOT NULL,
    allowed_actions jsonb DEFAULT '["tools/list", "tools/call"]'::jsonb NOT NULL,
    expiry_override_reason text,
    expiry_override_by_user_id text,
    expiry_override_by_agent_id uuid,
    expiry_override_at timestamp with time zone
);


--
-- Name: tool_mcp_gateways; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tool_mcp_gateways (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    name text NOT NULL,
    slug text NOT NULL,
    description text,
    status text DEFAULT 'active'::text NOT NULL,
    profile_id uuid NOT NULL,
    agent_id uuid,
    project_id uuid,
    issue_id uuid,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_by_agent_id uuid,
    created_by_user_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    gateway_public_id text DEFAULT ('gw_'::text || replace((gen_random_uuid())::text, '-'::text, ''::text)) NOT NULL,
    display_slug text DEFAULT ''::text NOT NULL,
    default_profile_mode text DEFAULT 'gateway_only'::text NOT NULL,
    context_scope_type text DEFAULT 'none'::text NOT NULL,
    context_scope_id text,
    approval_issue_id uuid,
    auth_config jsonb DEFAULT '{"oauth": {"enabled": false, "reservedFor": "v1_5", "authorizationCodePkce": false, "dynamicClientRegistration": false}, "bearer": {"enabled": true, "tokenPrefix": "pcgw", "defaultTtlSeconds": 7776000, "requireFiniteExpiry": true, "longLivedTokenRequiresOverride": true}, "version": 1}'::jsonb NOT NULL,
    header_policy jsonb DEFAULT '{"version": 1, "staticHeaders": [], "responseHeaders": {"forwardSafeCacheHeaders": true, "forwardMcpRequiredHeaders": true}, "callerPassthrough": {"enabled": false, "allowedHeaders": []}, "generatedMetadata": {"enabled": false, "allowedHeaders": []}}'::jsonb NOT NULL,
    metadata_policy jsonb DEFAULT '{"version": 1, "forwardRunId": false, "forwardAgentId": false, "forwardIssueId": false, "forwardCompanyId": false, "forwardGatewayId": false, "forwardProjectId": false, "forwardCorrelationId": true}'::jsonb NOT NULL,
    on_demand_tools_config jsonb DEFAULT '{"enabled": false, "runToolName": "run_tool", "searchToolName": "search_tools"}'::jsonb NOT NULL,
    archived_at timestamp with time zone
);


--
-- Name: tool_oauth_states; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tool_oauth_states (
    state text NOT NULL,
    company_id uuid NOT NULL,
    connection_id uuid NOT NULL,
    code_verifier text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by_actor_type text,
    created_by_actor_id text,
    created_by_session_id text,
    subject_user_id text,
    requested_scopes jsonb,
    return_to text,
    issue_id uuid,
    interaction_id uuid,
    subject_agent_id uuid
);


--
-- Name: tool_policies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tool_policies (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    name text NOT NULL,
    description text,
    policy_type text NOT NULL,
    priority integer DEFAULT 100 NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    selectors jsonb DEFAULT '{}'::jsonb NOT NULL,
    conditions jsonb,
    config jsonb,
    created_by_agent_id uuid,
    created_by_user_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: tool_profile_bindings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tool_profile_bindings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    profile_id uuid NOT NULL,
    target_type text NOT NULL,
    target_id text NOT NULL,
    priority integer DEFAULT 100 NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_by_agent_id uuid,
    created_by_user_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: tool_profile_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tool_profile_entries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    profile_id uuid NOT NULL,
    selector_type text NOT NULL,
    effect text DEFAULT 'include'::text NOT NULL,
    application_id uuid,
    connection_id uuid,
    catalog_entry_id uuid,
    tool_name text,
    risk_level text,
    conditions jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: tool_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tool_profiles (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    profile_key text NOT NULL,
    name text NOT NULL,
    description text,
    status text DEFAULT 'active'::text NOT NULL,
    default_action text DEFAULT 'deny'::text NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    new_tools_reviewed_at timestamp with time zone
);


--
-- Name: tool_rate_limit_counters; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tool_rate_limit_counters (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    policy_id uuid NOT NULL,
    counter_key text NOT NULL,
    scope_type text NOT NULL,
    scope_id text NOT NULL,
    window_kind text NOT NULL,
    window_start_at timestamp with time zone NOT NULL,
    "limit" integer NOT NULL,
    remaining integer NOT NULL,
    reset_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: tool_runtime_metric_counters; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tool_runtime_metric_counters (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    metric text NOT NULL,
    bucket_start_at timestamp with time zone NOT NULL,
    count integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT tool_runtime_metric_counters_count_nonnegative CHECK ((count >= 0))
);


--
-- Name: tool_runtime_slots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tool_runtime_slots (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    connection_id uuid,
    slot_key text NOT NULL,
    status text DEFAULT 'stopped'::text NOT NULL,
    provider_ref text,
    health_status text DEFAULT 'unchecked'::text NOT NULL,
    health_message text,
    last_started_at timestamp with time zone,
    last_used_at timestamp with time zone,
    idle_deadline_at timestamp with time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    application_id uuid,
    project_workspace_id uuid,
    execution_workspace_id uuid,
    issue_id uuid,
    owner_scope_type text DEFAULT 'connection'::text NOT NULL,
    owner_scope_id text,
    runtime_kind text DEFAULT 'local_stdio'::text NOT NULL,
    reuse_key text,
    workspace_scope text,
    credential_scope_hash text,
    provider text,
    process_id integer,
    command_template_key text,
    last_health_check_at timestamp with time zone,
    started_at timestamp with time zone,
    stopped_at timestamp with time zone,
    idle_expires_at timestamp with time zone,
    last_error text
);


--
-- Name: tool_stdio_command_templates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tool_stdio_command_templates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    template_key text NOT NULL,
    name text NOT NULL,
    description text,
    status text DEFAULT 'active'::text NOT NULL,
    command text NOT NULL,
    args jsonb DEFAULT '[]'::jsonb NOT NULL,
    env_keys jsonb DEFAULT '[]'::jsonb NOT NULL,
    tools jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_by_agent_id uuid,
    created_by_user_id text,
    disabled_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: user; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public."user" (
    id text NOT NULL,
    name text NOT NULL,
    email text NOT NULL,
    email_verified boolean DEFAULT false NOT NULL,
    image text,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: user_inbox_agent_policies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_inbox_agent_policies (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    user_id text NOT NULL,
    mode text DEFAULT 'open'::text NOT NULL,
    allowed_agent_ids jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT user_inbox_agent_policies_mode_check CHECK ((mode = ANY (ARRAY['open'::text, 'allowlist'::text, 'disabled'::text])))
);


--
-- Name: user_secret_declarations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_secret_declarations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    user_secret_definition_id uuid NOT NULL,
    target_type text NOT NULL,
    target_id text NOT NULL,
    config_path text NOT NULL,
    env_key text NOT NULL,
    version_selector text DEFAULT 'latest'::text NOT NULL,
    required boolean DEFAULT true NOT NULL,
    allow_missing_override boolean DEFAULT false NOT NULL,
    label text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: user_secret_definitions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_secret_definitions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    key text NOT NULL,
    name text NOT NULL,
    description text,
    status text DEFAULT 'active'::text NOT NULL,
    provider text DEFAULT 'local_encrypted'::text NOT NULL,
    managed_mode text DEFAULT 'paperclip_managed'::text NOT NULL,
    provider_config_id uuid,
    provider_metadata jsonb,
    usage_guidance text,
    created_by_agent_id uuid,
    created_by_user_id text,
    updated_by_agent_id uuid,
    updated_by_user_id text,
    deleted_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: user_sidebar_preferences; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_sidebar_preferences (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id text NOT NULL,
    company_order jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: verification; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.verification (
    id text NOT NULL,
    identifier text NOT NULL,
    value text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: work_assessments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.work_assessments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    issue_id uuid NOT NULL,
    run_id uuid NOT NULL,
    turn_id text,
    contract_id uuid NOT NULL,
    result_id uuid NOT NULL,
    trigger_kind text NOT NULL,
    trigger_ref text,
    trigger_capability text,
    trigger_actor_company_id uuid NOT NULL,
    prior_issue_status text NOT NULL,
    prior_status_version bigint NOT NULL,
    prior_decision_id uuid,
    policy_version text NOT NULL,
    assessment_json jsonb NOT NULL,
    input_digest text NOT NULL,
    supersedes_assessment_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT work_assessments_trigger_actor_company_check CHECK ((trigger_actor_company_id = company_id))
);


--
-- Name: workspace_operations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.workspace_operations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    execution_workspace_id uuid,
    heartbeat_run_id uuid,
    phase text NOT NULL,
    command text,
    cwd text,
    status text DEFAULT 'running'::text NOT NULL,
    exit_code integer,
    log_store text,
    log_ref text,
    log_bytes bigint,
    log_sha256 text,
    log_compressed boolean DEFAULT false NOT NULL,
    stdout_excerpt text,
    stderr_excerpt text,
    metadata jsonb,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    finished_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    issue_id uuid
);


--
-- Name: workspace_runtime_services; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.workspace_runtime_services (
    id uuid NOT NULL,
    company_id uuid NOT NULL,
    project_id uuid,
    project_workspace_id uuid,
    issue_id uuid,
    scope_type text NOT NULL,
    scope_id text,
    service_name text NOT NULL,
    status text NOT NULL,
    lifecycle text NOT NULL,
    reuse_key text,
    command text,
    cwd text,
    port integer,
    url text,
    provider text NOT NULL,
    provider_ref text,
    owner_agent_id uuid,
    started_by_run_id uuid,
    last_used_at timestamp with time zone DEFAULT now() NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    stopped_at timestamp with time zone,
    stop_policy jsonb,
    health_status text DEFAULT 'unknown'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    execution_workspace_id uuid,
    exposure jsonb,
    exposure_handle text,
    backend_url text
);


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
-- Name: __drizzle_migrations id; Type: DEFAULT; Schema: drizzle; Owner: -
--

ALTER TABLE ONLY drizzle.__drizzle_migrations ALTER COLUMN id SET DEFAULT nextval('drizzle.__drizzle_migrations_id_seq'::regclass);


--
-- Name: heartbeat_run_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.heartbeat_run_events ALTER COLUMN id SET DEFAULT nextval('public.heartbeat_run_events_id_seq'::regclass);


--
-- Name: audit_chain seq; Type: DEFAULT; Schema: uplift; Owner: -
--

ALTER TABLE ONLY uplift.audit_chain ALTER COLUMN seq SET DEFAULT nextval('uplift.audit_chain_seq_seq'::regclass);


--
-- Name: execution_events id; Type: DEFAULT; Schema: uplift; Owner: -
--

ALTER TABLE ONLY uplift.execution_events ALTER COLUMN id SET DEFAULT nextval('uplift.execution_events_id_seq'::regclass);


--
-- Name: __drizzle_migrations __drizzle_migrations_pkey; Type: CONSTRAINT; Schema: drizzle; Owner: -
--

ALTER TABLE ONLY drizzle.__drizzle_migrations
    ADD CONSTRAINT __drizzle_migrations_pkey PRIMARY KEY (id);


--
-- Name: account account_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_pkey PRIMARY KEY (id);


--
-- Name: activity_log activity_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_log
    ADD CONSTRAINT activity_log_pkey PRIMARY KEY (id);


--
-- Name: adapter_auth_sessions adapter_auth_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.adapter_auth_sessions
    ADD CONSTRAINT adapter_auth_sessions_pkey PRIMARY KEY (id);


--
-- Name: agent_api_keys agent_api_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_api_keys
    ADD CONSTRAINT agent_api_keys_pkey PRIMARY KEY (id);


--
-- Name: agent_config_revisions agent_config_revisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_config_revisions
    ADD CONSTRAINT agent_config_revisions_pkey PRIMARY KEY (id);


--
-- Name: agent_instruction_heads agent_instruction_heads_identity_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_instruction_heads
    ADD CONSTRAINT agent_instruction_heads_identity_uq UNIQUE (company_id, agent_id, entry_file);


--
-- Name: agent_instruction_revisions agent_instruction_revisions_identity_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_instruction_revisions
    ADD CONSTRAINT agent_instruction_revisions_identity_uq UNIQUE (company_id, agent_id, entry_file, id);


--
-- Name: agent_instruction_revisions agent_instruction_revisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_instruction_revisions
    ADD CONSTRAINT agent_instruction_revisions_pkey PRIMARY KEY (id);


--
-- Name: agent_instruction_working_copies agent_instruction_working_copies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_instruction_working_copies
    ADD CONSTRAINT agent_instruction_working_copies_pkey PRIMARY KEY (run_id);


--
-- Name: agent_memberships agent_memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_memberships
    ADD CONSTRAINT agent_memberships_pkey PRIMARY KEY (id);


--
-- Name: agent_runtime_state agent_runtime_state_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_runtime_state
    ADD CONSTRAINT agent_runtime_state_pkey PRIMARY KEY (agent_id);


--
-- Name: agent_session_goal_actions agent_session_goal_actions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_session_goal_actions
    ADD CONSTRAINT agent_session_goal_actions_pkey PRIMARY KEY (id);


--
-- Name: agent_task_sessions agent_task_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_task_sessions
    ADD CONSTRAINT agent_task_sessions_pkey PRIMARY KEY (id);


--
-- Name: agent_wakeup_requests agent_wakeup_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_wakeup_requests
    ADD CONSTRAINT agent_wakeup_requests_pkey PRIMARY KEY (id);


--
-- Name: agents agents_company_id_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agents
    ADD CONSTRAINT agents_company_id_uq UNIQUE (company_id, id);


--
-- Name: agents agents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agents
    ADD CONSTRAINT agents_pkey PRIMARY KEY (id);


--
-- Name: ai_connection_defaults ai_connection_defaults_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_connection_defaults
    ADD CONSTRAINT ai_connection_defaults_pkey PRIMARY KEY (id);


--
-- Name: ai_connection_pools ai_connection_pools_company_id_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_connection_pools
    ADD CONSTRAINT ai_connection_pools_company_id_uq UNIQUE (company_id, id);


--
-- Name: ai_connection_pools ai_connection_pools_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_connection_pools
    ADD CONSTRAINT ai_connection_pools_pkey PRIMARY KEY (id);


--
-- Name: ai_connection_router_cursors ai_connection_router_cursors_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_connection_router_cursors
    ADD CONSTRAINT ai_connection_router_cursors_pkey PRIMARY KEY (pool_id);


--
-- Name: ai_connection_task_pins ai_connection_task_pins_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_connection_task_pins
    ADD CONSTRAINT ai_connection_task_pins_pkey PRIMARY KEY (id);


--
-- Name: ai_provider_defaults ai_provider_defaults_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_provider_defaults
    ADD CONSTRAINT ai_provider_defaults_pkey PRIMARY KEY (id);


--
-- Name: announcement_dismissals announcement_dismissals_user_id_announcement_id_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.announcement_dismissals
    ADD CONSTRAINT announcement_dismissals_user_id_announcement_id_pk PRIMARY KEY (user_id, announcement_id);


--
-- Name: announcement_publications announcement_publications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.announcement_publications
    ADD CONSTRAINT announcement_publications_pkey PRIMARY KEY (announcement_id);


--
-- Name: approval_comments approval_comments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approval_comments
    ADD CONSTRAINT approval_comments_pkey PRIMARY KEY (id);


--
-- Name: approvals approvals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approvals
    ADD CONSTRAINT approvals_pkey PRIMARY KEY (id);


--
-- Name: assets assets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assets
    ADD CONSTRAINT assets_pkey PRIMARY KEY (id);


--
-- Name: board_api_keys board_api_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.board_api_keys
    ADD CONSTRAINT board_api_keys_pkey PRIMARY KEY (id);


--
-- Name: browser_use_browsers browser_use_browsers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.browser_use_browsers
    ADD CONSTRAINT browser_use_browsers_pkey PRIMARY KEY (id);


--
-- Name: browser_use_runs browser_use_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.browser_use_runs
    ADD CONSTRAINT browser_use_runs_pkey PRIMARY KEY (id);


--
-- Name: browser_use_sessions browser_use_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.browser_use_sessions
    ADD CONSTRAINT browser_use_sessions_pkey PRIMARY KEY (id);


--
-- Name: browser_use_settings browser_use_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.browser_use_settings
    ADD CONSTRAINT browser_use_settings_pkey PRIMARY KEY (grant_id);


--
-- Name: budget_incidents budget_incidents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.budget_incidents
    ADD CONSTRAINT budget_incidents_pkey PRIMARY KEY (id);


--
-- Name: budget_policies budget_policies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.budget_policies
    ADD CONSTRAINT budget_policies_pkey PRIMARY KEY (id);


--
-- Name: built_in_managed_resources built_in_managed_resources_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.built_in_managed_resources
    ADD CONSTRAINT built_in_managed_resources_pkey PRIMARY KEY (id);


--
-- Name: case_attachments case_attachments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_attachments
    ADD CONSTRAINT case_attachments_pkey PRIMARY KEY (id);


--
-- Name: case_documents case_documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_documents
    ADD CONSTRAINT case_documents_pkey PRIMARY KEY (id);


--
-- Name: case_events case_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_events
    ADD CONSTRAINT case_events_pkey PRIMARY KEY (id);


--
-- Name: case_issue_links case_issue_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_issue_links
    ADD CONSTRAINT case_issue_links_pkey PRIMARY KEY (id);


--
-- Name: case_labels case_labels_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_labels
    ADD CONSTRAINT case_labels_pkey PRIMARY KEY (id);


--
-- Name: cases cases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cases
    ADD CONSTRAINT cases_pkey PRIMARY KEY (id);


--
-- Name: chat_actions chat_actions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_actions
    ADD CONSTRAINT chat_actions_pkey PRIMARY KEY (id);


--
-- Name: chat_agent_routes chat_agent_routes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_agent_routes
    ADD CONSTRAINT chat_agent_routes_pkey PRIMARY KEY (id);


--
-- Name: chat_completion_deliveries chat_completion_deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_completion_deliveries
    ADD CONSTRAINT chat_completion_deliveries_pkey PRIMARY KEY (id);


--
-- Name: chat_conversations chat_conversations_company_id_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_conversations
    ADD CONSTRAINT chat_conversations_company_id_uq UNIQUE (company_id, id);


--
-- Name: chat_conversations chat_conversations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_conversations
    ADD CONSTRAINT chat_conversations_pkey PRIMARY KEY (id);


--
-- Name: chat_deliveries chat_deliveries_company_id_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_deliveries
    ADD CONSTRAINT chat_deliveries_company_id_uq UNIQUE (company_id, id);


--
-- Name: chat_deliveries chat_deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_deliveries
    ADD CONSTRAINT chat_deliveries_pkey PRIMARY KEY (id);


--
-- Name: chat_discord_command_owners chat_discord_command_owners_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_discord_command_owners
    ADD CONSTRAINT chat_discord_command_owners_pkey PRIMARY KEY (application_id);


--
-- Name: chat_endpoint_leases chat_endpoint_leases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_endpoint_leases
    ADD CONSTRAINT chat_endpoint_leases_pkey PRIMARY KEY (id);


--
-- Name: chat_endpoint_resources chat_endpoint_resources_company_id_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_endpoint_resources
    ADD CONSTRAINT chat_endpoint_resources_company_id_uq UNIQUE (company_id, id);


--
-- Name: chat_endpoint_resources chat_endpoint_resources_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_endpoint_resources
    ADD CONSTRAINT chat_endpoint_resources_pkey PRIMARY KEY (id);


--
-- Name: chat_endpoints chat_endpoints_company_id_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_endpoints
    ADD CONSTRAINT chat_endpoints_company_id_uq UNIQUE (company_id, id);


--
-- Name: chat_endpoints chat_endpoints_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_endpoints
    ADD CONSTRAINT chat_endpoints_pkey PRIMARY KEY (id);


--
-- Name: chat_external_principals chat_external_principals_company_id_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_external_principals
    ADD CONSTRAINT chat_external_principals_company_id_uq UNIQUE (company_id, id);


--
-- Name: chat_external_principals chat_external_principals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_external_principals
    ADD CONSTRAINT chat_external_principals_pkey PRIMARY KEY (id);


--
-- Name: chat_github_configurations chat_github_configurations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_github_configurations
    ADD CONSTRAINT chat_github_configurations_pkey PRIMARY KEY (endpoint_id);


--
-- Name: chat_github_registrations chat_github_registrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_github_registrations
    ADD CONSTRAINT chat_github_registrations_pkey PRIMARY KEY (id);


--
-- Name: chat_github_reviews chat_github_reviews_company_id_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_github_reviews
    ADD CONSTRAINT chat_github_reviews_company_id_uq UNIQUE (company_id, id);


--
-- Name: chat_github_reviews chat_github_reviews_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_github_reviews
    ADD CONSTRAINT chat_github_reviews_pkey PRIMARY KEY (id);


--
-- Name: chat_identity_links chat_identity_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_identity_links
    ADD CONSTRAINT chat_identity_links_pkey PRIMARY KEY (id);


--
-- Name: chat_message_links chat_message_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_message_links
    ADD CONSTRAINT chat_message_links_pkey PRIMARY KEY (id);


--
-- Name: chat_publications chat_publications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_publications
    ADD CONSTRAINT chat_publications_pkey PRIMARY KEY (id);


--
-- Name: chat_sdk_state chat_sdk_state_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_sdk_state
    ADD CONSTRAINT chat_sdk_state_pkey PRIMARY KEY (id);


--
-- Name: chat_task_handoffs chat_task_handoffs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_task_handoffs
    ADD CONSTRAINT chat_task_handoffs_pkey PRIMARY KEY (task_id);


--
-- Name: chat_teams_file_transfers chat_teams_file_transfers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_teams_file_transfers
    ADD CONSTRAINT chat_teams_file_transfers_pkey PRIMARY KEY (id);


--
-- Name: cli_auth_challenges cli_auth_challenges_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cli_auth_challenges
    ADD CONSTRAINT cli_auth_challenges_pkey PRIMARY KEY (id);


--
-- Name: companies companies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.companies
    ADD CONSTRAINT companies_pkey PRIMARY KEY (id);


--
-- Name: company_logos company_logos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_logos
    ADD CONSTRAINT company_logos_pkey PRIMARY KEY (id);


--
-- Name: company_memberships company_memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_memberships
    ADD CONSTRAINT company_memberships_pkey PRIMARY KEY (id);


--
-- Name: company_onboarding_seeds company_onboarding_seeds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_onboarding_seeds
    ADD CONSTRAINT company_onboarding_seeds_pkey PRIMARY KEY (id);


--
-- Name: company_secret_bindings company_secret_bindings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_secret_bindings
    ADD CONSTRAINT company_secret_bindings_pkey PRIMARY KEY (id);


--
-- Name: company_secret_proposals company_secret_proposals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_secret_proposals
    ADD CONSTRAINT company_secret_proposals_pkey PRIMARY KEY (id);


--
-- Name: company_secret_provider_configs company_secret_provider_configs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_secret_provider_configs
    ADD CONSTRAINT company_secret_provider_configs_pkey PRIMARY KEY (id);


--
-- Name: company_secret_versions company_secret_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_secret_versions
    ADD CONSTRAINT company_secret_versions_pkey PRIMARY KEY (id);


--
-- Name: company_secrets company_secrets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_secrets
    ADD CONSTRAINT company_secrets_pkey PRIMARY KEY (id);


--
-- Name: company_skill_comments company_skill_comments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_comments
    ADD CONSTRAINT company_skill_comments_pkey PRIMARY KEY (id);


--
-- Name: company_skill_policies company_skill_policies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_policies
    ADD CONSTRAINT company_skill_policies_pkey PRIMARY KEY (company_id);


--
-- Name: company_skill_source_entries company_skill_source_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_source_entries
    ADD CONSTRAINT company_skill_source_entries_pkey PRIMARY KEY (id);


--
-- Name: company_skill_sources company_skill_sources_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_sources
    ADD CONSTRAINT company_skill_sources_pkey PRIMARY KEY (id);


--
-- Name: company_skill_stars company_skill_stars_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_stars
    ADD CONSTRAINT company_skill_stars_pkey PRIMARY KEY (id);


--
-- Name: company_skill_test_inputs company_skill_test_inputs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_test_inputs
    ADD CONSTRAINT company_skill_test_inputs_pkey PRIMARY KEY (id);


--
-- Name: company_skill_test_run_templates company_skill_test_run_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_test_run_templates
    ADD CONSTRAINT company_skill_test_run_templates_pkey PRIMARY KEY (id);


--
-- Name: company_skill_test_runs company_skill_test_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_test_runs
    ADD CONSTRAINT company_skill_test_runs_pkey PRIMARY KEY (id);


--
-- Name: company_skill_versions company_skill_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_versions
    ADD CONSTRAINT company_skill_versions_pkey PRIMARY KEY (id);


--
-- Name: company_skills company_skills_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skills
    ADD CONSTRAINT company_skills_pkey PRIMARY KEY (id);


--
-- Name: company_transfer_runs company_transfer_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_transfer_runs
    ADD CONSTRAINT company_transfer_runs_pkey PRIMARY KEY (id);


--
-- Name: company_user_sidebar_preferences company_user_sidebar_preferences_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_user_sidebar_preferences
    ADD CONSTRAINT company_user_sidebar_preferences_pkey PRIMARY KEY (id);


--
-- Name: completion_contracts completion_contracts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.completion_contracts
    ADD CONSTRAINT completion_contracts_pkey PRIMARY KEY (id);


--
-- Name: connection_event_deliveries connection_event_deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.connection_event_deliveries
    ADD CONSTRAINT connection_event_deliveries_pkey PRIMARY KEY (id);


--
-- Name: connection_grant_delegations connection_grant_delegations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.connection_grant_delegations
    ADD CONSTRAINT connection_grant_delegations_pkey PRIMARY KEY (id);


--
-- Name: connection_grant_members connection_grant_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.connection_grant_members
    ADD CONSTRAINT connection_grant_members_pkey PRIMARY KEY (id);


--
-- Name: connection_grants connection_grants_company_id_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.connection_grants
    ADD CONSTRAINT connection_grants_company_id_uq UNIQUE (company_id, id);


--
-- Name: connection_grants connection_grants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.connection_grants
    ADD CONSTRAINT connection_grants_pkey PRIMARY KEY (id);


--
-- Name: connection_intent_deliveries connection_intent_deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.connection_intent_deliveries
    ADD CONSTRAINT connection_intent_deliveries_pkey PRIMARY KEY (interaction_id);


--
-- Name: connection_token_issuances connection_token_issuances_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.connection_token_issuances
    ADD CONSTRAINT connection_token_issuances_pkey PRIMARY KEY (id);


--
-- Name: cost_events cost_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cost_events
    ADD CONSTRAINT cost_events_pkey PRIMARY KEY (id);


--
-- Name: decision_archive_notification_outbox decision_archive_notification_outbox_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_archive_notification_outbox
    ADD CONSTRAINT decision_archive_notification_outbox_pkey PRIMARY KEY (id);


--
-- Name: decision_bundles decision_bundles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_bundles
    ADD CONSTRAINT decision_bundles_pkey PRIMARY KEY (id);


--
-- Name: decision_effect_executions decision_effect_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_effect_executions
    ADD CONSTRAINT decision_effect_executions_pkey PRIMARY KEY (id);


--
-- Name: decision_queue_items decision_queue_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_queue_items
    ADD CONSTRAINT decision_queue_items_pkey PRIMARY KEY (id);


--
-- Name: decision_queues decision_queues_id_company_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_queues
    ADD CONSTRAINT decision_queues_id_company_uq UNIQUE (id, company_id);


--
-- Name: decision_queues decision_queues_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_queues
    ADD CONSTRAINT decision_queues_pkey PRIMARY KEY (id);


--
-- Name: decision_retention decision_retention_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_retention
    ADD CONSTRAINT decision_retention_pkey PRIMARY KEY (id);


--
-- Name: decision_target_issues decision_target_issues_decision_id_issue_id_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_target_issues
    ADD CONSTRAINT decision_target_issues_decision_id_issue_id_pk PRIMARY KEY (decision_id, issue_id);


--
-- Name: decision_training_examples decision_training_examples_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_training_examples
    ADD CONSTRAINT decision_training_examples_pkey PRIMARY KEY (id);


--
-- Name: decision_triage_events decision_triage_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_triage_events
    ADD CONSTRAINT decision_triage_events_pkey PRIMARY KEY (id);


--
-- Name: decision_triage decision_triage_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_triage
    ADD CONSTRAINT decision_triage_pkey PRIMARY KEY (id);


--
-- Name: decisions decisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decisions
    ADD CONSTRAINT decisions_pkey PRIMARY KEY (id);


--
-- Name: document_annotation_anchor_snapshots document_annotation_anchor_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_annotation_anchor_snapshots
    ADD CONSTRAINT document_annotation_anchor_snapshots_pkey PRIMARY KEY (id);


--
-- Name: document_annotation_comments document_annotation_comments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_annotation_comments
    ADD CONSTRAINT document_annotation_comments_pkey PRIMARY KEY (id);


--
-- Name: document_annotation_threads document_annotation_threads_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_annotation_threads
    ADD CONSTRAINT document_annotation_threads_pkey PRIMARY KEY (id);


--
-- Name: document_memberships document_memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_memberships
    ADD CONSTRAINT document_memberships_pkey PRIMARY KEY (id);


--
-- Name: document_revisions document_revisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_revisions
    ADD CONSTRAINT document_revisions_pkey PRIMARY KEY (id);


--
-- Name: documents documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_pkey PRIMARY KEY (id);


--
-- Name: email_endpoints email_endpoints_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_endpoints
    ADD CONSTRAINT email_endpoints_pkey PRIMARY KEY (endpoint_id);


--
-- Name: email_messages email_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_messages
    ADD CONSTRAINT email_messages_pkey PRIMARY KEY (id);


--
-- Name: email_sends email_sends_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_sends
    ADD CONSTRAINT email_sends_pkey PRIMARY KEY (publication_id);


--
-- Name: environment_custom_image_setup_sessions environment_custom_image_setup_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.environment_custom_image_setup_sessions
    ADD CONSTRAINT environment_custom_image_setup_sessions_pkey PRIMARY KEY (id);


--
-- Name: environment_custom_image_templates environment_custom_image_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.environment_custom_image_templates
    ADD CONSTRAINT environment_custom_image_templates_pkey PRIMARY KEY (id);


--
-- Name: environment_leases environment_leases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.environment_leases
    ADD CONSTRAINT environment_leases_pkey PRIMARY KEY (id);


--
-- Name: environments environments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.environments
    ADD CONSTRAINT environments_pkey PRIMARY KEY (id);


--
-- Name: execution_workspace_runtime_leases execution_workspace_runtime_leases_execution_workspace_id_uniqu; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_workspace_runtime_leases
    ADD CONSTRAINT execution_workspace_runtime_leases_execution_workspace_id_uniqu UNIQUE (execution_workspace_id);


--
-- Name: execution_workspace_runtime_leases execution_workspace_runtime_leases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_workspace_runtime_leases
    ADD CONSTRAINT execution_workspace_runtime_leases_pkey PRIMARY KEY (id);


--
-- Name: execution_workspaces execution_workspaces_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_workspaces
    ADD CONSTRAINT execution_workspaces_pkey PRIMARY KEY (id);


--
-- Name: external_object_mentions external_object_mentions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.external_object_mentions
    ADD CONSTRAINT external_object_mentions_pkey PRIMARY KEY (id);


--
-- Name: external_objects external_objects_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.external_objects
    ADD CONSTRAINT external_objects_pkey PRIMARY KEY (id);


--
-- Name: feedback_exports feedback_exports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.feedback_exports
    ADD CONSTRAINT feedback_exports_pkey PRIMARY KEY (id);


--
-- Name: feedback_votes feedback_votes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.feedback_votes
    ADD CONSTRAINT feedback_votes_pkey PRIMARY KEY (id);


--
-- Name: finance_events finance_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finance_events
    ADD CONSTRAINT finance_events_pkey PRIMARY KEY (id);


--
-- Name: folders folders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.folders
    ADD CONSTRAINT folders_pkey PRIMARY KEY (id);


--
-- Name: goals goals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goals
    ADD CONSTRAINT goals_pkey PRIMARY KEY (id);


--
-- Name: heartbeat_run_events heartbeat_run_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.heartbeat_run_events
    ADD CONSTRAINT heartbeat_run_events_pkey PRIMARY KEY (id);


--
-- Name: heartbeat_run_watchdog_decisions heartbeat_run_watchdog_decisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.heartbeat_run_watchdog_decisions
    ADD CONSTRAINT heartbeat_run_watchdog_decisions_pkey PRIMARY KEY (id);


--
-- Name: heartbeat_runs heartbeat_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.heartbeat_runs
    ADD CONSTRAINT heartbeat_runs_pkey PRIMARY KEY (id);


--
-- Name: inbox_dismissals inbox_dismissals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inbox_dismissals
    ADD CONSTRAINT inbox_dismissals_pkey PRIMARY KEY (id);


--
-- Name: instance_settings instance_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.instance_settings
    ADD CONSTRAINT instance_settings_pkey PRIMARY KEY (id);


--
-- Name: instance_user_roles instance_user_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.instance_user_roles
    ADD CONSTRAINT instance_user_roles_pkey PRIMARY KEY (id);


--
-- Name: invites invites_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invites
    ADD CONSTRAINT invites_pkey PRIMARY KEY (id);


--
-- Name: issue_approvals issue_approvals_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_approvals
    ADD CONSTRAINT issue_approvals_pk PRIMARY KEY (issue_id, approval_id);


--
-- Name: issue_attachments issue_attachments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_attachments
    ADD CONSTRAINT issue_attachments_pkey PRIMARY KEY (id);


--
-- Name: issue_comments issue_comments_client_request_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_comments
    ADD CONSTRAINT issue_comments_client_request_uq UNIQUE (issue_id, author_user_id, client_request_id);


--
-- Name: issue_comments issue_comments_company_id_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_comments
    ADD CONSTRAINT issue_comments_company_id_uq UNIQUE (company_id, id);


--
-- Name: issue_comments issue_comments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_comments
    ADD CONSTRAINT issue_comments_pkey PRIMARY KEY (id);


--
-- Name: issue_create_idempotency_keys issue_create_idempotency_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_create_idempotency_keys
    ADD CONSTRAINT issue_create_idempotency_keys_pkey PRIMARY KEY (id);


--
-- Name: issue_documents issue_documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_documents
    ADD CONSTRAINT issue_documents_pkey PRIMARY KEY (id);


--
-- Name: issue_execution_decisions issue_execution_decisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_execution_decisions
    ADD CONSTRAINT issue_execution_decisions_pkey PRIMARY KEY (id);


--
-- Name: issue_inbox_archives issue_inbox_archives_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_inbox_archives
    ADD CONSTRAINT issue_inbox_archives_pkey PRIMARY KEY (id);


--
-- Name: issue_labels issue_labels_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_labels
    ADD CONSTRAINT issue_labels_pk PRIMARY KEY (issue_id, label_id);


--
-- Name: issue_plan_decompositions issue_plan_decompositions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_plan_decompositions
    ADD CONSTRAINT issue_plan_decompositions_pkey PRIMARY KEY (id);


--
-- Name: issue_question_response_deliveries issue_question_response_deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_question_response_deliveries
    ADD CONSTRAINT issue_question_response_deliveries_pkey PRIMARY KEY (id);


--
-- Name: issue_read_states issue_read_states_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_read_states
    ADD CONSTRAINT issue_read_states_pkey PRIMARY KEY (id);


--
-- Name: issue_recovery_actions issue_recovery_actions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_recovery_actions
    ADD CONSTRAINT issue_recovery_actions_pkey PRIMARY KEY (id);


--
-- Name: issue_reference_mentions issue_reference_mentions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_reference_mentions
    ADD CONSTRAINT issue_reference_mentions_pkey PRIMARY KEY (id);


--
-- Name: issue_relations issue_relations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_relations
    ADD CONSTRAINT issue_relations_pkey PRIMARY KEY (id);


--
-- Name: issue_thread_interactions issue_thread_interactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_thread_interactions
    ADD CONSTRAINT issue_thread_interactions_pkey PRIMARY KEY (id);


--
-- Name: issue_tree_hold_members issue_tree_hold_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_tree_hold_members
    ADD CONSTRAINT issue_tree_hold_members_pkey PRIMARY KEY (id);


--
-- Name: issue_tree_holds issue_tree_holds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_tree_holds
    ADD CONSTRAINT issue_tree_holds_pkey PRIMARY KEY (id);


--
-- Name: issue_watchdogs issue_watchdogs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_watchdogs
    ADD CONSTRAINT issue_watchdogs_pkey PRIMARY KEY (id);


--
-- Name: issue_work_products issue_work_products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_work_products
    ADD CONSTRAINT issue_work_products_pkey PRIMARY KEY (id);


--
-- Name: issues issues_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issues
    ADD CONSTRAINT issues_pkey PRIMARY KEY (id);


--
-- Name: join_requests join_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.join_requests
    ADD CONSTRAINT join_requests_pkey PRIMARY KEY (id);


--
-- Name: labels labels_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.labels
    ADD CONSTRAINT labels_pkey PRIMARY KEY (id);


--
-- Name: managed_agent_profiles managed_agent_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.managed_agent_profiles
    ADD CONSTRAINT managed_agent_profiles_pkey PRIMARY KEY (id);


--
-- Name: native_run_finalizations native_run_finalizations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.native_run_finalizations
    ADD CONSTRAINT native_run_finalizations_pkey PRIMARY KEY (run_id);


--
-- Name: native_run_results native_run_results_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.native_run_results
    ADD CONSTRAINT native_run_results_pkey PRIMARY KEY (id);


--
-- Name: pipeline_automation_executions pipeline_automation_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_automation_executions
    ADD CONSTRAINT pipeline_automation_executions_pkey PRIMARY KEY (id);


--
-- Name: pipeline_case_blockers pipeline_case_blockers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_case_blockers
    ADD CONSTRAINT pipeline_case_blockers_pkey PRIMARY KEY (id);


--
-- Name: pipeline_case_documents pipeline_case_documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_case_documents
    ADD CONSTRAINT pipeline_case_documents_pkey PRIMARY KEY (id);


--
-- Name: pipeline_case_events pipeline_case_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_case_events
    ADD CONSTRAINT pipeline_case_events_pkey PRIMARY KEY (id);


--
-- Name: pipeline_case_issue_links pipeline_case_issue_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_case_issue_links
    ADD CONSTRAINT pipeline_case_issue_links_pkey PRIMARY KEY (id);


--
-- Name: pipeline_cases pipeline_cases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_cases
    ADD CONSTRAINT pipeline_cases_pkey PRIMARY KEY (id);


--
-- Name: pipeline_documents pipeline_documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_documents
    ADD CONSTRAINT pipeline_documents_pkey PRIMARY KEY (id);


--
-- Name: pipeline_stages pipeline_stages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_stages
    ADD CONSTRAINT pipeline_stages_pkey PRIMARY KEY (id);


--
-- Name: pipeline_transitions pipeline_transitions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_transitions
    ADD CONSTRAINT pipeline_transitions_pkey PRIMARY KEY (id);


--
-- Name: pipelines pipelines_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipelines
    ADD CONSTRAINT pipelines_pkey PRIMARY KEY (id);


--
-- Name: plugin_company_settings plugin_company_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugin_company_settings
    ADD CONSTRAINT plugin_company_settings_pkey PRIMARY KEY (id);


--
-- Name: plugin_config plugin_config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugin_config
    ADD CONSTRAINT plugin_config_pkey PRIMARY KEY (id);


--
-- Name: plugin_database_namespaces plugin_database_namespaces_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugin_database_namespaces
    ADD CONSTRAINT plugin_database_namespaces_pkey PRIMARY KEY (id);


--
-- Name: plugin_entities plugin_entities_external_idx; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugin_entities
    ADD CONSTRAINT plugin_entities_external_idx UNIQUE NULLS NOT DISTINCT (company_id, plugin_id, entity_type, external_id);


--
-- Name: plugin_entities plugin_entities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugin_entities
    ADD CONSTRAINT plugin_entities_pkey PRIMARY KEY (id);


--
-- Name: plugin_job_runs plugin_job_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugin_job_runs
    ADD CONSTRAINT plugin_job_runs_pkey PRIMARY KEY (id);


--
-- Name: plugin_jobs plugin_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugin_jobs
    ADD CONSTRAINT plugin_jobs_pkey PRIMARY KEY (id);


--
-- Name: plugin_logs plugin_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugin_logs
    ADD CONSTRAINT plugin_logs_pkey PRIMARY KEY (id);


--
-- Name: plugin_managed_resources plugin_managed_resources_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugin_managed_resources
    ADD CONSTRAINT plugin_managed_resources_pkey PRIMARY KEY (id);


--
-- Name: plugin_migrations plugin_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugin_migrations
    ADD CONSTRAINT plugin_migrations_pkey PRIMARY KEY (id);


--
-- Name: plugin_state plugin_state_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugin_state
    ADD CONSTRAINT plugin_state_pkey PRIMARY KEY (id);


--
-- Name: plugin_state plugin_state_unique_entry_idx; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugin_state
    ADD CONSTRAINT plugin_state_unique_entry_idx UNIQUE (plugin_id, scope_kind, scope_id, namespace, state_key);


--
-- Name: plugin_webhook_deliveries plugin_webhook_deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugin_webhook_deliveries
    ADD CONSTRAINT plugin_webhook_deliveries_pkey PRIMARY KEY (id);


--
-- Name: plugins plugins_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugins
    ADD CONSTRAINT plugins_pkey PRIMARY KEY (id);


--
-- Name: principal_permission_grants principal_permission_grants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.principal_permission_grants
    ADD CONSTRAINT principal_permission_grants_pkey PRIMARY KEY (id);


--
-- Name: project_goals project_goals_project_id_goal_id_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_goals
    ADD CONSTRAINT project_goals_project_id_goal_id_pk PRIMARY KEY (project_id, goal_id);


--
-- Name: project_memberships project_memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_memberships
    ADD CONSTRAINT project_memberships_pkey PRIMARY KEY (id);


--
-- Name: project_workspaces project_workspaces_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_workspaces
    ADD CONSTRAINT project_workspaces_pkey PRIMARY KEY (id);


--
-- Name: projects projects_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT projects_pkey PRIMARY KEY (id);


--
-- Name: provider_trace_records provider_trace_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_trace_records
    ADD CONSTRAINT provider_trace_records_pkey PRIMARY KEY (id);


--
-- Name: remote_agent_profiles remote_agent_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.remote_agent_profiles
    ADD CONSTRAINT remote_agent_profiles_pkey PRIMARY KEY (id);


--
-- Name: resource_lifecycle_events resource_lifecycle_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_lifecycle_events
    ADD CONSTRAINT resource_lifecycle_events_pkey PRIMARY KEY (id);


--
-- Name: routine_documents routine_documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routine_documents
    ADD CONSTRAINT routine_documents_pkey PRIMARY KEY (id);


--
-- Name: routine_revisions routine_revisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routine_revisions
    ADD CONSTRAINT routine_revisions_pkey PRIMARY KEY (id);


--
-- Name: routine_runs routine_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routine_runs
    ADD CONSTRAINT routine_runs_pkey PRIMARY KEY (id);


--
-- Name: routine_triggers routine_triggers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routine_triggers
    ADD CONSTRAINT routine_triggers_pkey PRIMARY KEY (id);


--
-- Name: routine_webhook_test_receipts routine_webhook_test_receipts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routine_webhook_test_receipts
    ADD CONSTRAINT routine_webhook_test_receipts_pkey PRIMARY KEY (id);


--
-- Name: routines routines_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routines
    ADD CONSTRAINT routines_pkey PRIMARY KEY (id);


--
-- Name: run_identity_contexts run_identity_contexts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.run_identity_contexts
    ADD CONSTRAINT run_identity_contexts_pkey PRIMARY KEY (id);


--
-- Name: runner_api_response_reservations runner_api_response_reservations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.runner_api_response_reservations
    ADD CONSTRAINT runner_api_response_reservations_pkey PRIMARY KEY (id);


--
-- Name: secret_access_events secret_access_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_access_events
    ADD CONSTRAINT secret_access_events_pkey PRIMARY KEY (id);


--
-- Name: session session_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.session
    ADD CONSTRAINT session_pkey PRIMARY KEY (id);


--
-- Name: smoke_run_steps smoke_run_steps_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.smoke_run_steps
    ADD CONSTRAINT smoke_run_steps_pkey PRIMARY KEY (id);


--
-- Name: smoke_runs smoke_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.smoke_runs
    ADD CONSTRAINT smoke_runs_pkey PRIMARY KEY (id);


--
-- Name: status_card_updates status_card_updates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.status_card_updates
    ADD CONSTRAINT status_card_updates_pkey PRIMARY KEY (id);


--
-- Name: status_cards status_cards_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.status_cards
    ADD CONSTRAINT status_cards_pkey PRIMARY KEY (id);


--
-- Name: status_decision_effects status_decision_effects_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.status_decision_effects
    ADD CONSTRAINT status_decision_effects_pkey PRIMARY KEY (id);


--
-- Name: status_decisions status_decisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.status_decisions
    ADD CONSTRAINT status_decisions_pkey PRIMARY KEY (id);


--
-- Name: summary_slots summary_slots_company_scope_slot_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.summary_slots
    ADD CONSTRAINT summary_slots_company_scope_slot_uq UNIQUE NULLS NOT DISTINCT (company_id, scope_kind, scope_id, slot_key);


--
-- Name: summary_slots summary_slots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.summary_slots
    ADD CONSTRAINT summary_slots_pkey PRIMARY KEY (id);


--
-- Name: tool_access_audit_events tool_access_audit_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_access_audit_events
    ADD CONSTRAINT tool_access_audit_events_pkey PRIMARY KEY (id);


--
-- Name: tool_action_deliveries tool_action_deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_action_deliveries
    ADD CONSTRAINT tool_action_deliveries_pkey PRIMARY KEY (action_request_id);


--
-- Name: tool_action_requests tool_action_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_action_requests
    ADD CONSTRAINT tool_action_requests_pkey PRIMARY KEY (id);


--
-- Name: tool_applications tool_applications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_applications
    ADD CONSTRAINT tool_applications_pkey PRIMARY KEY (id);


--
-- Name: tool_call_events tool_call_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_call_events
    ADD CONSTRAINT tool_call_events_pkey PRIMARY KEY (id);


--
-- Name: tool_catalog_entries tool_catalog_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_catalog_entries
    ADD CONSTRAINT tool_catalog_entries_pkey PRIMARY KEY (id);


--
-- Name: tool_connection_app_snapshots tool_connection_app_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_connection_app_snapshots
    ADD CONSTRAINT tool_connection_app_snapshots_pkey PRIMARY KEY (id);


--
-- Name: tool_connection_app_syncs tool_connection_app_syncs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_connection_app_syncs
    ADD CONSTRAINT tool_connection_app_syncs_pkey PRIMARY KEY (id);


--
-- Name: tool_connection_installs tool_connection_installs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_connection_installs
    ADD CONSTRAINT tool_connection_installs_pkey PRIMARY KEY (id);


--
-- Name: tool_connections tool_connections_company_id_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_connections
    ADD CONSTRAINT tool_connections_company_id_uq UNIQUE (company_id, id);


--
-- Name: tool_connections tool_connections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_connections
    ADD CONSTRAINT tool_connections_pkey PRIMARY KEY (id);


--
-- Name: tool_gateway_rate_limit_counters tool_gateway_rate_limit_counters_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_gateway_rate_limit_counters
    ADD CONSTRAINT tool_gateway_rate_limit_counters_pkey PRIMARY KEY (id);


--
-- Name: tool_gateway_sessions tool_gateway_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_gateway_sessions
    ADD CONSTRAINT tool_gateway_sessions_pkey PRIMARY KEY (id);


--
-- Name: tool_invocations tool_invocations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_invocations
    ADD CONSTRAINT tool_invocations_pkey PRIMARY KEY (id);


--
-- Name: tool_mcp_gateway_tokens tool_mcp_gateway_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_mcp_gateway_tokens
    ADD CONSTRAINT tool_mcp_gateway_tokens_pkey PRIMARY KEY (id);


--
-- Name: tool_mcp_gateways tool_mcp_gateways_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_mcp_gateways
    ADD CONSTRAINT tool_mcp_gateways_pkey PRIMARY KEY (id);


--
-- Name: tool_oauth_states tool_oauth_states_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_oauth_states
    ADD CONSTRAINT tool_oauth_states_pkey PRIMARY KEY (state);


--
-- Name: tool_policies tool_policies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_policies
    ADD CONSTRAINT tool_policies_pkey PRIMARY KEY (id);


--
-- Name: tool_profile_bindings tool_profile_bindings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_profile_bindings
    ADD CONSTRAINT tool_profile_bindings_pkey PRIMARY KEY (id);


--
-- Name: tool_profile_entries tool_profile_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_profile_entries
    ADD CONSTRAINT tool_profile_entries_pkey PRIMARY KEY (id);


--
-- Name: tool_profiles tool_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_profiles
    ADD CONSTRAINT tool_profiles_pkey PRIMARY KEY (id);


--
-- Name: tool_rate_limit_counters tool_rate_limit_counters_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_rate_limit_counters
    ADD CONSTRAINT tool_rate_limit_counters_pkey PRIMARY KEY (id);


--
-- Name: tool_runtime_metric_counters tool_runtime_metric_counters_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_runtime_metric_counters
    ADD CONSTRAINT tool_runtime_metric_counters_pkey PRIMARY KEY (id);


--
-- Name: tool_runtime_slots tool_runtime_slots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_runtime_slots
    ADD CONSTRAINT tool_runtime_slots_pkey PRIMARY KEY (id);


--
-- Name: tool_stdio_command_templates tool_stdio_command_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_stdio_command_templates
    ADD CONSTRAINT tool_stdio_command_templates_pkey PRIMARY KEY (id);


--
-- Name: user_inbox_agent_policies user_inbox_agent_policies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_inbox_agent_policies
    ADD CONSTRAINT user_inbox_agent_policies_pkey PRIMARY KEY (id);


--
-- Name: user user_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."user"
    ADD CONSTRAINT user_pkey PRIMARY KEY (id);


--
-- Name: user_secret_declarations user_secret_declarations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_secret_declarations
    ADD CONSTRAINT user_secret_declarations_pkey PRIMARY KEY (id);


--
-- Name: user_secret_definitions user_secret_definitions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_secret_definitions
    ADD CONSTRAINT user_secret_definitions_pkey PRIMARY KEY (id);


--
-- Name: user_sidebar_preferences user_sidebar_preferences_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_sidebar_preferences
    ADD CONSTRAINT user_sidebar_preferences_pkey PRIMARY KEY (id);


--
-- Name: verification verification_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.verification
    ADD CONSTRAINT verification_pkey PRIMARY KEY (id);


--
-- Name: work_assessments work_assessments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_assessments
    ADD CONSTRAINT work_assessments_pkey PRIMARY KEY (id);


--
-- Name: workspace_operations workspace_operations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_operations
    ADD CONSTRAINT workspace_operations_pkey PRIMARY KEY (id);


--
-- Name: workspace_runtime_services workspace_runtime_services_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_runtime_services
    ADD CONSTRAINT workspace_runtime_services_pkey PRIMARY KEY (id);


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
-- Name: account_issuer_account_id_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX account_issuer_account_id_uq ON public.account USING btree (issuer, account_id);


--
-- Name: activity_log_company_agent_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activity_log_company_agent_created_idx ON public.activity_log USING btree (company_id, agent_id, created_at);


--
-- Name: activity_log_company_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activity_log_company_created_idx ON public.activity_log USING btree (company_id, created_at);


--
-- Name: activity_log_company_responsible_user_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activity_log_company_responsible_user_created_idx ON public.activity_log USING btree (company_id, responsible_user_id, created_at);


--
-- Name: activity_log_entity_type_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activity_log_entity_type_id_idx ON public.activity_log USING btree (entity_type, entity_id);


--
-- Name: activity_log_run_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activity_log_run_id_idx ON public.activity_log USING btree (run_id);


--
-- Name: adapter_auth_sessions_company_owner_adapter_active_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX adapter_auth_sessions_company_owner_adapter_active_uq ON public.adapter_auth_sessions USING btree (company_id, started_by_user_id, adapter_type) WHERE (status = ANY (ARRAY['starting'::text, 'waiting_for_user'::text, 'promoting'::text, 'awaiting_code'::text, 'submitting'::text]));


--
-- Name: adapter_auth_sessions_company_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX adapter_auth_sessions_company_status_idx ON public.adapter_auth_sessions USING btree (company_id, status);


--
-- Name: adapter_auth_sessions_environment_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX adapter_auth_sessions_environment_idx ON public.adapter_auth_sessions USING btree (environment_id);


--
-- Name: adapter_auth_sessions_expires_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX adapter_auth_sessions_expires_idx ON public.adapter_auth_sessions USING btree (expires_at);


--
-- Name: adapter_auth_sessions_provider_lease_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX adapter_auth_sessions_provider_lease_idx ON public.adapter_auth_sessions USING btree (provider_lease_id);


--
-- Name: adapter_auth_sessions_public_session_id_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX adapter_auth_sessions_public_session_id_uq ON public.adapter_auth_sessions USING btree (public_session_id);


--
-- Name: agent_api_keys_company_agent_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_api_keys_company_agent_idx ON public.agent_api_keys USING btree (company_id, agent_id);


--
-- Name: agent_api_keys_key_hash_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_api_keys_key_hash_idx ON public.agent_api_keys USING btree (key_hash);


--
-- Name: agent_config_revisions_agent_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_config_revisions_agent_created_idx ON public.agent_config_revisions USING btree (agent_id, created_at);


--
-- Name: agent_config_revisions_company_agent_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_config_revisions_company_agent_created_idx ON public.agent_config_revisions USING btree (company_id, agent_id, created_at);


--
-- Name: agent_instruction_copies_agent_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_instruction_copies_agent_idx ON public.agent_instruction_working_copies USING btree (company_id, agent_id, created_at);


--
-- Name: agent_instruction_copies_pending_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_instruction_copies_pending_idx ON public.agent_instruction_working_copies USING btree (state, next_attempt_at);


--
-- Name: agent_instruction_revisions_history_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_instruction_revisions_history_idx ON public.agent_instruction_revisions USING btree (company_id, agent_id, entry_file, created_at, id);


--
-- Name: agent_memberships_agent_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_memberships_agent_idx ON public.agent_memberships USING btree (agent_id);


--
-- Name: agent_memberships_company_user_agent_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX agent_memberships_company_user_agent_uq ON public.agent_memberships USING btree (company_id, user_id, agent_id);


--
-- Name: agent_memberships_company_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_memberships_company_user_idx ON public.agent_memberships USING btree (company_id, user_id);


--
-- Name: agent_memberships_company_user_starred_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_memberships_company_user_starred_idx ON public.agent_memberships USING btree (company_id, user_id, starred_at);


--
-- Name: agent_runtime_state_company_agent_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_runtime_state_company_agent_idx ON public.agent_runtime_state USING btree (company_id, agent_id);


--
-- Name: agent_runtime_state_company_updated_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_runtime_state_company_updated_idx ON public.agent_runtime_state USING btree (company_id, updated_at);


--
-- Name: agent_session_goal_actions_company_status_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_session_goal_actions_company_status_created_idx ON public.agent_session_goal_actions USING btree (company_id, status, created_at);


--
-- Name: agent_session_goal_actions_session_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_session_goal_actions_session_created_idx ON public.agent_session_goal_actions USING btree (session_id, created_at);


--
-- Name: agent_session_goal_actions_session_request_uniq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX agent_session_goal_actions_session_request_uniq ON public.agent_session_goal_actions USING btree (session_id, request_id);


--
-- Name: agent_task_sessions_company_agent_adapter_task_uniq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX agent_task_sessions_company_agent_adapter_task_uniq ON public.agent_task_sessions USING btree (company_id, agent_id, adapter_type, task_key);


--
-- Name: agent_task_sessions_company_agent_updated_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_task_sessions_company_agent_updated_idx ON public.agent_task_sessions USING btree (company_id, agent_id, updated_at);


--
-- Name: agent_task_sessions_company_task_updated_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_task_sessions_company_task_updated_idx ON public.agent_task_sessions USING btree (company_id, task_key, updated_at);


--
-- Name: agent_wakeup_requests_agent_requested_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_wakeup_requests_agent_requested_idx ON public.agent_wakeup_requests USING btree (agent_id, requested_at);


--
-- Name: agent_wakeup_requests_chat_completion_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX agent_wakeup_requests_chat_completion_uq ON public.agent_wakeup_requests USING btree (company_id, idempotency_key) WHERE (idempotency_key ~~ 'chat-completion:%'::text);


--
-- Name: agent_wakeup_requests_company_agent_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_wakeup_requests_company_agent_status_idx ON public.agent_wakeup_requests USING btree (company_id, agent_id, status);


--
-- Name: agent_wakeup_requests_company_idempotency_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_wakeup_requests_company_idempotency_key_idx ON public.agent_wakeup_requests USING btree (company_id, idempotency_key) WHERE (idempotency_key IS NOT NULL);


--
-- Name: agent_wakeup_requests_company_payload_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_wakeup_requests_company_payload_issue_idx ON public.agent_wakeup_requests USING btree (company_id, ((payload ->> 'issueId'::text)));


--
-- Name: agent_wakeup_requests_company_requested_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_wakeup_requests_company_requested_idx ON public.agent_wakeup_requests USING btree (company_id, requested_at);


--
-- Name: agent_wakeup_requests_connection_intent_delivery_idempotency_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX agent_wakeup_requests_connection_intent_delivery_idempotency_uq ON public.agent_wakeup_requests USING btree (company_id, idempotency_key) WHERE ((idempotency_key ~~ 'connection-intent:%'::text) AND (status <> ALL (ARRAY['skipped'::text, 'failed'::text, 'cancelled'::text])));


--
-- Name: agent_wakeup_requests_disposition_repair_idempotency_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX agent_wakeup_requests_disposition_repair_idempotency_uq ON public.agent_wakeup_requests USING btree (company_id, idempotency_key) WHERE ((idempotency_key ~~ 'issue_disposition_repair:%'::text) AND (status <> 'skipped'::text));


--
-- Name: agent_wakeup_requests_question_response_delivery_idempotency_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX agent_wakeup_requests_question_response_delivery_idempotency_uq ON public.agent_wakeup_requests USING btree (company_id, idempotency_key) WHERE (((idempotency_key ~~ 'question-response:%'::text) OR (idempotency_key ~~ 'interaction:%'::text)) AND (status <> ALL (ARRAY['skipped'::text, 'failed'::text, 'cancelled'::text])));


--
-- Name: agent_wakeup_requests_review_path_recovery_idempotency_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX agent_wakeup_requests_review_path_recovery_idempotency_uq ON public.agent_wakeup_requests USING btree (company_id, idempotency_key) WHERE ((idempotency_key ~~ 'issue_review_path_lost:%'::text) AND (status <> 'skipped'::text));


--
-- Name: agent_wakeup_requests_tool_action_delivery_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX agent_wakeup_requests_tool_action_delivery_uq ON public.agent_wakeup_requests USING btree (company_id, idempotency_key) WHERE ((idempotency_key ~~ 'tool-action-response:%'::text) AND (status <> ALL (ARRAY['skipped'::text, 'failed'::text, 'cancelled'::text])));


--
-- Name: agents_company_built_in_agent_key_unique_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX agents_company_built_in_agent_key_unique_idx ON public.agents USING btree (company_id, (((metadata -> 'paperclipBuiltInAgent'::text) ->> 'key'::text))) WHERE ((((metadata -> 'paperclipBuiltInAgent'::text) ->> 'key'::text) IS NOT NULL) AND (status <> 'terminated'::text));


--
-- Name: agents_company_default_environment_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agents_company_default_environment_idx ON public.agents USING btree (company_id, default_environment_id);


--
-- Name: agents_company_reports_to_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agents_company_reports_to_idx ON public.agents USING btree (company_id, reports_to);


--
-- Name: agents_company_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agents_company_status_idx ON public.agents USING btree (company_id, status);


--
-- Name: ai_connection_defaults_owner_method_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ai_connection_defaults_owner_method_uq ON public.ai_connection_defaults USING btree (company_id, user_id, provider, method);


--
-- Name: ai_connection_task_pins_affinity_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ai_connection_task_pins_affinity_uq ON public.ai_connection_task_pins USING btree (company_id, pool_id, agent_id, task_key);


--
-- Name: ai_provider_defaults_owner_provider_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ai_provider_defaults_owner_provider_uq ON public.ai_provider_defaults USING btree (company_id, user_id, provider);


--
-- Name: approval_comments_approval_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX approval_comments_approval_created_idx ON public.approval_comments USING btree (approval_id, created_at);


--
-- Name: approval_comments_approval_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX approval_comments_approval_idx ON public.approval_comments USING btree (approval_id);


--
-- Name: approval_comments_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX approval_comments_company_idx ON public.approval_comments USING btree (company_id);


--
-- Name: approvals_company_status_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX approvals_company_status_type_idx ON public.approvals USING btree (company_id, status, type);


--
-- Name: assets_company_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX assets_company_created_idx ON public.assets USING btree (company_id, created_at);


--
-- Name: assets_company_object_key_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX assets_company_object_key_uq ON public.assets USING btree (company_id, object_key);


--
-- Name: assets_company_provider_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX assets_company_provider_idx ON public.assets USING btree (company_id, provider);


--
-- Name: board_api_keys_key_hash_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX board_api_keys_key_hash_idx ON public.board_api_keys USING btree (key_hash);


--
-- Name: board_api_keys_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX board_api_keys_user_idx ON public.board_api_keys USING btree (user_id);


--
-- Name: browser_use_browsers_provider_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX browser_use_browsers_provider_uq ON public.browser_use_browsers USING btree (provider_browser_id);


--
-- Name: browser_use_browsers_session_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX browser_use_browsers_session_idx ON public.browser_use_browsers USING btree (session_id);


--
-- Name: browser_use_runs_invocation_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX browser_use_runs_invocation_uq ON public.browser_use_runs USING btree (invocation_id);


--
-- Name: browser_use_runs_provider_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX browser_use_runs_provider_uq ON public.browser_use_runs USING btree (provider_run_id);


--
-- Name: browser_use_runs_session_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX browser_use_runs_session_idx ON public.browser_use_runs USING btree (session_id);


--
-- Name: browser_use_sessions_provider_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX browser_use_sessions_provider_uq ON public.browser_use_sessions USING btree (provider_session_id);


--
-- Name: browser_use_sessions_task_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX browser_use_sessions_task_idx ON public.browser_use_sessions USING btree (company_id, issue_id);


--
-- Name: budget_incidents_company_scope_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX budget_incidents_company_scope_idx ON public.budget_incidents USING btree (company_id, scope_type, scope_id, status);


--
-- Name: budget_incidents_company_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX budget_incidents_company_status_idx ON public.budget_incidents USING btree (company_id, status);


--
-- Name: budget_incidents_policy_window_threshold_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX budget_incidents_policy_window_threshold_idx ON public.budget_incidents USING btree (policy_id, window_start, threshold_type) WHERE (status <> 'dismissed'::text);


--
-- Name: budget_policies_company_scope_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX budget_policies_company_scope_active_idx ON public.budget_policies USING btree (company_id, scope_type, scope_id, is_active);


--
-- Name: budget_policies_company_scope_metric_unique_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX budget_policies_company_scope_metric_unique_idx ON public.budget_policies USING btree (company_id, scope_type, scope_id, metric, window_kind);


--
-- Name: budget_policies_company_window_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX budget_policies_company_window_idx ON public.budget_policies USING btree (company_id, window_kind, metric);


--
-- Name: built_in_managed_resources_company_bundle_resource_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX built_in_managed_resources_company_bundle_resource_uq ON public.built_in_managed_resources USING btree (company_id, bundle_key, resource_kind, resource_key);


--
-- Name: built_in_managed_resources_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX built_in_managed_resources_company_idx ON public.built_in_managed_resources USING btree (company_id);


--
-- Name: built_in_managed_resources_resource_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX built_in_managed_resources_resource_idx ON public.built_in_managed_resources USING btree (resource_kind, resource_id);


--
-- Name: case_attachments_asset_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX case_attachments_asset_uq ON public.case_attachments USING btree (asset_id);


--
-- Name: case_attachments_company_case_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX case_attachments_company_case_idx ON public.case_attachments USING btree (company_id, case_id);


--
-- Name: case_documents_company_case_key_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX case_documents_company_case_key_uq ON public.case_documents USING btree (company_id, case_id, key);


--
-- Name: case_documents_company_case_updated_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX case_documents_company_case_updated_idx ON public.case_documents USING btree (company_id, case_id, updated_at);


--
-- Name: case_documents_document_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX case_documents_document_uq ON public.case_documents USING btree (document_id);


--
-- Name: case_events_case_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX case_events_case_created_idx ON public.case_events USING btree (case_id, created_at);


--
-- Name: case_events_company_case_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX case_events_company_case_idx ON public.case_events USING btree (company_id, case_id);


--
-- Name: case_issue_links_case_issue_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX case_issue_links_case_issue_uq ON public.case_issue_links USING btree (case_id, issue_id);


--
-- Name: case_issue_links_company_case_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX case_issue_links_company_case_idx ON public.case_issue_links USING btree (company_id, case_id);


--
-- Name: case_issue_links_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX case_issue_links_issue_idx ON public.case_issue_links USING btree (issue_id);


--
-- Name: case_labels_case_label_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX case_labels_case_label_uq ON public.case_labels USING btree (case_id, label_id);


--
-- Name: case_labels_company_case_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX case_labels_company_case_idx ON public.case_labels USING btree (company_id, case_id);


--
-- Name: case_labels_label_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX case_labels_label_idx ON public.case_labels USING btree (label_id);


--
-- Name: cases_company_case_number_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX cases_company_case_number_uq ON public.cases USING btree (company_id, case_number);


--
-- Name: cases_company_project_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cases_company_project_idx ON public.cases USING btree (company_id, project_id);


--
-- Name: cases_company_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cases_company_status_idx ON public.cases USING btree (company_id, status);


--
-- Name: cases_company_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cases_company_type_idx ON public.cases USING btree (company_id, case_type);


--
-- Name: cases_company_type_key_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX cases_company_type_key_uq ON public.cases USING btree (company_id, case_type, key);


--
-- Name: cases_identifier_search_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cases_identifier_search_idx ON public.cases USING gin (identifier public.gin_trgm_ops);


--
-- Name: cases_identifier_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX cases_identifier_uq ON public.cases USING btree (identifier);


--
-- Name: cases_parent_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cases_parent_idx ON public.cases USING btree (parent_case_id);


--
-- Name: cases_summary_search_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cases_summary_search_idx ON public.cases USING gin (summary public.gin_trgm_ops);


--
-- Name: cases_title_search_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cases_title_search_idx ON public.cases USING gin (title public.gin_trgm_ops);


--
-- Name: chat_actions_provider_action_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chat_actions_provider_action_uq ON public.chat_actions USING btree (endpoint_id, provider_action_id);


--
-- Name: chat_agent_routes_pair_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chat_agent_routes_pair_uq ON public.chat_agent_routes USING btree (source_endpoint_id, destination_endpoint_id);


--
-- Name: chat_completion_deliveries_pending_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_completion_deliveries_pending_idx ON public.chat_completion_deliveries USING btree (status, next_attempt_at);


--
-- Name: chat_completion_deliveries_transition_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chat_completion_deliveries_transition_uq ON public.chat_completion_deliveries USING btree (task_id, status_version);


--
-- Name: chat_conversations_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_conversations_issue_idx ON public.chat_conversations USING btree (company_id, issue_id);


--
-- Name: chat_conversations_thread_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chat_conversations_thread_uq ON public.chat_conversations USING btree (endpoint_id, external_conversation_id, external_thread_id, session_generation);


--
-- Name: chat_deliveries_dedupe_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chat_deliveries_dedupe_uq ON public.chat_deliveries USING btree (endpoint_id, deduplication_key);


--
-- Name: chat_deliveries_event_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chat_deliveries_event_uq ON public.chat_deliveries USING btree (endpoint_id, provider_event_id);


--
-- Name: chat_deliveries_work_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_deliveries_work_idx ON public.chat_deliveries USING btree (state, next_attempt_at);


--
-- Name: chat_endpoint_leases_active_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chat_endpoint_leases_active_uq ON public.chat_endpoint_leases USING btree (endpoint_id, lease_key);


--
-- Name: chat_endpoint_leases_expiry_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_endpoint_leases_expiry_idx ON public.chat_endpoint_leases USING btree (expires_at);


--
-- Name: chat_endpoint_resources_endpoint_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_endpoint_resources_endpoint_idx ON public.chat_endpoint_resources USING btree (company_id, endpoint_id);


--
-- Name: chat_endpoint_resources_external_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chat_endpoint_resources_external_uq ON public.chat_endpoint_resources USING btree (endpoint_id, type, provider_resource_id);


--
-- Name: chat_endpoints_agent_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_endpoints_agent_idx ON public.chat_endpoints USING btree (company_id, assigned_agent_id);


--
-- Name: chat_endpoints_agentmail_inbox_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chat_endpoints_agentmail_inbox_uq ON public.chat_endpoints USING btree (bot_external_id) WHERE ((provider = 'agentmail'::text) AND (status <> 'archived'::text) AND (bot_external_id IS NOT NULL));


--
-- Name: chat_endpoints_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_endpoints_company_idx ON public.chat_endpoints USING btree (company_id);


--
-- Name: chat_endpoints_connection_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chat_endpoints_connection_uq ON public.chat_endpoints USING btree (connection_id);


--
-- Name: chat_endpoints_live_bot_external_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chat_endpoints_live_bot_external_uq ON public.chat_endpoints USING btree (provider, provider_account_id, bot_external_id) WHERE ((status = ANY (ARRAY['verifying'::text, 'active'::text, 'paused'::text, 'attention'::text])) AND (provider_account_id IS NOT NULL) AND (bot_external_id IS NOT NULL));


--
-- Name: chat_endpoints_live_bot_username_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chat_endpoints_live_bot_username_uq ON public.chat_endpoints USING btree (provider, provider_account_id, bot_username) WHERE ((status = ANY (ARRAY['verifying'::text, 'active'::text, 'paused'::text, 'attention'::text])) AND (provider_account_id IS NOT NULL) AND (bot_username IS NOT NULL));


--
-- Name: chat_endpoints_live_discord_bot_external_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chat_endpoints_live_discord_bot_external_uq ON public.chat_endpoints USING btree (provider, bot_external_id) WHERE ((provider = 'discord'::text) AND (status = ANY (ARRAY['verifying'::text, 'active'::text, 'paused'::text, 'attention'::text])) AND (bot_external_id IS NOT NULL));


--
-- Name: chat_endpoints_live_global_app_bot_external_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chat_endpoints_live_global_app_bot_external_uq ON public.chat_endpoints USING btree (provider, bot_external_id) WHERE ((provider = ANY (ARRAY['github'::text, 'microsoft-teams'::text])) AND (status = ANY (ARRAY['verifying'::text, 'active'::text, 'paused'::text, 'attention'::text])) AND (bot_external_id IS NOT NULL));


--
-- Name: chat_endpoints_photon_number_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chat_endpoints_photon_number_uq ON public.chat_endpoints USING btree (bot_external_id) WHERE ((provider = 'imessage-photon'::text) AND (status <> 'archived'::text) AND (bot_external_id IS NOT NULL));


--
-- Name: chat_endpoints_public_id_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chat_endpoints_public_id_uq ON public.chat_endpoints USING btree (public_id);


--
-- Name: chat_endpoints_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_endpoints_status_idx ON public.chat_endpoints USING btree (company_id, status);


--
-- Name: chat_external_principals_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_external_principals_company_idx ON public.chat_external_principals USING btree (company_id);


--
-- Name: chat_external_principals_external_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chat_external_principals_external_uq ON public.chat_external_principals USING btree (company_id, provider, provider_account_id, external_id);


--
-- Name: chat_github_registration_endpoint_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_github_registration_endpoint_idx ON public.chat_github_registrations USING btree (endpoint_id, expires_at);


--
-- Name: chat_github_registration_state_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chat_github_registration_state_uq ON public.chat_github_registrations USING btree (state_hash);


--
-- Name: chat_github_reviews_delivery_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chat_github_reviews_delivery_uq ON public.chat_github_reviews USING btree (endpoint_id, delivery_id);


--
-- Name: chat_github_reviews_pull_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_github_reviews_pull_idx ON public.chat_github_reviews USING btree (endpoint_id, repository_id, pull_number, created_at);


--
-- Name: chat_github_reviews_task_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_github_reviews_task_idx ON public.chat_github_reviews USING btree (company_id, issue_id, run_id);


--
-- Name: chat_identity_links_endpoint_principal_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chat_identity_links_endpoint_principal_uq ON public.chat_identity_links USING btree (endpoint_id, principal_id);


--
-- Name: chat_identity_links_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_identity_links_user_idx ON public.chat_identity_links USING btree (company_id, paperclip_user_id);


--
-- Name: chat_message_links_provider_message_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chat_message_links_provider_message_uq ON public.chat_message_links USING btree (endpoint_id, conversation_id, provider_message_id);


--
-- Name: chat_publications_company_id_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chat_publications_company_id_uq ON public.chat_publications USING btree (company_id, id);


--
-- Name: chat_publications_idempotency_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chat_publications_idempotency_uq ON public.chat_publications USING btree (company_id, idempotency_key);


--
-- Name: chat_publications_work_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_publications_work_idx ON public.chat_publications USING btree (state, next_attempt_at);


--
-- Name: chat_sdk_state_expiry_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_sdk_state_expiry_idx ON public.chat_sdk_state USING btree (expires_at);


--
-- Name: chat_sdk_state_key_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chat_sdk_state_key_uq ON public.chat_sdk_state USING btree (endpoint_id, state_key);


--
-- Name: chat_task_handoffs_source_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_task_handoffs_source_idx ON public.chat_task_handoffs USING btree (company_id, conversation_id);


--
-- Name: chat_teams_file_transfers_publication_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chat_teams_file_transfers_publication_uq ON public.chat_teams_file_transfers USING btree (company_id, publication_id);


--
-- Name: chat_teams_file_transfers_token_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chat_teams_file_transfers_token_uq ON public.chat_teams_file_transfers USING btree (endpoint_id, token_sha256);


--
-- Name: chat_teams_file_transfers_work_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_teams_file_transfers_work_idx ON public.chat_teams_file_transfers USING btree (phase, attempt_expires_at, expires_at);


--
-- Name: cli_auth_challenges_approved_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cli_auth_challenges_approved_by_idx ON public.cli_auth_challenges USING btree (approved_by_user_id);


--
-- Name: cli_auth_challenges_requested_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cli_auth_challenges_requested_company_idx ON public.cli_auth_challenges USING btree (requested_company_id);


--
-- Name: cli_auth_challenges_secret_hash_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cli_auth_challenges_secret_hash_idx ON public.cli_auth_challenges USING btree (secret_hash);


--
-- Name: companies_default_responsible_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX companies_default_responsible_user_idx ON public.companies USING btree (default_responsible_user_id);


--
-- Name: companies_issue_prefix_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX companies_issue_prefix_idx ON public.companies USING btree (issue_prefix);


--
-- Name: company_logos_asset_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX company_logos_asset_uq ON public.company_logos USING btree (asset_id);


--
-- Name: company_logos_company_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX company_logos_company_uq ON public.company_logos USING btree (company_id);


--
-- Name: company_memberships_company_principal_unique_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX company_memberships_company_principal_unique_idx ON public.company_memberships USING btree (company_id, principal_type, principal_id);


--
-- Name: company_memberships_company_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_memberships_company_status_idx ON public.company_memberships USING btree (company_id, status);


--
-- Name: company_memberships_principal_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_memberships_principal_status_idx ON public.company_memberships USING btree (principal_type, principal_id, status);


--
-- Name: company_onboarding_seeds_company_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX company_onboarding_seeds_company_uq ON public.company_onboarding_seeds USING btree (company_id);


--
-- Name: company_secret_bindings_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_secret_bindings_company_idx ON public.company_secret_bindings USING btree (company_id);


--
-- Name: company_secret_bindings_secret_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_secret_bindings_secret_idx ON public.company_secret_bindings USING btree (secret_id);


--
-- Name: company_secret_bindings_target_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_secret_bindings_target_idx ON public.company_secret_bindings USING btree (company_id, target_type, target_id);


--
-- Name: company_secret_bindings_target_path_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX company_secret_bindings_target_path_uq ON public.company_secret_bindings USING btree (company_id, target_type, target_id, config_path);


--
-- Name: company_secret_proposals_company_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_secret_proposals_company_status_idx ON public.company_secret_proposals USING btree (company_id, status);


--
-- Name: company_secret_proposals_expiry_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_secret_proposals_expiry_idx ON public.company_secret_proposals USING btree (status, expires_at);


--
-- Name: company_secret_proposals_interaction_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_secret_proposals_interaction_idx ON public.company_secret_proposals USING btree (interaction_id);


--
-- Name: company_secret_proposals_proposer_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_secret_proposals_proposer_status_idx ON public.company_secret_proposals USING btree (proposed_by_agent_id, status);


--
-- Name: company_secret_proposals_secret_proposal_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_secret_proposals_secret_proposal_idx ON public.company_secret_proposals USING btree (secret_proposal_id);


--
-- Name: company_secret_provider_configs_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_secret_provider_configs_company_idx ON public.company_secret_provider_configs USING btree (company_id);


--
-- Name: company_secret_provider_configs_company_provider_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_secret_provider_configs_company_provider_idx ON public.company_secret_provider_configs USING btree (company_id, provider);


--
-- Name: company_secret_provider_configs_default_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX company_secret_provider_configs_default_uq ON public.company_secret_provider_configs USING btree (company_id, provider) WHERE (is_default = true);


--
-- Name: company_secret_versions_fingerprint_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_secret_versions_fingerprint_idx ON public.company_secret_versions USING btree (fingerprint_sha256);


--
-- Name: company_secret_versions_secret_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_secret_versions_secret_idx ON public.company_secret_versions USING btree (secret_id, created_at);


--
-- Name: company_secret_versions_secret_version_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX company_secret_versions_secret_version_uq ON public.company_secret_versions USING btree (secret_id, version);


--
-- Name: company_secret_versions_value_sha256_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_secret_versions_value_sha256_idx ON public.company_secret_versions USING btree (value_sha256);


--
-- Name: company_secrets_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_secrets_company_idx ON public.company_secrets USING btree (company_id);


--
-- Name: company_secrets_company_key_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX company_secrets_company_key_uq ON public.company_secrets USING btree (company_id, key) WHERE ((scope = 'company'::text) AND (deleted_at IS NULL));


--
-- Name: company_secrets_company_name_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX company_secrets_company_name_uq ON public.company_secrets USING btree (company_id, name) WHERE ((scope = 'company'::text) AND (deleted_at IS NULL));


--
-- Name: company_secrets_company_owner_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_secrets_company_owner_idx ON public.company_secrets USING btree (company_id, owner_user_id);


--
-- Name: company_secrets_company_provider_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_secrets_company_provider_idx ON public.company_secrets USING btree (company_id, provider);


--
-- Name: company_secrets_company_scope_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_secrets_company_scope_idx ON public.company_secrets USING btree (company_id, scope);


--
-- Name: company_secrets_provider_config_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_secrets_provider_config_idx ON public.company_secrets USING btree (provider_config_id);


--
-- Name: company_secrets_user_definition_owner_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_secrets_user_definition_owner_idx ON public.company_secrets USING btree (company_id, user_secret_definition_id, owner_user_id);


--
-- Name: company_secrets_user_definition_owner_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX company_secrets_user_definition_owner_uq ON public.company_secrets USING btree (company_id, user_secret_definition_id, owner_user_id) WHERE ((scope = 'user'::text) AND (deleted_at IS NULL));


--
-- Name: company_skill_comments_company_skill_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_skill_comments_company_skill_created_idx ON public.company_skill_comments USING btree (company_id, company_skill_id, created_at);


--
-- Name: company_skill_comments_parent_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_skill_comments_parent_idx ON public.company_skill_comments USING btree (parent_comment_id);


--
-- Name: company_skill_source_entries_company_skill_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_skill_source_entries_company_skill_idx ON public.company_skill_source_entries USING btree (company_id, skill_id);


--
-- Name: company_skill_source_entries_source_path_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX company_skill_source_entries_source_path_idx ON public.company_skill_source_entries USING btree (source_id, path);


--
-- Name: company_skill_sources_identity_ref_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX company_skill_sources_identity_ref_idx ON public.company_skill_sources USING btree (company_id, repository_id, tracking_ref);


--
-- Name: company_skill_sources_repository_ref_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX company_skill_sources_repository_ref_idx ON public.company_skill_sources USING btree (company_id, repository_url, tracking_ref);


--
-- Name: company_skill_stars_company_skill_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_skill_stars_company_skill_created_idx ON public.company_skill_stars USING btree (company_id, company_skill_id, created_at);


--
-- Name: company_skill_stars_skill_agent_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX company_skill_stars_skill_agent_idx ON public.company_skill_stars USING btree (company_skill_id, agent_id);


--
-- Name: company_skill_stars_skill_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX company_skill_stars_skill_user_idx ON public.company_skill_stars USING btree (company_skill_id, user_id);


--
-- Name: company_skill_test_inputs_company_skill_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_skill_test_inputs_company_skill_active_idx ON public.company_skill_test_inputs USING btree (company_id, skill_id, deleted_at);


--
-- Name: company_skill_test_inputs_company_skill_name_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_skill_test_inputs_company_skill_name_idx ON public.company_skill_test_inputs USING btree (company_id, skill_id, name);


--
-- Name: company_skill_test_run_templates_company_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_skill_test_run_templates_company_active_idx ON public.company_skill_test_run_templates USING btree (company_id, deleted_at, name);


--
-- Name: company_skill_test_runs_company_harness_expires_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_skill_test_runs_company_harness_expires_idx ON public.company_skill_test_runs USING btree (company_id, harness_issue_expires_at);


--
-- Name: company_skill_test_runs_company_input_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_skill_test_runs_company_input_created_idx ON public.company_skill_test_runs USING btree (company_id, input_id, created_at);


--
-- Name: company_skill_test_runs_company_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX company_skill_test_runs_company_issue_idx ON public.company_skill_test_runs USING btree (company_id, issue_id);


--
-- Name: company_skill_test_runs_company_skill_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_skill_test_runs_company_skill_created_idx ON public.company_skill_test_runs USING btree (company_id, skill_id, created_at);


--
-- Name: company_skill_test_runs_company_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_skill_test_runs_company_status_idx ON public.company_skill_test_runs USING btree (company_id, status);


--
-- Name: company_skill_versions_company_skill_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_skill_versions_company_skill_created_idx ON public.company_skill_versions USING btree (company_id, company_skill_id, created_at);


--
-- Name: company_skill_versions_skill_release_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX company_skill_versions_skill_release_idx ON public.company_skill_versions USING btree (company_skill_id, release_id) WHERE (release_id IS NOT NULL);


--
-- Name: company_skill_versions_skill_revision_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX company_skill_versions_skill_revision_idx ON public.company_skill_versions USING btree (company_skill_id, revision_number);


--
-- Name: company_skills_company_categories_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_skills_company_categories_idx ON public.company_skills USING gin (categories);


--
-- Name: company_skills_company_current_version_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_skills_company_current_version_idx ON public.company_skills USING btree (company_id, current_version_id);


--
-- Name: company_skills_company_folder_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_skills_company_folder_idx ON public.company_skills USING btree (company_id, folder_id);


--
-- Name: company_skills_company_forked_from_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_skills_company_forked_from_idx ON public.company_skills USING btree (company_id, forked_from_skill_id);


--
-- Name: company_skills_company_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX company_skills_company_key_idx ON public.company_skills USING btree (company_id, key);


--
-- Name: company_skills_company_name_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_skills_company_name_idx ON public.company_skills USING btree (company_id, name);


--
-- Name: company_skills_company_sharing_scope_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_skills_company_sharing_scope_idx ON public.company_skills USING btree (company_id, sharing_scope);


--
-- Name: company_transfer_runs_actor_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_transfer_runs_actor_status_idx ON public.company_transfer_runs USING btree (actor_key, status);


--
-- Name: company_transfer_runs_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_transfer_runs_company_idx ON public.company_transfer_runs USING btree (company_id);


--
-- Name: company_transfer_runs_idempotency_direction_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_transfer_runs_idempotency_direction_idx ON public.company_transfer_runs USING btree (idempotency_key, direction);


--
-- Name: company_user_sidebar_preferences_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_user_sidebar_preferences_company_idx ON public.company_user_sidebar_preferences USING btree (company_id);


--
-- Name: company_user_sidebar_preferences_company_user_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX company_user_sidebar_preferences_company_user_uq ON public.company_user_sidebar_preferences USING btree (company_id, user_id);


--
-- Name: company_user_sidebar_preferences_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX company_user_sidebar_preferences_user_idx ON public.company_user_sidebar_preferences USING btree (user_id);


--
-- Name: completion_contracts_company_issue_id_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX completion_contracts_company_issue_id_uq ON public.completion_contracts USING btree (company_id, issue_id, id);


--
-- Name: completion_contracts_issue_hash_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX completion_contracts_issue_hash_uq ON public.completion_contracts USING btree (issue_id, canonical_sha256);


--
-- Name: completion_contracts_issue_revision_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX completion_contracts_issue_revision_uq ON public.completion_contracts USING btree (issue_id, revision);


--
-- Name: connection_event_deliveries_company_provider_id_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX connection_event_deliveries_company_provider_id_uq ON public.connection_event_deliveries USING btree (company_id, provider, provider_delivery_id);


--
-- Name: connection_event_deliveries_company_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX connection_event_deliveries_company_status_idx ON public.connection_event_deliveries USING btree (company_id, status, created_at);


--
-- Name: connection_grant_delegations_company_agent_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX connection_grant_delegations_company_agent_idx ON public.connection_grant_delegations USING btree (company_id, agent_id);


--
-- Name: connection_grant_delegations_grant_agent_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX connection_grant_delegations_grant_agent_uq ON public.connection_grant_delegations USING btree (grant_id, agent_id);


--
-- Name: connection_grant_members_company_subject_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX connection_grant_members_company_subject_idx ON public.connection_grant_members USING btree (company_id, subject_type, subject_id);


--
-- Name: connection_grant_members_grant_subject_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX connection_grant_members_grant_subject_uq ON public.connection_grant_members USING btree (grant_id, subject_type, subject_id);


--
-- Name: connection_grants_agent_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX connection_grants_agent_uq ON public.connection_grants USING btree (connection_id, subject_agent_id);


--
-- Name: connection_grants_company_connection_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX connection_grants_company_connection_idx ON public.connection_grants USING btree (company_id, connection_id);


--
-- Name: connection_grants_default_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX connection_grants_default_uq ON public.connection_grants USING btree (connection_id) WHERE ((is_default = true) AND (kind = 'organization'::text));


--
-- Name: connection_grants_subject_agent_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX connection_grants_subject_agent_idx ON public.connection_grants USING btree (company_id, subject_agent_id);


--
-- Name: connection_grants_subject_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX connection_grants_subject_user_idx ON public.connection_grants USING btree (company_id, subject_user_id);


--
-- Name: connection_grants_user_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX connection_grants_user_uq ON public.connection_grants USING btree (connection_id, subject_user_id);


--
-- Name: connection_intent_deliveries_pending_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX connection_intent_deliveries_pending_idx ON public.connection_intent_deliveries USING btree (delivered_at, next_attempt_at);


--
-- Name: connection_token_issuances_agent_connection_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX connection_token_issuances_agent_connection_idx ON public.connection_token_issuances USING btree (company_id, agent_id, connection_id, created_at);


--
-- Name: connection_token_issuances_company_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX connection_token_issuances_company_created_idx ON public.connection_token_issuances USING btree (company_id, created_at);


--
-- Name: connection_token_issuances_connection_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX connection_token_issuances_connection_created_idx ON public.connection_token_issuances USING btree (company_id, connection_id, created_at);


--
-- Name: connection_token_issuances_run_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX connection_token_issuances_run_idx ON public.connection_token_issuances USING btree (company_id, run_id);


--
-- Name: cost_events_company_agent_occurred_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cost_events_company_agent_occurred_idx ON public.cost_events USING btree (company_id, agent_id, occurred_at);


--
-- Name: cost_events_company_biller_occurred_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cost_events_company_biller_occurred_idx ON public.cost_events USING btree (company_id, biller, occurred_at);


--
-- Name: cost_events_company_heartbeat_run_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cost_events_company_heartbeat_run_idx ON public.cost_events USING btree (company_id, heartbeat_run_id);


--
-- Name: cost_events_company_occurred_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cost_events_company_occurred_idx ON public.cost_events USING btree (company_id, occurred_at);


--
-- Name: cost_events_company_provider_occurred_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cost_events_company_provider_occurred_idx ON public.cost_events USING btree (company_id, provider, occurred_at);


--
-- Name: decision_archive_notification_outbox_pending_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX decision_archive_notification_outbox_pending_idx ON public.decision_archive_notification_outbox USING btree (status, created_at);


--
-- Name: decision_archive_notification_outbox_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX decision_archive_notification_outbox_uq ON public.decision_archive_notification_outbox USING btree (company_id, source_kind, source_id, archive_version, origin_agent_id);


--
-- Name: decision_bundles_company_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX decision_bundles_company_created_at_idx ON public.decision_bundles USING btree (company_id, created_at);


--
-- Name: decision_effect_executions_decision_effect_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX decision_effect_executions_decision_effect_uq ON public.decision_effect_executions USING btree (decision_id, effect_index);


--
-- Name: decision_effect_executions_target_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX decision_effect_executions_target_issue_idx ON public.decision_effect_executions USING btree (target_issue_id);


--
-- Name: decision_queue_items_company_source_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX decision_queue_items_company_source_idx ON public.decision_queue_items USING btree (company_id, source_kind, source_id);


--
-- Name: decision_queue_items_queue_source_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX decision_queue_items_queue_source_uq ON public.decision_queue_items USING btree (queue_id, source_kind, source_id);


--
-- Name: decision_queues_company_key_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX decision_queues_company_key_uq ON public.decision_queues USING btree (company_id, key);


--
-- Name: decision_queues_company_updated_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX decision_queues_company_updated_idx ON public.decision_queues USING btree (company_id, updated_at);


--
-- Name: decision_retention_company_archived_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX decision_retention_company_archived_idx ON public.decision_retention USING btree (company_id, archived_at);


--
-- Name: decision_retention_company_source_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX decision_retention_company_source_uq ON public.decision_retention USING btree (company_id, source_kind, source_id);


--
-- Name: decision_target_issues_decision_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX decision_target_issues_decision_idx ON public.decision_target_issues USING btree (decision_id);


--
-- Name: decision_target_issues_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX decision_target_issues_issue_idx ON public.decision_target_issues USING btree (issue_id);


--
-- Name: decision_training_examples_company_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX decision_training_examples_company_created_at_idx ON public.decision_training_examples USING btree (company_id, created_at);


--
-- Name: decision_training_examples_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX decision_training_examples_issue_idx ON public.decision_training_examples USING btree (issue_id);


--
-- Name: decision_training_examples_source_author_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX decision_training_examples_source_author_uq ON public.decision_training_examples USING btree (source_kind, source_id, created_by_user_id);


--
-- Name: decision_triage_company_decide_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX decision_triage_company_decide_by_idx ON public.decision_triage USING btree (company_id, decide_by);


--
-- Name: decision_triage_company_source_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX decision_triage_company_source_uq ON public.decision_triage USING btree (company_id, source_kind, source_id);


--
-- Name: decision_triage_events_company_source_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX decision_triage_events_company_source_created_idx ON public.decision_triage_events USING btree (company_id, source_kind, source_id, created_at);


--
-- Name: decision_triage_events_queue_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX decision_triage_events_queue_created_idx ON public.decision_triage_events USING btree (queue_id, created_at);


--
-- Name: decisions_bundle_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX decisions_bundle_idx ON public.decisions USING btree (bundle_id);


--
-- Name: decisions_company_idempotency_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX decisions_company_idempotency_uq ON public.decisions USING btree (company_id, idempotency_key) WHERE (idempotency_key IS NOT NULL);


--
-- Name: decisions_company_status_expires_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX decisions_company_status_expires_at_idx ON public.decisions USING btree (company_id, status, expires_at);


--
-- Name: decisions_origin_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX decisions_origin_issue_idx ON public.decisions USING btree (origin_issue_id);


--
-- Name: document_annotation_anchor_snapshots_company_document_revision_; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX document_annotation_anchor_snapshots_company_document_revision_ ON public.document_annotation_anchor_snapshots USING btree (company_id, document_id, to_revision_number);


--
-- Name: document_annotation_anchor_snapshots_company_thread_created_at_; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX document_annotation_anchor_snapshots_company_thread_created_at_ ON public.document_annotation_anchor_snapshots USING btree (company_id, thread_id, created_at);


--
-- Name: document_annotation_comments_body_search_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX document_annotation_comments_body_search_idx ON public.document_annotation_comments USING gin (body public.gin_trgm_ops);


--
-- Name: document_annotation_comments_company_case_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX document_annotation_comments_company_case_created_at_idx ON public.document_annotation_comments USING btree (company_id, case_id, created_at);


--
-- Name: document_annotation_comments_company_document_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX document_annotation_comments_company_document_created_at_idx ON public.document_annotation_comments USING btree (company_id, document_id, created_at);


--
-- Name: document_annotation_comments_company_issue_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX document_annotation_comments_company_issue_created_at_idx ON public.document_annotation_comments USING btree (company_id, issue_id, created_at);


--
-- Name: document_annotation_comments_company_routine_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX document_annotation_comments_company_routine_created_at_idx ON public.document_annotation_comments USING btree (company_id, routine_id, created_at);


--
-- Name: document_annotation_comments_company_thread_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX document_annotation_comments_company_thread_created_at_idx ON public.document_annotation_comments USING btree (company_id, thread_id, created_at);


--
-- Name: document_annotation_comments_issue_comment_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX document_annotation_comments_issue_comment_idx ON public.document_annotation_comments USING btree (issue_comment_id);


--
-- Name: document_annotation_threads_company_anchor_state_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX document_annotation_threads_company_anchor_state_idx ON public.document_annotation_threads USING btree (company_id, anchor_state);


--
-- Name: document_annotation_threads_company_case_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX document_annotation_threads_company_case_status_idx ON public.document_annotation_threads USING btree (company_id, case_id, status);


--
-- Name: document_annotation_threads_company_current_revision_open_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX document_annotation_threads_company_current_revision_open_idx ON public.document_annotation_threads USING btree (company_id, document_id, current_revision_id, status);


--
-- Name: document_annotation_threads_company_document_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX document_annotation_threads_company_document_status_idx ON public.document_annotation_threads USING btree (company_id, document_id, status);


--
-- Name: document_annotation_threads_company_issue_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX document_annotation_threads_company_issue_status_idx ON public.document_annotation_threads USING btree (company_id, issue_id, status);


--
-- Name: document_annotation_threads_company_routine_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX document_annotation_threads_company_routine_status_idx ON public.document_annotation_threads USING btree (company_id, routine_id, status);


--
-- Name: document_memberships_company_user_document_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX document_memberships_company_user_document_uq ON public.document_memberships USING btree (company_id, user_id, document_id);


--
-- Name: document_memberships_company_user_starred_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX document_memberships_company_user_starred_idx ON public.document_memberships USING btree (company_id, user_id, starred_at);


--
-- Name: document_revisions_company_document_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX document_revisions_company_document_created_idx ON public.document_revisions USING btree (company_id, document_id, created_at);


--
-- Name: document_revisions_document_revision_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX document_revisions_document_revision_uq ON public.document_revisions USING btree (document_id, revision_number);


--
-- Name: documents_company_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX documents_company_created_idx ON public.documents USING btree (company_id, created_at);


--
-- Name: documents_company_updated_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX documents_company_updated_idx ON public.documents USING btree (company_id, updated_at);


--
-- Name: documents_latest_body_search_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX documents_latest_body_search_idx ON public.documents USING gin (latest_body public.gin_trgm_ops);


--
-- Name: documents_title_search_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX documents_title_search_idx ON public.documents USING gin (title public.gin_trgm_ops);


--
-- Name: email_messages_conversation_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_conversation_idx ON public.email_messages USING btree (company_id, conversation_id, "timestamp");


--
-- Name: email_messages_provider_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX email_messages_provider_uq ON public.email_messages USING btree (endpoint_id, provider_message_id);


--
-- Name: email_sends_pending_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_sends_pending_idx ON public.email_sends USING btree (endpoint_id, outcome) WHERE (outcome = ANY (ARRAY['queued'::text, 'uncertain'::text]));


--
-- Name: environment_custom_image_setup_sessions_environment_active_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX environment_custom_image_setup_sessions_environment_active_uq ON public.environment_custom_image_setup_sessions USING btree (environment_id) WHERE (status = ANY (ARRAY['starting'::text, 'waiting_for_user'::text, 'capturing'::text]));


--
-- Name: environment_custom_image_setup_sessions_environment_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX environment_custom_image_setup_sessions_environment_status_idx ON public.environment_custom_image_setup_sessions USING btree (environment_id, status);


--
-- Name: environment_custom_image_setup_sessions_expires_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX environment_custom_image_setup_sessions_expires_idx ON public.environment_custom_image_setup_sessions USING btree (expires_at);


--
-- Name: environment_custom_image_setup_sessions_promoted_template_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX environment_custom_image_setup_sessions_promoted_template_idx ON public.environment_custom_image_setup_sessions USING btree (promoted_template_id);


--
-- Name: environment_custom_image_setup_sessions_provider_lease_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX environment_custom_image_setup_sessions_provider_lease_idx ON public.environment_custom_image_setup_sessions USING btree (provider, provider_lease_id);


--
-- Name: environment_custom_image_setup_sessions_template_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX environment_custom_image_setup_sessions_template_idx ON public.environment_custom_image_setup_sessions USING btree (template_id);


--
-- Name: environment_custom_image_templates_environment_active_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX environment_custom_image_templates_environment_active_uq ON public.environment_custom_image_templates USING btree (environment_id) WHERE (status = 'active'::text);


--
-- Name: environment_custom_image_templates_environment_provider_status_; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX environment_custom_image_templates_environment_provider_status_ ON public.environment_custom_image_templates USING btree (environment_id, provider, status);


--
-- Name: environment_custom_image_templates_environment_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX environment_custom_image_templates_environment_status_idx ON public.environment_custom_image_templates USING btree (environment_id, status);


--
-- Name: environment_custom_image_templates_last_used_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX environment_custom_image_templates_last_used_idx ON public.environment_custom_image_templates USING btree (last_used_at);


--
-- Name: environment_custom_image_templates_superseded_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX environment_custom_image_templates_superseded_by_idx ON public.environment_custom_image_templates USING btree (superseded_by_template_id);


--
-- Name: environment_leases_company_environment_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX environment_leases_company_environment_status_idx ON public.environment_leases USING btree (company_id, environment_id, status);


--
-- Name: environment_leases_company_execution_workspace_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX environment_leases_company_execution_workspace_idx ON public.environment_leases USING btree (company_id, execution_workspace_id);


--
-- Name: environment_leases_company_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX environment_leases_company_issue_idx ON public.environment_leases USING btree (company_id, issue_id);


--
-- Name: environment_leases_company_last_used_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX environment_leases_company_last_used_idx ON public.environment_leases USING btree (company_id, last_used_at);


--
-- Name: environment_leases_heartbeat_run_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX environment_leases_heartbeat_run_idx ON public.environment_leases USING btree (heartbeat_run_id);


--
-- Name: environment_leases_provider_lease_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX environment_leases_provider_lease_idx ON public.environment_leases USING btree (provider_lease_id);


--
-- Name: environments_local_driver_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX environments_local_driver_idx ON public.environments USING btree (driver) WHERE (driver = 'local'::text);


--
-- Name: environments_managed_sandbox_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX environments_managed_sandbox_idx ON public.environments USING btree (driver) WHERE ((driver = 'sandbox'::text) AND (((metadata ->> 'managedByPaperclip'::text))::boolean = true));


--
-- Name: environments_name_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX environments_name_idx ON public.environments USING btree (name);


--
-- Name: environments_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX environments_status_idx ON public.environments USING btree (status);


--
-- Name: execution_workspace_runtime_leases_company_owner_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX execution_workspace_runtime_leases_company_owner_idx ON public.execution_workspace_runtime_leases USING btree (company_id, owner_key);


--
-- Name: execution_workspace_runtime_leases_company_workspace_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX execution_workspace_runtime_leases_company_workspace_idx ON public.execution_workspace_runtime_leases USING btree (company_id, execution_workspace_id);


--
-- Name: execution_workspace_runtime_leases_expires_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX execution_workspace_runtime_leases_expires_at_idx ON public.execution_workspace_runtime_leases USING btree (expires_at);


--
-- Name: execution_workspaces_company_branch_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX execution_workspaces_company_branch_idx ON public.execution_workspaces USING btree (company_id, branch_name);


--
-- Name: execution_workspaces_company_last_used_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX execution_workspaces_company_last_used_idx ON public.execution_workspaces USING btree (company_id, last_used_at);


--
-- Name: execution_workspaces_company_project_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX execution_workspaces_company_project_status_idx ON public.execution_workspaces USING btree (company_id, project_id, status);


--
-- Name: execution_workspaces_company_project_workspace_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX execution_workspaces_company_project_workspace_status_idx ON public.execution_workspaces USING btree (company_id, project_workspace_id, status);


--
-- Name: execution_workspaces_company_source_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX execution_workspaces_company_source_issue_idx ON public.execution_workspaces USING btree (company_id, source_issue_id);


--
-- Name: external_object_mentions_company_object_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX external_object_mentions_company_object_idx ON public.external_object_mentions USING btree (company_id, object_id);


--
-- Name: external_object_mentions_company_provider_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX external_object_mentions_company_provider_idx ON public.external_object_mentions USING btree (company_id, provider_key, object_type);


--
-- Name: external_object_mentions_company_source_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX external_object_mentions_company_source_issue_idx ON public.external_object_mentions USING btree (company_id, source_issue_id);


--
-- Name: external_object_mentions_company_source_null_record_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX external_object_mentions_company_source_null_record_uq ON public.external_object_mentions USING btree (company_id, source_issue_id, source_kind, document_key, property_key, canonical_identity_hash) WHERE ((source_record_id IS NULL) AND (canonical_identity_hash IS NOT NULL));


--
-- Name: external_object_mentions_company_source_record_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX external_object_mentions_company_source_record_uq ON public.external_object_mentions USING btree (company_id, source_issue_id, source_kind, source_record_id, document_key, property_key, canonical_identity_hash) WHERE ((source_record_id IS NOT NULL) AND (canonical_identity_hash IS NOT NULL));


--
-- Name: external_objects_company_external_id_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX external_objects_company_external_id_uq ON public.external_objects USING btree (company_id, provider_key, object_type, external_id);


--
-- Name: external_objects_company_identity_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX external_objects_company_identity_uq ON public.external_objects USING btree (company_id, provider_key, object_type, canonical_identity_hash);


--
-- Name: external_objects_company_provider_object_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX external_objects_company_provider_object_idx ON public.external_objects USING btree (company_id, provider_key, object_type);


--
-- Name: external_objects_company_provider_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX external_objects_company_provider_status_idx ON public.external_objects USING btree (company_id, provider_key, status_category);


--
-- Name: external_objects_company_refresh_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX external_objects_company_refresh_idx ON public.external_objects USING btree (company_id, next_refresh_at);


--
-- Name: feedback_exports_company_author_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX feedback_exports_company_author_idx ON public.feedback_exports USING btree (company_id, author_user_id, created_at);


--
-- Name: feedback_exports_company_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX feedback_exports_company_created_idx ON public.feedback_exports USING btree (company_id, created_at);


--
-- Name: feedback_exports_company_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX feedback_exports_company_issue_idx ON public.feedback_exports USING btree (company_id, issue_id, created_at);


--
-- Name: feedback_exports_company_project_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX feedback_exports_company_project_idx ON public.feedback_exports USING btree (company_id, project_id, created_at);


--
-- Name: feedback_exports_company_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX feedback_exports_company_status_idx ON public.feedback_exports USING btree (company_id, status, created_at);


--
-- Name: feedback_exports_feedback_vote_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX feedback_exports_feedback_vote_idx ON public.feedback_exports USING btree (feedback_vote_id);


--
-- Name: feedback_votes_author_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX feedback_votes_author_idx ON public.feedback_votes USING btree (author_user_id, created_at);


--
-- Name: feedback_votes_company_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX feedback_votes_company_issue_idx ON public.feedback_votes USING btree (company_id, issue_id);


--
-- Name: feedback_votes_company_target_author_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX feedback_votes_company_target_author_idx ON public.feedback_votes USING btree (company_id, target_type, target_id, author_user_id);


--
-- Name: feedback_votes_issue_target_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX feedback_votes_issue_target_idx ON public.feedback_votes USING btree (issue_id, target_type, target_id);


--
-- Name: finance_events_company_biller_occurred_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX finance_events_company_biller_occurred_idx ON public.finance_events USING btree (company_id, biller, occurred_at);


--
-- Name: finance_events_company_cost_event_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX finance_events_company_cost_event_idx ON public.finance_events USING btree (company_id, cost_event_id);


--
-- Name: finance_events_company_direction_occurred_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX finance_events_company_direction_occurred_idx ON public.finance_events USING btree (company_id, direction, occurred_at);


--
-- Name: finance_events_company_heartbeat_run_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX finance_events_company_heartbeat_run_idx ON public.finance_events USING btree (company_id, heartbeat_run_id);


--
-- Name: finance_events_company_kind_occurred_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX finance_events_company_kind_occurred_idx ON public.finance_events USING btree (company_id, event_kind, occurred_at);


--
-- Name: finance_events_company_occurred_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX finance_events_company_occurred_idx ON public.finance_events USING btree (company_id, occurred_at);


--
-- Name: folders_company_kind_parent_position_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX folders_company_kind_parent_position_idx ON public.folders USING btree (company_id, kind, parent_id, "position", name);


--
-- Name: folders_company_kind_parent_slug_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX folders_company_kind_parent_slug_uq ON public.folders USING btree (company_id, kind, parent_id, slug) WHERE (parent_id IS NOT NULL);


--
-- Name: folders_company_kind_position_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX folders_company_kind_position_idx ON public.folders USING btree (company_id, kind, "position", name);


--
-- Name: folders_company_kind_root_slug_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX folders_company_kind_root_slug_uq ON public.folders USING btree (company_id, kind, slug) WHERE (parent_id IS NULL);


--
-- Name: folders_company_kind_system_key_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX folders_company_kind_system_key_uq ON public.folders USING btree (company_id, kind, system_key) WHERE (system_key IS NOT NULL);


--
-- Name: goals_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX goals_company_idx ON public.goals USING btree (company_id);


--
-- Name: heartbeat_run_events_adapter_invoke_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX heartbeat_run_events_adapter_invoke_type_idx ON public.heartbeat_run_events USING btree (((payload ->> 'adapterType'::text)), company_id, run_id) WHERE (event_type = 'adapter.invoke'::text);


--
-- Name: heartbeat_run_events_company_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX heartbeat_run_events_company_created_idx ON public.heartbeat_run_events USING btree (company_id, created_at);


--
-- Name: heartbeat_run_events_company_run_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX heartbeat_run_events_company_run_idx ON public.heartbeat_run_events USING btree (company_id, run_id);


--
-- Name: heartbeat_run_events_run_seq_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX heartbeat_run_events_run_seq_uq ON public.heartbeat_run_events USING btree (run_id, seq);


--
-- Name: heartbeat_run_events_run_source_event_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX heartbeat_run_events_run_source_event_uq ON public.heartbeat_run_events USING btree (run_id, source_event_id) WHERE (source_event_id IS NOT NULL);


--
-- Name: heartbeat_run_events_run_source_seq_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX heartbeat_run_events_run_source_seq_uq ON public.heartbeat_run_events USING btree (run_id, source_instance_id, source_seq) WHERE ((source_instance_id IS NOT NULL) AND (source_seq IS NOT NULL));


--
-- Name: heartbeat_run_watchdog_decisions_company_run_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX heartbeat_run_watchdog_decisions_company_run_created_idx ON public.heartbeat_run_watchdog_decisions USING btree (company_id, run_id, created_at);


--
-- Name: heartbeat_run_watchdog_decisions_company_run_snooze_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX heartbeat_run_watchdog_decisions_company_run_snooze_idx ON public.heartbeat_run_watchdog_decisions USING btree (company_id, run_id, snoozed_until);


--
-- Name: heartbeat_runs_company_agent_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX heartbeat_runs_company_agent_created_idx ON public.heartbeat_runs USING btree (company_id, agent_id, created_at);


--
-- Name: heartbeat_runs_company_agent_started_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX heartbeat_runs_company_agent_started_idx ON public.heartbeat_runs USING btree (company_id, agent_id, started_at);


--
-- Name: heartbeat_runs_company_context_issue_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX heartbeat_runs_company_context_issue_created_idx ON public.heartbeat_runs USING btree (company_id, ((context_snapshot ->> 'issueId'::text)), created_at, id);


--
-- Name: heartbeat_runs_company_created_at_desc_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX heartbeat_runs_company_created_at_desc_idx ON public.heartbeat_runs USING btree (company_id, created_at DESC);


--
-- Name: heartbeat_runs_company_created_desc_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX heartbeat_runs_company_created_desc_idx ON public.heartbeat_runs USING btree (company_id, created_at DESC);


--
-- Name: heartbeat_runs_company_ctx_issue_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX heartbeat_runs_company_ctx_issue_created_idx ON public.heartbeat_runs USING btree (company_id, ((context_snapshot ->> 'issueId'::text)), created_at DESC);


--
-- Name: heartbeat_runs_company_ctx_pcissue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX heartbeat_runs_company_ctx_pcissue_idx ON public.heartbeat_runs USING btree (company_id, (((context_snapshot -> 'paperclipIssue'::text) ->> 'id'::text)));


--
-- Name: heartbeat_runs_company_ctx_task_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX heartbeat_runs_company_ctx_task_created_idx ON public.heartbeat_runs USING btree (company_id, ((context_snapshot ->> 'taskId'::text)), created_at DESC);


--
-- Name: heartbeat_runs_company_ctx_taskkey_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX heartbeat_runs_company_ctx_taskkey_created_idx ON public.heartbeat_runs USING btree (company_id, ((context_snapshot ->> 'taskKey'::text)), created_at DESC);


--
-- Name: heartbeat_runs_company_liveness_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX heartbeat_runs_company_liveness_idx ON public.heartbeat_runs USING btree (company_id, liveness_state, created_at);


--
-- Name: heartbeat_runs_company_native_issue_contract_id_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX heartbeat_runs_company_native_issue_contract_id_uq ON public.heartbeat_runs USING btree (company_id, native_issue_id, id, completion_contract_id);


--
-- Name: heartbeat_runs_company_native_issue_id_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX heartbeat_runs_company_native_issue_id_uq ON public.heartbeat_runs USING btree (company_id, native_issue_id, id);


--
-- Name: heartbeat_runs_company_owner_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX heartbeat_runs_company_owner_issue_idx ON public.heartbeat_runs USING btree (company_id, COALESCE((native_issue_id)::text, (context_snapshot ->> 'issueId'::text)));


--
-- Name: heartbeat_runs_company_recovery_action_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX heartbeat_runs_company_recovery_action_idx ON public.heartbeat_runs USING btree (company_id, ((context_snapshot ->> 'recoveryActionId'::text)), created_at DESC, id DESC) WHERE ((context_snapshot ->> 'recoveryActionId'::text) IS NOT NULL);


--
-- Name: heartbeat_runs_company_responsible_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX heartbeat_runs_company_responsible_user_idx ON public.heartbeat_runs USING btree (company_id, responsible_user_id, created_at);


--
-- Name: heartbeat_runs_company_status_last_output_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX heartbeat_runs_company_status_last_output_idx ON public.heartbeat_runs USING btree (company_id, status, last_output_at);


--
-- Name: heartbeat_runs_company_status_process_started_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX heartbeat_runs_company_status_process_started_idx ON public.heartbeat_runs USING btree (company_id, status, process_started_at);


--
-- Name: heartbeat_runs_execution_control_deadline_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX heartbeat_runs_execution_control_deadline_idx ON public.heartbeat_runs USING btree (execution_control_deadline_at) WHERE (execution_control_deadline_at IS NOT NULL);


--
-- Name: heartbeat_runs_execution_status_delivery_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX heartbeat_runs_execution_status_delivery_idx ON public.heartbeat_runs USING btree (execution_status_delivery_id) WHERE (execution_status_delivery_id IS NOT NULL);


--
-- Name: heartbeat_runs_native_replacement_predecessor_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX heartbeat_runs_native_replacement_predecessor_uq ON public.heartbeat_runs USING btree (company_id, retry_of_run_id) WHERE (scheduled_retry_reason = 'native_safe_replacement'::text);


--
-- Name: inbox_dismissals_company_item_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX inbox_dismissals_company_item_idx ON public.inbox_dismissals USING btree (company_id, item_key);


--
-- Name: inbox_dismissals_company_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX inbox_dismissals_company_user_idx ON public.inbox_dismissals USING btree (company_id, user_id);


--
-- Name: inbox_dismissals_company_user_item_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX inbox_dismissals_company_user_item_idx ON public.inbox_dismissals USING btree (company_id, user_id, item_key);


--
-- Name: instance_settings_singleton_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX instance_settings_singleton_key_idx ON public.instance_settings USING btree (singleton_key);


--
-- Name: instance_user_roles_role_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX instance_user_roles_role_idx ON public.instance_user_roles USING btree (role);


--
-- Name: instance_user_roles_user_role_unique_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX instance_user_roles_user_role_unique_idx ON public.instance_user_roles USING btree (user_id, role);


--
-- Name: invites_company_invite_state_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX invites_company_invite_state_idx ON public.invites USING btree (company_id, invite_type, revoked_at, expires_at);


--
-- Name: invites_token_hash_unique_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX invites_token_hash_unique_idx ON public.invites USING btree (token_hash);


--
-- Name: issue_approvals_approval_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_approvals_approval_idx ON public.issue_approvals USING btree (approval_id);


--
-- Name: issue_approvals_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_approvals_company_idx ON public.issue_approvals USING btree (company_id);


--
-- Name: issue_approvals_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_approvals_issue_idx ON public.issue_approvals USING btree (issue_id);


--
-- Name: issue_attachments_asset_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX issue_attachments_asset_uq ON public.issue_attachments USING btree (asset_id);


--
-- Name: issue_attachments_company_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_attachments_company_issue_idx ON public.issue_attachments USING btree (company_id, issue_id);


--
-- Name: issue_attachments_issue_comment_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_attachments_issue_comment_idx ON public.issue_attachments USING btree (issue_comment_id);


--
-- Name: issue_attachments_originating_run_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_attachments_originating_run_idx ON public.issue_attachments USING btree (originating_run_id);


--
-- Name: issue_comments_body_search_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_comments_body_search_idx ON public.issue_comments USING gin (body public.gin_trgm_ops);


--
-- Name: issue_comments_company_author_issue_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_comments_company_author_issue_created_at_idx ON public.issue_comments USING btree (company_id, author_user_id, issue_id, created_at);


--
-- Name: issue_comments_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_comments_company_idx ON public.issue_comments USING btree (company_id);


--
-- Name: issue_comments_company_issue_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_comments_company_issue_created_at_idx ON public.issue_comments USING btree (company_id, issue_id, created_at);


--
-- Name: issue_comments_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_comments_issue_idx ON public.issue_comments USING btree (issue_id);


--
-- Name: issue_create_idempotency_keys_company_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_create_idempotency_keys_company_created_at_idx ON public.issue_create_idempotency_keys USING btree (company_id, created_at);


--
-- Name: issue_create_idempotency_keys_company_key_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX issue_create_idempotency_keys_company_key_uq ON public.issue_create_idempotency_keys USING btree (company_id, idempotency_key);


--
-- Name: issue_create_idempotency_keys_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_create_idempotency_keys_issue_idx ON public.issue_create_idempotency_keys USING btree (issue_id);


--
-- Name: issue_documents_company_issue_key_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX issue_documents_company_issue_key_uq ON public.issue_documents USING btree (company_id, issue_id, key);


--
-- Name: issue_documents_company_issue_updated_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_documents_company_issue_updated_idx ON public.issue_documents USING btree (company_id, issue_id, updated_at);


--
-- Name: issue_documents_document_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX issue_documents_document_uq ON public.issue_documents USING btree (document_id);


--
-- Name: issue_execution_decisions_company_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_execution_decisions_company_issue_idx ON public.issue_execution_decisions USING btree (company_id, issue_id);


--
-- Name: issue_execution_decisions_stage_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_execution_decisions_stage_idx ON public.issue_execution_decisions USING btree (issue_id, stage_id, created_at);


--
-- Name: issue_inbox_archives_company_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_inbox_archives_company_issue_idx ON public.issue_inbox_archives USING btree (company_id, issue_id);


--
-- Name: issue_inbox_archives_company_issue_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX issue_inbox_archives_company_issue_user_idx ON public.issue_inbox_archives USING btree (company_id, issue_id, user_id);


--
-- Name: issue_inbox_archives_company_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_inbox_archives_company_user_idx ON public.issue_inbox_archives USING btree (company_id, user_id);


--
-- Name: issue_labels_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_labels_company_idx ON public.issue_labels USING btree (company_id);


--
-- Name: issue_labels_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_labels_issue_idx ON public.issue_labels USING btree (issue_id);


--
-- Name: issue_labels_label_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_labels_label_idx ON public.issue_labels USING btree (label_id);


--
-- Name: issue_plan_decompositions_active_owner_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_plan_decompositions_active_owner_idx ON public.issue_plan_decompositions USING btree (company_id, owner_agent_id) WHERE (status = 'in_flight'::text);


--
-- Name: issue_plan_decompositions_company_source_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_plan_decompositions_company_source_status_idx ON public.issue_plan_decompositions USING btree (company_id, source_issue_id, status);


--
-- Name: issue_plan_decompositions_source_revision_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX issue_plan_decompositions_source_revision_uq ON public.issue_plan_decompositions USING btree (company_id, source_issue_id, accepted_plan_revision_id);


--
-- Name: issue_question_response_deliveries_company_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_question_response_deliveries_company_issue_idx ON public.issue_question_response_deliveries USING btree (company_id, issue_id, created_at);


--
-- Name: issue_question_response_deliveries_correlation_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX issue_question_response_deliveries_correlation_uq ON public.issue_question_response_deliveries USING btree (correlation_id);


--
-- Name: issue_question_response_deliveries_interaction_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX issue_question_response_deliveries_interaction_uq ON public.issue_question_response_deliveries USING btree (interaction_id);


--
-- Name: issue_question_response_deliveries_pending_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_question_response_deliveries_pending_idx ON public.issue_question_response_deliveries USING btree (status, created_at);


--
-- Name: issue_read_states_company_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_read_states_company_issue_idx ON public.issue_read_states USING btree (company_id, issue_id);


--
-- Name: issue_read_states_company_issue_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX issue_read_states_company_issue_user_idx ON public.issue_read_states USING btree (company_id, issue_id, user_id);


--
-- Name: issue_read_states_company_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_read_states_company_user_idx ON public.issue_read_states USING btree (company_id, user_id);


--
-- Name: issue_recovery_actions_active_fingerprint_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX issue_recovery_actions_active_fingerprint_uq ON public.issue_recovery_actions USING btree (company_id, source_issue_id, cause, fingerprint) WHERE (status = ANY (ARRAY['active'::text, 'escalated'::text]));


--
-- Name: issue_recovery_actions_active_source_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX issue_recovery_actions_active_source_uq ON public.issue_recovery_actions USING btree (company_id, source_issue_id) WHERE (status = ANY (ARRAY['active'::text, 'escalated'::text]));


--
-- Name: issue_recovery_actions_company_owner_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_recovery_actions_company_owner_status_idx ON public.issue_recovery_actions USING btree (company_id, owner_agent_id, status);


--
-- Name: issue_recovery_actions_company_recovery_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_recovery_actions_company_recovery_issue_idx ON public.issue_recovery_actions USING btree (company_id, recovery_issue_id);


--
-- Name: issue_recovery_actions_company_source_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_recovery_actions_company_source_status_idx ON public.issue_recovery_actions USING btree (company_id, source_issue_id, status);


--
-- Name: issue_recovery_actions_corrective_run_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_recovery_actions_corrective_run_idx ON public.issue_recovery_actions USING btree (corrective_run_id);


--
-- Name: issue_recovery_actions_epoch_identity_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX issue_recovery_actions_epoch_identity_uq ON public.issue_recovery_actions USING btree (company_id, source_issue_id, cause, review_epoch_key) WHERE (review_epoch_key IS NOT NULL);


--
-- Name: issue_reference_mentions_company_issue_pair_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_reference_mentions_company_issue_pair_idx ON public.issue_reference_mentions USING btree (company_id, source_issue_id, target_issue_id);


--
-- Name: issue_reference_mentions_company_source_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_reference_mentions_company_source_issue_idx ON public.issue_reference_mentions USING btree (company_id, source_issue_id);


--
-- Name: issue_reference_mentions_company_source_mention_null_record_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX issue_reference_mentions_company_source_mention_null_record_uq ON public.issue_reference_mentions USING btree (company_id, source_issue_id, target_issue_id, source_kind) WHERE (source_record_id IS NULL);


--
-- Name: issue_reference_mentions_company_source_mention_record_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX issue_reference_mentions_company_source_mention_record_uq ON public.issue_reference_mentions USING btree (company_id, source_issue_id, target_issue_id, source_kind, source_record_id) WHERE (source_record_id IS NOT NULL);


--
-- Name: issue_reference_mentions_company_target_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_reference_mentions_company_target_issue_idx ON public.issue_reference_mentions USING btree (company_id, target_issue_id);


--
-- Name: issue_relations_company_edge_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX issue_relations_company_edge_uq ON public.issue_relations USING btree (company_id, issue_id, related_issue_id, type);


--
-- Name: issue_relations_company_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_relations_company_issue_idx ON public.issue_relations USING btree (company_id, issue_id);


--
-- Name: issue_relations_company_related_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_relations_company_related_issue_idx ON public.issue_relations USING btree (company_id, related_issue_id);


--
-- Name: issue_relations_company_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_relations_company_type_idx ON public.issue_relations USING btree (company_id, type);


--
-- Name: issue_thread_interactions_addressee_agent_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_thread_interactions_addressee_agent_idx ON public.issue_thread_interactions USING btree (addressee_agent_id);


--
-- Name: issue_thread_interactions_addressee_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_thread_interactions_addressee_user_idx ON public.issue_thread_interactions USING btree (addressee_user_id);


--
-- Name: issue_thread_interactions_company_issue_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_thread_interactions_company_issue_created_at_idx ON public.issue_thread_interactions USING btree (company_id, issue_id, created_at);


--
-- Name: issue_thread_interactions_company_issue_idempotency_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX issue_thread_interactions_company_issue_idempotency_uq ON public.issue_thread_interactions USING btree (company_id, issue_id, idempotency_key) WHERE (idempotency_key IS NOT NULL);


--
-- Name: issue_thread_interactions_company_issue_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_thread_interactions_company_issue_status_idx ON public.issue_thread_interactions USING btree (company_id, issue_id, status);


--
-- Name: issue_thread_interactions_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_thread_interactions_issue_idx ON public.issue_thread_interactions USING btree (issue_id);


--
-- Name: issue_thread_interactions_source_comment_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_thread_interactions_source_comment_idx ON public.issue_thread_interactions USING btree (source_comment_id);


--
-- Name: issue_tree_hold_members_company_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_tree_hold_members_company_issue_idx ON public.issue_tree_hold_members USING btree (company_id, issue_id);


--
-- Name: issue_tree_hold_members_hold_depth_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_tree_hold_members_hold_depth_idx ON public.issue_tree_hold_members USING btree (hold_id, depth);


--
-- Name: issue_tree_hold_members_hold_issue_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX issue_tree_hold_members_hold_issue_uq ON public.issue_tree_hold_members USING btree (hold_id, issue_id);


--
-- Name: issue_tree_holds_company_root_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_tree_holds_company_root_status_idx ON public.issue_tree_holds USING btree (company_id, root_issue_id, status);


--
-- Name: issue_tree_holds_company_status_mode_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_tree_holds_company_status_mode_idx ON public.issue_tree_holds USING btree (company_id, status, mode);


--
-- Name: issue_watchdogs_company_agent_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_watchdogs_company_agent_idx ON public.issue_watchdogs USING btree (company_id, watchdog_agent_id);


--
-- Name: issue_watchdogs_company_issue_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX issue_watchdogs_company_issue_uq ON public.issue_watchdogs USING btree (company_id, issue_id);


--
-- Name: issue_watchdogs_company_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_watchdogs_company_status_idx ON public.issue_watchdogs USING btree (company_id, status);


--
-- Name: issue_watchdogs_company_watchdog_issue_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX issue_watchdogs_company_watchdog_issue_uq ON public.issue_watchdogs USING btree (company_id, watchdog_issue_id) WHERE (watchdog_issue_id IS NOT NULL);


--
-- Name: issue_work_products_company_execution_workspace_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_work_products_company_execution_workspace_type_idx ON public.issue_work_products USING btree (company_id, execution_workspace_id, type);


--
-- Name: issue_work_products_company_issue_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_work_products_company_issue_type_idx ON public.issue_work_products USING btree (company_id, issue_id, type);


--
-- Name: issue_work_products_company_provider_external_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_work_products_company_provider_external_id_idx ON public.issue_work_products USING btree (company_id, provider, external_id);


--
-- Name: issue_work_products_company_updated_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issue_work_products_company_updated_idx ON public.issue_work_products USING btree (company_id, updated_at);


--
-- Name: issues_active_liveness_recovery_incident_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX issues_active_liveness_recovery_incident_uq ON public.issues USING btree (company_id, origin_kind, origin_id) WHERE ((origin_kind = 'harness_liveness_escalation'::text) AND (origin_id IS NOT NULL) AND (hidden_at IS NULL) AND (status <> ALL (ARRAY['done'::text, 'cancelled'::text])));


--
-- Name: issues_active_liveness_recovery_leaf_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX issues_active_liveness_recovery_leaf_uq ON public.issues USING btree (company_id, origin_kind, origin_fingerprint) WHERE ((origin_kind = 'harness_liveness_escalation'::text) AND (origin_fingerprint <> 'default'::text) AND (hidden_at IS NULL) AND (status <> ALL (ARRAY['done'::text, 'cancelled'::text])));


--
-- Name: issues_active_productivity_review_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX issues_active_productivity_review_uq ON public.issues USING btree (company_id, origin_kind, origin_id) WHERE ((origin_kind = 'issue_productivity_review'::text) AND (origin_id IS NOT NULL) AND (hidden_at IS NULL) AND (status <> ALL (ARRAY['done'::text, 'cancelled'::text])));


--
-- Name: issues_active_stale_run_evaluation_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX issues_active_stale_run_evaluation_uq ON public.issues USING btree (company_id, origin_kind, origin_id) WHERE ((origin_kind = 'stale_active_run_evaluation'::text) AND (origin_id IS NOT NULL) AND (hidden_at IS NULL) AND (status <> ALL (ARRAY['done'::text, 'cancelled'::text])));


--
-- Name: issues_active_stranded_issue_recovery_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX issues_active_stranded_issue_recovery_uq ON public.issues USING btree (company_id, origin_kind, origin_id) WHERE ((origin_kind = 'stranded_issue_recovery'::text) AND (origin_id IS NOT NULL) AND (hidden_at IS NULL) AND (status <> ALL (ARRAY['done'::text, 'cancelled'::text])));


--
-- Name: issues_active_task_watchdog_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX issues_active_task_watchdog_uq ON public.issues USING btree (company_id, origin_kind, origin_id) WHERE ((origin_kind = 'task_watchdog'::text) AND (origin_id IS NOT NULL) AND (hidden_at IS NULL) AND (status <> ALL (ARRAY['done'::text, 'cancelled'::text])));


--
-- Name: issues_company_assignee_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issues_company_assignee_status_idx ON public.issues USING btree (company_id, assignee_agent_id, status);


--
-- Name: issues_company_assignee_user_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issues_company_assignee_user_status_idx ON public.issues USING btree (company_id, assignee_user_id, status);


--
-- Name: issues_company_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issues_company_created_idx ON public.issues USING btree (company_id, created_at);


--
-- Name: issues_company_execution_workspace_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issues_company_execution_workspace_idx ON public.issues USING btree (company_id, execution_workspace_id);


--
-- Name: issues_company_harness_kind_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issues_company_harness_kind_idx ON public.issues USING btree (company_id, harness_kind);


--
-- Name: issues_company_id_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX issues_company_id_uq ON public.issues USING btree (company_id, id);


--
-- Name: issues_company_monitor_due_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issues_company_monitor_due_idx ON public.issues USING btree (company_id, monitor_next_check_at);


--
-- Name: issues_company_origin_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issues_company_origin_idx ON public.issues USING btree (company_id, origin_kind, origin_id);


--
-- Name: issues_company_parent_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issues_company_parent_idx ON public.issues USING btree (company_id, parent_id);


--
-- Name: issues_company_priority_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issues_company_priority_idx ON public.issues USING btree (company_id, priority);


--
-- Name: issues_company_project_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issues_company_project_idx ON public.issues USING btree (company_id, project_id);


--
-- Name: issues_company_project_workspace_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issues_company_project_workspace_idx ON public.issues USING btree (company_id, project_workspace_id);


--
-- Name: issues_company_responsible_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issues_company_responsible_user_idx ON public.issues USING btree (company_id, responsible_user_id);


--
-- Name: issues_company_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issues_company_status_idx ON public.issues USING btree (company_id, status);


--
-- Name: issues_company_status_review_epoch_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issues_company_status_review_epoch_idx ON public.issues USING btree (company_id, status, review_epoch_id);


--
-- Name: issues_company_updated_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issues_company_updated_idx ON public.issues USING btree (company_id, updated_at);


--
-- Name: issues_conversation_identity_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX issues_conversation_identity_idx ON public.issues USING btree (company_id, conversation_agent_id, conversation_user_id);


--
-- Name: issues_description_search_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issues_description_search_idx ON public.issues USING gin (description public.gin_trgm_ops);


--
-- Name: issues_identifier_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX issues_identifier_idx ON public.issues USING btree (identifier);


--
-- Name: issues_identifier_search_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issues_identifier_search_idx ON public.issues USING gin (identifier public.gin_trgm_ops);


--
-- Name: issues_onboarding_first_task_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX issues_onboarding_first_task_uq ON public.issues USING btree (company_id) WHERE (origin_kind = 'onboarding_first_task'::text);


--
-- Name: issues_open_normalized_title_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issues_open_normalized_title_created_idx ON public.issues USING btree (company_id, parent_id, lower(regexp_replace(btrim(title), '\s+'::text, ' '::text, 'g'::text)), created_at) WHERE ((hidden_at IS NULL) AND (status <> ALL (ARRAY['done'::text, 'cancelled'::text])));


--
-- Name: issues_open_routine_execution_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX issues_open_routine_execution_uq ON public.issues USING btree (company_id, origin_kind, origin_id, origin_fingerprint) WHERE ((origin_kind = 'routine_execution'::text) AND (origin_id IS NOT NULL) AND (hidden_at IS NULL) AND (execution_run_id IS NOT NULL) AND (status = ANY (ARRAY['backlog'::text, 'todo'::text, 'in_progress'::text, 'in_review'::text, 'blocked'::text])));


--
-- Name: issues_title_search_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issues_title_search_idx ON public.issues USING gin (title public.gin_trgm_ops);


--
-- Name: join_requests_company_status_type_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX join_requests_company_status_type_created_idx ON public.join_requests USING btree (company_id, status, request_type, created_at);


--
-- Name: join_requests_invite_unique_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX join_requests_invite_unique_idx ON public.join_requests USING btree (invite_id);


--
-- Name: join_requests_pending_human_email_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX join_requests_pending_human_email_uq ON public.join_requests USING btree (company_id, lower(request_email_snapshot)) WHERE ((request_type = 'human'::text) AND (status = 'pending_approval'::text) AND (request_email_snapshot IS NOT NULL));


--
-- Name: join_requests_pending_human_user_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX join_requests_pending_human_user_uq ON public.join_requests USING btree (company_id, requesting_user_id) WHERE ((request_type = 'human'::text) AND (status = 'pending_approval'::text) AND (requesting_user_id IS NOT NULL));


--
-- Name: labels_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX labels_company_idx ON public.labels USING btree (company_id);


--
-- Name: labels_company_name_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX labels_company_name_idx ON public.labels USING btree (company_id, name);


--
-- Name: managed_agent_profiles_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX managed_agent_profiles_company_idx ON public.managed_agent_profiles USING btree (company_id);


--
-- Name: managed_agent_profiles_company_key_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX managed_agent_profiles_company_key_uq ON public.managed_agent_profiles USING btree (company_id, profile_key);


--
-- Name: managed_agent_profiles_company_resource_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX managed_agent_profiles_company_resource_uq ON public.managed_agent_profiles USING btree (company_id, anthropic_agent_id, agent_version, environment_id);


--
-- Name: native_run_finalizations_control_deadline_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX native_run_finalizations_control_deadline_idx ON public.native_run_finalizations USING btree (control_deadline_at) WHERE (control_deadline_at IS NOT NULL);


--
-- Name: native_run_results_company_issue_run_id_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX native_run_results_company_issue_run_id_uq ON public.native_run_results USING btree (company_id, issue_id, run_id, id);


--
-- Name: native_run_results_run_caller_dedupe_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX native_run_results_run_caller_dedupe_uq ON public.native_run_results USING btree (run_id, caller_dedupe_key);


--
-- Name: native_run_results_run_caller_result_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX native_run_results_run_caller_result_uq ON public.native_run_results USING btree (run_id, caller_result_id);


--
-- Name: native_run_results_run_fingerprint_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX native_run_results_run_fingerprint_uq ON public.native_run_results USING btree (run_id, server_fingerprint);


--
-- Name: pipeline_automation_executions_company_case_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pipeline_automation_executions_company_case_idx ON public.pipeline_automation_executions USING btree (company_id, case_id);


--
-- Name: pipeline_automation_executions_execution_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pipeline_automation_executions_execution_issue_idx ON public.pipeline_automation_executions USING btree (execution_issue_id);


--
-- Name: pipeline_automation_executions_idempotency_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX pipeline_automation_executions_idempotency_uq ON public.pipeline_automation_executions USING btree (case_id, automation_id, triggering_event_id);


--
-- Name: pipeline_automation_executions_retry_of_execution_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pipeline_automation_executions_retry_of_execution_idx ON public.pipeline_automation_executions USING btree (retry_of_execution_id);


--
-- Name: pipeline_automation_executions_routine_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pipeline_automation_executions_routine_idx ON public.pipeline_automation_executions USING btree (routine_id);


--
-- Name: pipeline_case_blockers_blocked_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pipeline_case_blockers_blocked_by_idx ON public.pipeline_case_blockers USING btree (blocked_by_case_id);


--
-- Name: pipeline_case_blockers_case_blocked_by_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX pipeline_case_blockers_case_blocked_by_uq ON public.pipeline_case_blockers USING btree (case_id, blocked_by_case_id);


--
-- Name: pipeline_case_blockers_company_case_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pipeline_case_blockers_company_case_idx ON public.pipeline_case_blockers USING btree (company_id, case_id);


--
-- Name: pipeline_case_documents_company_case_key_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX pipeline_case_documents_company_case_key_uq ON public.pipeline_case_documents USING btree (company_id, case_id, key);


--
-- Name: pipeline_case_documents_company_case_updated_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pipeline_case_documents_company_case_updated_idx ON public.pipeline_case_documents USING btree (company_id, case_id, updated_at);


--
-- Name: pipeline_case_documents_document_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX pipeline_case_documents_document_uq ON public.pipeline_case_documents USING btree (document_id);


--
-- Name: pipeline_case_events_case_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pipeline_case_events_case_created_idx ON public.pipeline_case_events USING btree (case_id, created_at);


--
-- Name: pipeline_case_events_company_case_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pipeline_case_events_company_case_idx ON public.pipeline_case_events USING btree (company_id, case_id);


--
-- Name: pipeline_case_issue_links_automation_attempt_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pipeline_case_issue_links_automation_attempt_idx ON public.pipeline_case_issue_links USING btree (automation_attempt_id);


--
-- Name: pipeline_case_issue_links_case_issue_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX pipeline_case_issue_links_case_issue_uq ON public.pipeline_case_issue_links USING btree (case_id, issue_id);


--
-- Name: pipeline_case_issue_links_company_case_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pipeline_case_issue_links_company_case_idx ON public.pipeline_case_issue_links USING btree (company_id, case_id);


--
-- Name: pipeline_case_issue_links_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pipeline_case_issue_links_issue_idx ON public.pipeline_case_issue_links USING btree (issue_id);


--
-- Name: pipeline_cases_automation_attempt_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pipeline_cases_automation_attempt_idx ON public.pipeline_cases USING btree (automation_attempt_id);


--
-- Name: pipeline_cases_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pipeline_cases_company_idx ON public.pipeline_cases USING btree (company_id);


--
-- Name: pipeline_cases_lease_expires_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pipeline_cases_lease_expires_idx ON public.pipeline_cases USING btree (lease_expires_at) WHERE (lease_expires_at IS NOT NULL);


--
-- Name: pipeline_cases_parent_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pipeline_cases_parent_idx ON public.pipeline_cases USING btree (parent_case_id);


--
-- Name: pipeline_cases_parent_request_key_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX pipeline_cases_parent_request_key_uq ON public.pipeline_cases USING btree (parent_case_id, request_key) WHERE ((request_key IS NOT NULL) AND (retired_at IS NULL));


--
-- Name: pipeline_cases_pipeline_case_key_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX pipeline_cases_pipeline_case_key_uq ON public.pipeline_cases USING btree (pipeline_id, case_key);


--
-- Name: pipeline_cases_pipeline_stage_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pipeline_cases_pipeline_stage_idx ON public.pipeline_cases USING btree (pipeline_id, stage_id);


--
-- Name: pipeline_cases_retired_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pipeline_cases_retired_idx ON public.pipeline_cases USING btree (company_id, retired_at);


--
-- Name: pipeline_documents_company_pipeline_key_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX pipeline_documents_company_pipeline_key_uq ON public.pipeline_documents USING btree (company_id, pipeline_id, key);


--
-- Name: pipeline_documents_company_pipeline_updated_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pipeline_documents_company_pipeline_updated_idx ON public.pipeline_documents USING btree (company_id, pipeline_id, updated_at);


--
-- Name: pipeline_documents_document_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX pipeline_documents_document_uq ON public.pipeline_documents USING btree (document_id);


--
-- Name: pipeline_stages_pipeline_key_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX pipeline_stages_pipeline_key_uq ON public.pipeline_stages USING btree (pipeline_id, key);


--
-- Name: pipeline_stages_pipeline_position_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pipeline_stages_pipeline_position_idx ON public.pipeline_stages USING btree (pipeline_id, "position");


--
-- Name: pipeline_transitions_pipeline_edge_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX pipeline_transitions_pipeline_edge_uq ON public.pipeline_transitions USING btree (pipeline_id, from_stage_id, to_stage_id);


--
-- Name: pipeline_transitions_pipeline_from_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pipeline_transitions_pipeline_from_idx ON public.pipeline_transitions USING btree (pipeline_id, from_stage_id);


--
-- Name: pipeline_transitions_pipeline_to_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pipeline_transitions_pipeline_to_idx ON public.pipeline_transitions USING btree (pipeline_id, to_stage_id);


--
-- Name: pipelines_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pipelines_company_idx ON public.pipelines USING btree (company_id);


--
-- Name: pipelines_company_key_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX pipelines_company_key_uq ON public.pipelines USING btree (company_id, key);


--
-- Name: pipelines_company_project_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pipelines_company_project_idx ON public.pipelines USING btree (company_id, project_id);


--
-- Name: plugin_company_settings_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX plugin_company_settings_company_idx ON public.plugin_company_settings USING btree (company_id);


--
-- Name: plugin_company_settings_company_plugin_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX plugin_company_settings_company_plugin_uq ON public.plugin_company_settings USING btree (company_id, plugin_id);


--
-- Name: plugin_company_settings_plugin_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX plugin_company_settings_plugin_idx ON public.plugin_company_settings USING btree (plugin_id);


--
-- Name: plugin_config_plugin_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX plugin_config_plugin_company_idx ON public.plugin_config USING btree (plugin_id, company_id);


--
-- Name: plugin_database_namespaces_namespace_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX plugin_database_namespaces_namespace_idx ON public.plugin_database_namespaces USING btree (namespace_name);


--
-- Name: plugin_database_namespaces_plugin_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX plugin_database_namespaces_plugin_idx ON public.plugin_database_namespaces USING btree (plugin_id);


--
-- Name: plugin_database_namespaces_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX plugin_database_namespaces_status_idx ON public.plugin_database_namespaces USING btree (status);


--
-- Name: plugin_entities_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX plugin_entities_company_idx ON public.plugin_entities USING btree (company_id);


--
-- Name: plugin_entities_plugin_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX plugin_entities_plugin_idx ON public.plugin_entities USING btree (plugin_id);


--
-- Name: plugin_entities_scope_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX plugin_entities_scope_idx ON public.plugin_entities USING btree (scope_kind, scope_id);


--
-- Name: plugin_entities_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX plugin_entities_type_idx ON public.plugin_entities USING btree (entity_type);


--
-- Name: plugin_job_runs_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX plugin_job_runs_company_idx ON public.plugin_job_runs USING btree (company_id);


--
-- Name: plugin_job_runs_job_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX plugin_job_runs_job_idx ON public.plugin_job_runs USING btree (job_id);


--
-- Name: plugin_job_runs_plugin_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX plugin_job_runs_plugin_idx ON public.plugin_job_runs USING btree (plugin_id);


--
-- Name: plugin_job_runs_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX plugin_job_runs_status_idx ON public.plugin_job_runs USING btree (status);


--
-- Name: plugin_jobs_next_run_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX plugin_jobs_next_run_idx ON public.plugin_jobs USING btree (next_run_at);


--
-- Name: plugin_jobs_plugin_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX plugin_jobs_plugin_idx ON public.plugin_jobs USING btree (plugin_id);


--
-- Name: plugin_jobs_unique_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX plugin_jobs_unique_idx ON public.plugin_jobs USING btree (plugin_id, job_key);


--
-- Name: plugin_logs_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX plugin_logs_company_idx ON public.plugin_logs USING btree (company_id);


--
-- Name: plugin_logs_level_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX plugin_logs_level_idx ON public.plugin_logs USING btree (level);


--
-- Name: plugin_logs_plugin_time_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX plugin_logs_plugin_time_idx ON public.plugin_logs USING btree (plugin_id, created_at);


--
-- Name: plugin_managed_resources_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX plugin_managed_resources_company_idx ON public.plugin_managed_resources USING btree (company_id);


--
-- Name: plugin_managed_resources_company_plugin_resource_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX plugin_managed_resources_company_plugin_resource_uq ON public.plugin_managed_resources USING btree (company_id, plugin_id, resource_kind, resource_key);


--
-- Name: plugin_managed_resources_plugin_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX plugin_managed_resources_plugin_idx ON public.plugin_managed_resources USING btree (plugin_id);


--
-- Name: plugin_managed_resources_resource_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX plugin_managed_resources_resource_idx ON public.plugin_managed_resources USING btree (resource_kind, resource_id);


--
-- Name: plugin_migrations_plugin_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX plugin_migrations_plugin_idx ON public.plugin_migrations USING btree (plugin_id);


--
-- Name: plugin_migrations_plugin_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX plugin_migrations_plugin_key_idx ON public.plugin_migrations USING btree (plugin_id, migration_key);


--
-- Name: plugin_migrations_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX plugin_migrations_status_idx ON public.plugin_migrations USING btree (status);


--
-- Name: plugin_state_plugin_scope_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX plugin_state_plugin_scope_idx ON public.plugin_state USING btree (plugin_id, scope_kind);


--
-- Name: plugin_webhook_deliveries_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX plugin_webhook_deliveries_company_idx ON public.plugin_webhook_deliveries USING btree (company_id);


--
-- Name: plugin_webhook_deliveries_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX plugin_webhook_deliveries_key_idx ON public.plugin_webhook_deliveries USING btree (webhook_key);


--
-- Name: plugin_webhook_deliveries_plugin_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX plugin_webhook_deliveries_plugin_idx ON public.plugin_webhook_deliveries USING btree (plugin_id);


--
-- Name: plugin_webhook_deliveries_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX plugin_webhook_deliveries_status_idx ON public.plugin_webhook_deliveries USING btree (status);


--
-- Name: plugins_plugin_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX plugins_plugin_key_idx ON public.plugins USING btree (plugin_key);


--
-- Name: plugins_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX plugins_status_idx ON public.plugins USING btree (status);


--
-- Name: principal_permission_grants_company_permission_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX principal_permission_grants_company_permission_idx ON public.principal_permission_grants USING btree (company_id, permission_key);


--
-- Name: principal_permission_grants_unique_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX principal_permission_grants_unique_idx ON public.principal_permission_grants USING btree (company_id, principal_type, principal_id, permission_key);


--
-- Name: project_goals_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX project_goals_company_idx ON public.project_goals USING btree (company_id);


--
-- Name: project_goals_goal_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX project_goals_goal_idx ON public.project_goals USING btree (goal_id);


--
-- Name: project_goals_project_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX project_goals_project_idx ON public.project_goals USING btree (project_id);


--
-- Name: project_memberships_company_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX project_memberships_company_user_idx ON public.project_memberships USING btree (company_id, user_id);


--
-- Name: project_memberships_company_user_project_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX project_memberships_company_user_project_uq ON public.project_memberships USING btree (company_id, user_id, project_id);


--
-- Name: project_memberships_company_user_starred_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX project_memberships_company_user_starred_idx ON public.project_memberships USING btree (company_id, user_id, starred_at);


--
-- Name: project_memberships_project_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX project_memberships_project_idx ON public.project_memberships USING btree (project_id);


--
-- Name: project_workspaces_company_project_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX project_workspaces_company_project_idx ON public.project_workspaces USING btree (company_id, project_id);


--
-- Name: project_workspaces_company_shared_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX project_workspaces_company_shared_key_idx ON public.project_workspaces USING btree (company_id, shared_workspace_key);


--
-- Name: project_workspaces_project_primary_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX project_workspaces_project_primary_idx ON public.project_workspaces USING btree (project_id, is_primary);


--
-- Name: project_workspaces_project_remote_ref_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX project_workspaces_project_remote_ref_idx ON public.project_workspaces USING btree (project_id, remote_provider, remote_workspace_ref);


--
-- Name: project_workspaces_project_source_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX project_workspaces_project_source_type_idx ON public.project_workspaces USING btree (project_id, source_type);


--
-- Name: projects_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX projects_company_idx ON public.projects USING btree (company_id);


--
-- Name: provider_trace_records_company_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX provider_trace_records_company_created_idx ON public.provider_trace_records USING btree (company_id, created_at);


--
-- Name: provider_trace_records_expiry_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX provider_trace_records_expiry_idx ON public.provider_trace_records USING btree (status, expires_at);


--
-- Name: provider_trace_records_run_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX provider_trace_records_run_unique ON public.provider_trace_records USING btree (run_id);


--
-- Name: remote_agent_profiles_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX remote_agent_profiles_company_idx ON public.remote_agent_profiles USING btree (company_id);


--
-- Name: remote_agent_profiles_company_key_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX remote_agent_profiles_company_key_uq ON public.remote_agent_profiles USING btree (company_id, profile_key);


--
-- Name: resource_lifecycle_events_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resource_lifecycle_events_company_idx ON public.resource_lifecycle_events USING btree (company_id, id);


--
-- Name: resource_lifecycle_events_creation_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX resource_lifecycle_events_creation_idx ON public.resource_lifecycle_events USING btree (company_id, resource_type, resource_id) WHERE (action = 'create'::text);


--
-- Name: routine_documents_company_routine_key_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX routine_documents_company_routine_key_uq ON public.routine_documents USING btree (company_id, routine_id, key);


--
-- Name: routine_documents_company_routine_updated_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX routine_documents_company_routine_updated_idx ON public.routine_documents USING btree (company_id, routine_id, updated_at);


--
-- Name: routine_documents_document_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX routine_documents_document_uq ON public.routine_documents USING btree (document_id);


--
-- Name: routine_revisions_company_responsible_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX routine_revisions_company_responsible_user_idx ON public.routine_revisions USING btree (company_id, responsible_user_id, created_at);


--
-- Name: routine_revisions_company_routine_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX routine_revisions_company_routine_created_idx ON public.routine_revisions USING btree (company_id, routine_id, created_at);


--
-- Name: routine_revisions_routine_revision_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX routine_revisions_routine_revision_uq ON public.routine_revisions USING btree (routine_id, revision_number);


--
-- Name: routine_runs_company_responsible_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX routine_runs_company_responsible_user_idx ON public.routine_runs USING btree (company_id, responsible_user_id, created_at);


--
-- Name: routine_runs_company_routine_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX routine_runs_company_routine_idx ON public.routine_runs USING btree (company_id, routine_id, created_at);


--
-- Name: routine_runs_dispatch_fingerprint_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX routine_runs_dispatch_fingerprint_idx ON public.routine_runs USING btree (routine_id, dispatch_fingerprint);


--
-- Name: routine_runs_linked_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX routine_runs_linked_issue_idx ON public.routine_runs USING btree (linked_issue_id);


--
-- Name: routine_runs_revision_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX routine_runs_revision_idx ON public.routine_runs USING btree (routine_revision_id);


--
-- Name: routine_runs_trigger_idempotency_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX routine_runs_trigger_idempotency_idx ON public.routine_runs USING btree (trigger_id, idempotency_key);


--
-- Name: routine_runs_trigger_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX routine_runs_trigger_idx ON public.routine_runs USING btree (trigger_id, created_at);


--
-- Name: routine_triggers_company_kind_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX routine_triggers_company_kind_idx ON public.routine_triggers USING btree (company_id, kind);


--
-- Name: routine_triggers_company_routine_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX routine_triggers_company_routine_idx ON public.routine_triggers USING btree (company_id, routine_id);


--
-- Name: routine_triggers_next_run_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX routine_triggers_next_run_idx ON public.routine_triggers USING btree (next_run_at);


--
-- Name: routine_triggers_public_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX routine_triggers_public_id_idx ON public.routine_triggers USING btree (public_id);


--
-- Name: routine_triggers_public_id_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX routine_triggers_public_id_uq ON public.routine_triggers USING btree (public_id);


--
-- Name: routine_webhook_test_receipts_delivery_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX routine_webhook_test_receipts_delivery_uq ON public.routine_webhook_test_receipts USING btree (trigger_id, delivery_key_hash);


--
-- Name: routines_company_assignee_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX routines_company_assignee_idx ON public.routines USING btree (company_id, assignee_agent_id);


--
-- Name: routines_company_folder_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX routines_company_folder_idx ON public.routines USING btree (company_id, folder_id);


--
-- Name: routines_company_origin_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX routines_company_origin_idx ON public.routines USING btree (company_id, origin_kind, origin_id);


--
-- Name: routines_company_project_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX routines_company_project_idx ON public.routines USING btree (company_id, project_id);


--
-- Name: routines_company_responsible_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX routines_company_responsible_user_idx ON public.routines USING btree (company_id, responsible_user_id);


--
-- Name: routines_company_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX routines_company_status_idx ON public.routines USING btree (company_id, status);


--
-- Name: run_identity_contexts_company_run_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX run_identity_contexts_company_run_idx ON public.run_identity_contexts USING btree (company_id, run_id);


--
-- Name: run_identity_contexts_run_correlation_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX run_identity_contexts_run_correlation_idx ON public.run_identity_contexts USING btree (run_id, correlation_id);


--
-- Name: run_identity_contexts_run_revision_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX run_identity_contexts_run_revision_idx ON public.run_identity_contexts USING btree (run_id, revision);


--
-- Name: runner_api_response_reservations_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX runner_api_response_reservations_company_idx ON public.runner_api_response_reservations USING btree (company_id);


--
-- Name: secret_access_events_company_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX secret_access_events_company_created_idx ON public.secret_access_events USING btree (company_id, created_at);


--
-- Name: secret_access_events_company_credential_owner_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX secret_access_events_company_credential_owner_idx ON public.secret_access_events USING btree (company_id, credential_owner_user_id, created_at);


--
-- Name: secret_access_events_consumer_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX secret_access_events_consumer_idx ON public.secret_access_events USING btree (company_id, consumer_type, consumer_id);


--
-- Name: secret_access_events_run_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX secret_access_events_run_idx ON public.secret_access_events USING btree (heartbeat_run_id);


--
-- Name: secret_access_events_secret_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX secret_access_events_secret_created_idx ON public.secret_access_events USING btree (secret_id, created_at);


--
-- Name: secret_access_events_user_definition_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX secret_access_events_user_definition_created_idx ON public.secret_access_events USING btree (user_secret_definition_id, created_at);


--
-- Name: smoke_run_steps_company_path_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX smoke_run_steps_company_path_idx ON public.smoke_run_steps USING btree (company_id, path);


--
-- Name: smoke_run_steps_company_run_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX smoke_run_steps_company_run_idx ON public.smoke_run_steps USING btree (company_id, run_id);


--
-- Name: smoke_runs_company_started_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX smoke_runs_company_started_idx ON public.smoke_runs USING btree (company_id, started_at);


--
-- Name: smoke_runs_company_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX smoke_runs_company_status_idx ON public.smoke_runs USING btree (company_id, status);


--
-- Name: status_card_updates_card_started_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX status_card_updates_card_started_idx ON public.status_card_updates USING btree (card_id, started_at);


--
-- Name: status_card_updates_generation_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX status_card_updates_generation_issue_idx ON public.status_card_updates USING btree (generation_issue_id);


--
-- Name: status_cards_company_archived_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX status_cards_company_archived_idx ON public.status_cards USING btree (company_id, archived_at);


--
-- Name: status_cards_company_next_eval_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX status_cards_company_next_eval_idx ON public.status_cards USING btree (company_id, next_eval_at);


--
-- Name: status_decision_effects_company_idempotency_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX status_decision_effects_company_idempotency_uq ON public.status_decision_effects USING btree (company_id, idempotency_key);


--
-- Name: status_decision_effects_decision_ordinal_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX status_decision_effects_decision_ordinal_uq ON public.status_decision_effects USING btree (decision_id, ordinal);


--
-- Name: status_decisions_company_assessment_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX status_decisions_company_assessment_uq ON public.status_decisions USING btree (company_id, assessment_id);


--
-- Name: status_decisions_company_issue_digest_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX status_decisions_company_issue_digest_uq ON public.status_decisions USING btree (company_id, issue_id, decision_digest);


--
-- Name: status_decisions_company_issue_id_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX status_decisions_company_issue_id_uq ON public.status_decisions USING btree (company_id, issue_id, id);


--
-- Name: status_decisions_company_issue_run_assessment_id_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX status_decisions_company_issue_run_assessment_id_uq ON public.status_decisions USING btree (company_id, issue_id, run_id, assessment_id, id);


--
-- Name: status_decisions_company_issue_version_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX status_decisions_company_issue_version_uq ON public.status_decisions USING btree (company_id, issue_id, decision_version);


--
-- Name: summary_slots_company_generating_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX summary_slots_company_generating_issue_idx ON public.summary_slots USING btree (company_id, generating_issue_id);


--
-- Name: summary_slots_company_scope_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX summary_slots_company_scope_idx ON public.summary_slots USING btree (company_id, scope_kind, scope_id);


--
-- Name: summary_slots_company_updated_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX summary_slots_company_updated_idx ON public.summary_slots USING btree (company_id, updated_at);


--
-- Name: summary_slots_document_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX summary_slots_document_uq ON public.summary_slots USING btree (document_id);


--
-- Name: tool_access_audit_company_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_access_audit_company_created_idx ON public.tool_access_audit_events USING btree (company_id, created_at);


--
-- Name: tool_access_audit_connection_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_access_audit_connection_idx ON public.tool_access_audit_events USING btree (connection_id);


--
-- Name: tool_access_audit_gateway_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_access_audit_gateway_idx ON public.tool_access_audit_events USING btree (company_id, gateway_id);


--
-- Name: tool_action_deliveries_pending_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_action_deliveries_pending_idx ON public.tool_action_deliveries USING btree (delivered_at, created_at);


--
-- Name: tool_action_requests_company_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_action_requests_company_status_idx ON public.tool_action_requests USING btree (company_id, status);


--
-- Name: tool_action_requests_invocation_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_action_requests_invocation_idx ON public.tool_action_requests USING btree (invocation_id);


--
-- Name: tool_action_requests_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_action_requests_issue_idx ON public.tool_action_requests USING btree (company_id, issue_id);


--
-- Name: tool_applications_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_applications_company_idx ON public.tool_applications USING btree (company_id);


--
-- Name: tool_applications_company_key_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX tool_applications_company_key_uq ON public.tool_applications USING btree (company_id, application_key);


--
-- Name: tool_applications_company_name_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX tool_applications_company_name_uq ON public.tool_applications USING btree (company_id, name);


--
-- Name: tool_applications_company_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_applications_company_status_idx ON public.tool_applications USING btree (company_id, status);


--
-- Name: tool_call_events_company_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_call_events_company_created_idx ON public.tool_call_events USING btree (company_id, created_at);


--
-- Name: tool_call_events_gateway_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_call_events_gateway_idx ON public.tool_call_events USING btree (company_id, gateway_id);


--
-- Name: tool_call_events_invocation_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_call_events_invocation_idx ON public.tool_call_events USING btree (invocation_id);


--
-- Name: tool_call_events_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_call_events_issue_idx ON public.tool_call_events USING btree (company_id, issue_id);


--
-- Name: tool_call_events_run_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_call_events_run_idx ON public.tool_call_events USING btree (company_id, run_id);


--
-- Name: tool_catalog_entries_application_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_catalog_entries_application_idx ON public.tool_catalog_entries USING btree (application_id);


--
-- Name: tool_catalog_entries_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_catalog_entries_company_idx ON public.tool_catalog_entries USING btree (company_id);


--
-- Name: tool_catalog_entries_company_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_catalog_entries_company_status_idx ON public.tool_catalog_entries USING btree (company_id, status);


--
-- Name: tool_catalog_entries_connection_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_catalog_entries_connection_idx ON public.tool_catalog_entries USING btree (connection_id);


--
-- Name: tool_catalog_entries_connection_name_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX tool_catalog_entries_connection_name_uq ON public.tool_catalog_entries USING btree (connection_id, name);


--
-- Name: tool_connection_app_snapshots_owner_toolkit_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX tool_connection_app_snapshots_owner_toolkit_uq ON public.tool_connection_app_snapshots USING btree (company_id, connection_id, user_id, toolkit);


--
-- Name: tool_connection_app_syncs_owner_key_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX tool_connection_app_syncs_owner_key_uq ON public.tool_connection_app_syncs USING btree (company_id, connection_id, user_id, credential_key);


--
-- Name: tool_connection_installs_company_target_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_connection_installs_company_target_idx ON public.tool_connection_installs USING btree (company_id, target_type, target_id);


--
-- Name: tool_connection_installs_connection_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_connection_installs_connection_idx ON public.tool_connection_installs USING btree (company_id, connection_id);


--
-- Name: tool_connection_installs_target_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX tool_connection_installs_target_uq ON public.tool_connection_installs USING btree (company_id, connection_id, target_type, target_id);


--
-- Name: tool_connections_application_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_connections_application_idx ON public.tool_connections USING btree (application_id);


--
-- Name: tool_connections_company_enabled_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_connections_company_enabled_idx ON public.tool_connections USING btree (company_id, enabled);


--
-- Name: tool_connections_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_connections_company_idx ON public.tool_connections USING btree (company_id);


--
-- Name: tool_connections_company_uid_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX tool_connections_company_uid_uq ON public.tool_connections USING btree (company_id, uid);


--
-- Name: tool_gateway_rate_limit_counters_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_gateway_rate_limit_counters_company_idx ON public.tool_gateway_rate_limit_counters USING btree (company_id);


--
-- Name: tool_gateway_rate_limit_counters_window_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX tool_gateway_rate_limit_counters_window_uq ON public.tool_gateway_rate_limit_counters USING btree (company_id, counter_key, window_start_at);


--
-- Name: tool_gateway_sessions_company_agent_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_gateway_sessions_company_agent_idx ON public.tool_gateway_sessions USING btree (company_id, agent_id);


--
-- Name: tool_gateway_sessions_company_expires_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_gateway_sessions_company_expires_idx ON public.tool_gateway_sessions USING btree (company_id, expires_at);


--
-- Name: tool_gateway_sessions_gateway_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_gateway_sessions_gateway_idx ON public.tool_gateway_sessions USING btree (company_id, gateway_id);


--
-- Name: tool_gateway_sessions_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_gateway_sessions_issue_idx ON public.tool_gateway_sessions USING btree (company_id, issue_id);


--
-- Name: tool_gateway_sessions_run_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_gateway_sessions_run_idx ON public.tool_gateway_sessions USING btree (company_id, run_id);


--
-- Name: tool_gateway_sessions_token_hash_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX tool_gateway_sessions_token_hash_uq ON public.tool_gateway_sessions USING btree (token_hash);


--
-- Name: tool_invocations_company_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_invocations_company_created_idx ON public.tool_invocations USING btree (company_id, created_at);


--
-- Name: tool_invocations_company_idempotency_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX tool_invocations_company_idempotency_uq ON public.tool_invocations USING btree (company_id, idempotency_key);


--
-- Name: tool_invocations_gateway_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_invocations_gateway_idx ON public.tool_invocations USING btree (company_id, gateway_id);


--
-- Name: tool_invocations_issue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_invocations_issue_idx ON public.tool_invocations USING btree (company_id, issue_id);


--
-- Name: tool_invocations_run_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_invocations_run_idx ON public.tool_invocations USING btree (company_id, run_id);


--
-- Name: tool_mcp_gateway_tokens_company_expires_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_mcp_gateway_tokens_company_expires_idx ON public.tool_mcp_gateway_tokens USING btree (company_id, expires_at);


--
-- Name: tool_mcp_gateway_tokens_expiry_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_mcp_gateway_tokens_expiry_idx ON public.tool_mcp_gateway_tokens USING btree (expires_at, id);


--
-- Name: tool_mcp_gateway_tokens_gateway_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_mcp_gateway_tokens_gateway_idx ON public.tool_mcp_gateway_tokens USING btree (company_id, gateway_id);


--
-- Name: tool_mcp_gateway_tokens_subject_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_mcp_gateway_tokens_subject_idx ON public.tool_mcp_gateway_tokens USING btree (company_id, subject_type, subject_id);


--
-- Name: tool_mcp_gateway_tokens_token_hash_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX tool_mcp_gateway_tokens_token_hash_uq ON public.tool_mcp_gateway_tokens USING btree (token_hash);


--
-- Name: tool_mcp_gateways_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_mcp_gateways_company_idx ON public.tool_mcp_gateways USING btree (company_id);


--
-- Name: tool_mcp_gateways_company_name_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX tool_mcp_gateways_company_name_uq ON public.tool_mcp_gateways USING btree (company_id, name);


--
-- Name: tool_mcp_gateways_company_slug_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX tool_mcp_gateways_company_slug_uq ON public.tool_mcp_gateways USING btree (company_id, slug);


--
-- Name: tool_mcp_gateways_company_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_mcp_gateways_company_status_idx ON public.tool_mcp_gateways USING btree (company_id, status);


--
-- Name: tool_mcp_gateways_profile_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_mcp_gateways_profile_idx ON public.tool_mcp_gateways USING btree (company_id, profile_id);


--
-- Name: tool_mcp_gateways_public_id_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX tool_mcp_gateways_public_id_uq ON public.tool_mcp_gateways USING btree (gateway_public_id);


--
-- Name: tool_oauth_states_actor_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_oauth_states_actor_idx ON public.tool_oauth_states USING btree (created_by_actor_type, created_by_actor_id);


--
-- Name: tool_oauth_states_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_oauth_states_company_idx ON public.tool_oauth_states USING btree (company_id);


--
-- Name: tool_oauth_states_connection_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_oauth_states_connection_idx ON public.tool_oauth_states USING btree (connection_id);


--
-- Name: tool_oauth_states_expires_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_oauth_states_expires_at_idx ON public.tool_oauth_states USING btree (expires_at);


--
-- Name: tool_oauth_states_subject_agent_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_oauth_states_subject_agent_idx ON public.tool_oauth_states USING btree (company_id, subject_agent_id);


--
-- Name: tool_oauth_states_subject_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_oauth_states_subject_user_idx ON public.tool_oauth_states USING btree (company_id, subject_user_id);


--
-- Name: tool_policies_company_enabled_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_policies_company_enabled_idx ON public.tool_policies USING btree (company_id, enabled);


--
-- Name: tool_policies_company_name_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX tool_policies_company_name_uq ON public.tool_policies USING btree (company_id, name);


--
-- Name: tool_policies_company_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_policies_company_type_idx ON public.tool_policies USING btree (company_id, policy_type);


--
-- Name: tool_profile_bindings_company_target_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_profile_bindings_company_target_idx ON public.tool_profile_bindings USING btree (company_id, target_type, target_id);


--
-- Name: tool_profile_bindings_target_profile_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX tool_profile_bindings_target_profile_uq ON public.tool_profile_bindings USING btree (company_id, target_type, target_id, profile_id);


--
-- Name: tool_profile_entries_application_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_profile_entries_application_idx ON public.tool_profile_entries USING btree (company_id, application_id);


--
-- Name: tool_profile_entries_catalog_entry_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_profile_entries_catalog_entry_idx ON public.tool_profile_entries USING btree (company_id, catalog_entry_id);


--
-- Name: tool_profile_entries_company_profile_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_profile_entries_company_profile_idx ON public.tool_profile_entries USING btree (company_id, profile_id);


--
-- Name: tool_profile_entries_connection_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_profile_entries_connection_idx ON public.tool_profile_entries USING btree (company_id, connection_id);


--
-- Name: tool_profiles_company_key_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX tool_profiles_company_key_uq ON public.tool_profiles USING btree (company_id, profile_key);


--
-- Name: tool_profiles_company_name_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX tool_profiles_company_name_uq ON public.tool_profiles USING btree (company_id, name);


--
-- Name: tool_profiles_company_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_profiles_company_status_idx ON public.tool_profiles USING btree (company_id, status);


--
-- Name: tool_rate_limit_counters_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_rate_limit_counters_company_idx ON public.tool_rate_limit_counters USING btree (company_id);


--
-- Name: tool_rate_limit_counters_window_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX tool_rate_limit_counters_window_uq ON public.tool_rate_limit_counters USING btree (company_id, policy_id, counter_key, window_kind, window_start_at);


--
-- Name: tool_runtime_metric_counters_bucket_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX tool_runtime_metric_counters_bucket_uq ON public.tool_runtime_metric_counters USING btree (company_id, metric, bucket_start_at);


--
-- Name: tool_runtime_metric_counters_company_metric_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_runtime_metric_counters_company_metric_idx ON public.tool_runtime_metric_counters USING btree (company_id, metric, bucket_start_at);


--
-- Name: tool_runtime_slots_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_runtime_slots_company_idx ON public.tool_runtime_slots USING btree (company_id);


--
-- Name: tool_runtime_slots_connection_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_runtime_slots_connection_idx ON public.tool_runtime_slots USING btree (connection_id);


--
-- Name: tool_runtime_slots_execution_workspace_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_runtime_slots_execution_workspace_idx ON public.tool_runtime_slots USING btree (company_id, execution_workspace_id);


--
-- Name: tool_runtime_slots_slot_key_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX tool_runtime_slots_slot_key_uq ON public.tool_runtime_slots USING btree (company_id, slot_key);


--
-- Name: tool_stdio_command_templates_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_stdio_command_templates_company_idx ON public.tool_stdio_command_templates USING btree (company_id);


--
-- Name: tool_stdio_command_templates_company_key_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX tool_stdio_command_templates_company_key_uq ON public.tool_stdio_command_templates USING btree (company_id, template_key);


--
-- Name: tool_stdio_command_templates_company_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_stdio_command_templates_company_status_idx ON public.tool_stdio_command_templates USING btree (company_id, status);


--
-- Name: user_inbox_agent_policies_allowed_agent_ids_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_inbox_agent_policies_allowed_agent_ids_idx ON public.user_inbox_agent_policies USING gin (allowed_agent_ids);


--
-- Name: user_inbox_agent_policies_company_user_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_inbox_agent_policies_company_user_uq ON public.user_inbox_agent_policies USING btree (company_id, user_id);


--
-- Name: user_secret_declarations_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_secret_declarations_company_idx ON public.user_secret_declarations USING btree (company_id);


--
-- Name: user_secret_declarations_company_required_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_secret_declarations_company_required_idx ON public.user_secret_declarations USING btree (company_id, required);


--
-- Name: user_secret_declarations_definition_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_secret_declarations_definition_idx ON public.user_secret_declarations USING btree (user_secret_definition_id);


--
-- Name: user_secret_declarations_required_override_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_secret_declarations_required_override_idx ON public.user_secret_declarations USING btree (company_id, allow_missing_override) WHERE (allow_missing_override = true);


--
-- Name: user_secret_declarations_target_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_secret_declarations_target_idx ON public.user_secret_declarations USING btree (company_id, target_type, target_id);


--
-- Name: user_secret_declarations_target_path_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_secret_declarations_target_path_uq ON public.user_secret_declarations USING btree (company_id, target_type, target_id, config_path);


--
-- Name: user_secret_definitions_company_key_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_secret_definitions_company_key_uq ON public.user_secret_definitions USING btree (company_id, key) WHERE (deleted_at IS NULL);


--
-- Name: user_secret_definitions_company_provider_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_secret_definitions_company_provider_idx ON public.user_secret_definitions USING btree (company_id, provider);


--
-- Name: user_secret_definitions_company_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_secret_definitions_company_status_idx ON public.user_secret_definitions USING btree (company_id, status);


--
-- Name: user_secret_definitions_provider_config_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_secret_definitions_provider_config_idx ON public.user_secret_definitions USING btree (provider_config_id);


--
-- Name: user_sidebar_preferences_user_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_sidebar_preferences_user_uq ON public.user_sidebar_preferences USING btree (user_id);


--
-- Name: work_assessments_company_issue_input_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX work_assessments_company_issue_input_uq ON public.work_assessments USING btree (company_id, issue_id, input_digest);


--
-- Name: work_assessments_company_issue_run_id_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX work_assessments_company_issue_run_id_uq ON public.work_assessments USING btree (company_id, issue_id, run_id, id);


--
-- Name: workspace_operations_company_run_started_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX workspace_operations_company_run_started_idx ON public.workspace_operations USING btree (company_id, heartbeat_run_id, started_at);


--
-- Name: workspace_operations_company_workspace_issue_started_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX workspace_operations_company_workspace_issue_started_idx ON public.workspace_operations USING btree (company_id, execution_workspace_id, issue_id, started_at);


--
-- Name: workspace_operations_company_workspace_started_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX workspace_operations_company_workspace_started_idx ON public.workspace_operations USING btree (company_id, execution_workspace_id, started_at);


--
-- Name: workspace_runtime_services_company_execution_workspace_status_i; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX workspace_runtime_services_company_execution_workspace_status_i ON public.workspace_runtime_services USING btree (company_id, execution_workspace_id, status);


--
-- Name: workspace_runtime_services_company_project_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX workspace_runtime_services_company_project_status_idx ON public.workspace_runtime_services USING btree (company_id, project_id, status);


--
-- Name: workspace_runtime_services_company_updated_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX workspace_runtime_services_company_updated_idx ON public.workspace_runtime_services USING btree (company_id, updated_at);


--
-- Name: workspace_runtime_services_company_workspace_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX workspace_runtime_services_company_workspace_status_idx ON public.workspace_runtime_services USING btree (company_id, project_workspace_id, status);


--
-- Name: workspace_runtime_services_run_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX workspace_runtime_services_run_idx ON public.workspace_runtime_services USING btree (started_by_run_id);


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
-- Name: agents agents_cleanup_inbox_policy_allowlists; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER agents_cleanup_inbox_policy_allowlists AFTER DELETE ON public.agents FOR EACH ROW EXECUTE FUNCTION public.remove_deleted_agent_from_inbox_policy_allowlists();


--
-- Name: ai_connection_defaults ai_connection_defaults_sync_provider; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ai_connection_defaults_sync_provider AFTER INSERT OR UPDATE OF grant_id, updated_at ON public.ai_connection_defaults FOR EACH ROW EXECUTE FUNCTION public.sync_ai_provider_default();


--
-- Name: company_secret_versions company_secret_versions_fingerprint_compat_trg; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER company_secret_versions_fingerprint_compat_trg BEFORE INSERT OR UPDATE OF value_sha256, fingerprint_sha256 ON public.company_secret_versions FOR EACH ROW EXECUTE FUNCTION public.paperclip_company_secret_versions_fingerprint_compat();


--
-- Name: company_secrets company_secrets_key_compat_trg; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER company_secrets_key_compat_trg BEFORE INSERT OR UPDATE OF name, key ON public.company_secrets FOR EACH ROW EXECUTE FUNCTION public.paperclip_company_secrets_key_compat();


--
-- Name: issues paperclip_issue_status_version_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER paperclip_issue_status_version_trigger BEFORE UPDATE OF status ON public.issues FOR EACH ROW EXECUTE FUNCTION public.paperclip_bump_issue_status_version();


--
-- Name: documents paperclip_temp_guard_stale_review_wait_documents_insert_2026071; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER paperclip_temp_guard_stale_review_wait_documents_insert_2026071 BEFORE INSERT ON public.documents FOR EACH ROW EXECUTE FUNCTION public.paperclip_temp_guard_stale_review_wait_20260717();


--
-- Name: documents paperclip_temp_guard_stale_review_wait_documents_update_2026071; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER paperclip_temp_guard_stale_review_wait_documents_update_2026071 BEFORE UPDATE OF latest_body, title ON public.documents FOR EACH ROW EXECUTE FUNCTION public.paperclip_temp_guard_stale_review_wait_20260717();


--
-- Name: document_revisions paperclip_temp_guard_stale_review_wait_revisions_insert_2026071; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER paperclip_temp_guard_stale_review_wait_revisions_insert_2026071 BEFORE INSERT ON public.document_revisions FOR EACH ROW EXECUTE FUNCTION public.paperclip_temp_guard_stale_review_wait_20260717();


--
-- Name: issues trg_freeze_reva29375_no_agent_exec_ins; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_freeze_reva29375_no_agent_exec_ins BEFORE INSERT ON public.issues FOR EACH ROW WHEN (((new.project_id = 'd15b63fa-3217-42bd-ab20-256916af2374'::uuid) AND (new.created_by_agent_id IS NOT NULL) AND (new.origin_kind = 'manual'::text) AND ((new.assignee_agent_id IS NOT NULL) OR (new.execution_run_id IS NOT NULL) OR (new.checkout_run_id IS NOT NULL)))) EXECUTE FUNCTION public.freeze_reva29375_block_agent_execution();


--
-- Name: issues trg_freeze_reva29375_no_agent_exec_upd; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_freeze_reva29375_no_agent_exec_upd BEFORE UPDATE ON public.issues FOR EACH ROW WHEN (((new.project_id = 'd15b63fa-3217-42bd-ab20-256916af2374'::uuid) AND (new.origin_kind = 'manual'::text) AND (((old.assignee_agent_id IS NULL) AND (new.assignee_agent_id IS NOT NULL)) OR ((old.execution_run_id IS NULL) AND (new.execution_run_id IS NOT NULL)) OR ((old.checkout_run_id IS NULL) AND (new.checkout_run_id IS NOT NULL))))) EXECUTE FUNCTION public.freeze_reva29375_block_agent_execution();


--
-- Name: audit_chain audit_chain_append_only; Type: TRIGGER; Schema: uplift; Owner: -
--

CREATE TRIGGER audit_chain_append_only BEFORE DELETE OR UPDATE ON uplift.audit_chain FOR EACH ROW EXECUTE FUNCTION uplift.audit_chain_guard();


--
-- Name: account account_user_id_user_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_user_id_user_id_fk FOREIGN KEY (user_id) REFERENCES public."user"(id) ON DELETE CASCADE NOT VALID;


--
-- Name: activity_log activity_log_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_log
    ADD CONSTRAINT activity_log_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES public.agents(id) NOT VALID;


--
-- Name: activity_log activity_log_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_log
    ADD CONSTRAINT activity_log_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: activity_log activity_log_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_log
    ADD CONSTRAINT activity_log_run_id_heartbeat_runs_id_fk FOREIGN KEY (run_id) REFERENCES public.heartbeat_runs(id) NOT VALID;


--
-- Name: adapter_auth_sessions adapter_auth_sessions_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.adapter_auth_sessions
    ADD CONSTRAINT adapter_auth_sessions_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: adapter_auth_sessions adapter_auth_sessions_environment_id_environments_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.adapter_auth_sessions
    ADD CONSTRAINT adapter_auth_sessions_environment_id_environments_id_fk FOREIGN KEY (environment_id) REFERENCES public.environments(id) ON DELETE CASCADE;


--
-- Name: agent_api_keys agent_api_keys_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_api_keys
    ADD CONSTRAINT agent_api_keys_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES public.agents(id) NOT VALID;


--
-- Name: agent_api_keys agent_api_keys_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_api_keys
    ADD CONSTRAINT agent_api_keys_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: agent_config_revisions agent_config_revisions_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_config_revisions
    ADD CONSTRAINT agent_config_revisions_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES public.agents(id) ON DELETE CASCADE NOT VALID;


--
-- Name: agent_config_revisions agent_config_revisions_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_config_revisions
    ADD CONSTRAINT agent_config_revisions_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: agent_config_revisions agent_config_revisions_created_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_config_revisions
    ADD CONSTRAINT agent_config_revisions_created_by_agent_id_agents_id_fk FOREIGN KEY (created_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL NOT VALID;


--
-- Name: agent_instruction_heads agent_instruction_heads_company_id_agent_id_entry_file_revision; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_instruction_heads
    ADD CONSTRAINT agent_instruction_heads_company_id_agent_id_entry_file_revision FOREIGN KEY (company_id, agent_id, entry_file, revision_id) REFERENCES public.agent_instruction_revisions(company_id, agent_id, entry_file, id) ON DELETE CASCADE;


--
-- Name: agent_instruction_revisions agent_instruction_revisions_company_id_agent_id_agents_company_; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_instruction_revisions
    ADD CONSTRAINT agent_instruction_revisions_company_id_agent_id_agents_company_ FOREIGN KEY (company_id, agent_id) REFERENCES public.agents(company_id, id) ON DELETE CASCADE;


--
-- Name: agent_instruction_working_copies agent_instruction_working_copies_company_id_agent_id_agents_com; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_instruction_working_copies
    ADD CONSTRAINT agent_instruction_working_copies_company_id_agent_id_agents_com FOREIGN KEY (company_id, agent_id) REFERENCES public.agents(company_id, id) ON DELETE CASCADE;


--
-- Name: agent_instruction_working_copies agent_instruction_working_copies_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_instruction_working_copies
    ADD CONSTRAINT agent_instruction_working_copies_run_id_heartbeat_runs_id_fk FOREIGN KEY (run_id) REFERENCES public.heartbeat_runs(id) ON DELETE CASCADE;


--
-- Name: agent_memberships agent_memberships_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_memberships
    ADD CONSTRAINT agent_memberships_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES public.agents(id) ON DELETE CASCADE;


--
-- Name: agent_memberships agent_memberships_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_memberships
    ADD CONSTRAINT agent_memberships_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: agent_runtime_state agent_runtime_state_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_runtime_state
    ADD CONSTRAINT agent_runtime_state_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES public.agents(id) NOT VALID;


--
-- Name: agent_runtime_state agent_runtime_state_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_runtime_state
    ADD CONSTRAINT agent_runtime_state_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: agent_session_goal_actions agent_session_goal_actions_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_session_goal_actions
    ADD CONSTRAINT agent_session_goal_actions_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: agent_session_goal_actions agent_session_goal_actions_session_id_agent_task_sessions_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_session_goal_actions
    ADD CONSTRAINT agent_session_goal_actions_session_id_agent_task_sessions_id_fk FOREIGN KEY (session_id) REFERENCES public.agent_task_sessions(id) ON DELETE CASCADE;


--
-- Name: agent_task_sessions agent_task_sessions_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_task_sessions
    ADD CONSTRAINT agent_task_sessions_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES public.agents(id) NOT VALID;


--
-- Name: agent_task_sessions agent_task_sessions_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_task_sessions
    ADD CONSTRAINT agent_task_sessions_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: agent_task_sessions agent_task_sessions_last_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_task_sessions
    ADD CONSTRAINT agent_task_sessions_last_run_id_heartbeat_runs_id_fk FOREIGN KEY (last_run_id) REFERENCES public.heartbeat_runs(id) NOT VALID;


--
-- Name: agent_wakeup_requests agent_wakeup_requests_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_wakeup_requests
    ADD CONSTRAINT agent_wakeup_requests_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES public.agents(id) NOT VALID;


--
-- Name: agent_wakeup_requests agent_wakeup_requests_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_wakeup_requests
    ADD CONSTRAINT agent_wakeup_requests_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: agents agents_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agents
    ADD CONSTRAINT agents_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: agents agents_default_environment_id_environments_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agents
    ADD CONSTRAINT agents_default_environment_id_environments_id_fk FOREIGN KEY (default_environment_id) REFERENCES public.environments(id) ON DELETE SET NULL NOT VALID;


--
-- Name: agents agents_reports_to_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agents
    ADD CONSTRAINT agents_reports_to_agents_id_fk FOREIGN KEY (reports_to) REFERENCES public.agents(id) NOT VALID;


--
-- Name: ai_connection_defaults ai_connection_defaults_company_grant_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_connection_defaults
    ADD CONSTRAINT ai_connection_defaults_company_grant_fk FOREIGN KEY (company_id, grant_id) REFERENCES public.connection_grants(company_id, id);


--
-- Name: ai_connection_defaults ai_connection_defaults_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_connection_defaults
    ADD CONSTRAINT ai_connection_defaults_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: ai_connection_pools ai_connection_pools_company_connection_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_connection_pools
    ADD CONSTRAINT ai_connection_pools_company_connection_fk FOREIGN KEY (company_id, id) REFERENCES public.tool_connections(company_id, id) ON DELETE CASCADE;


--
-- Name: ai_connection_pools ai_connection_pools_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_connection_pools
    ADD CONSTRAINT ai_connection_pools_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: ai_connection_pools ai_connection_pools_id_tool_connections_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_connection_pools
    ADD CONSTRAINT ai_connection_pools_id_tool_connections_id_fk FOREIGN KEY (id) REFERENCES public.tool_connections(id) ON DELETE CASCADE;


--
-- Name: ai_connection_router_cursors ai_connection_router_cursors_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_connection_router_cursors
    ADD CONSTRAINT ai_connection_router_cursors_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: ai_connection_router_cursors ai_connection_router_cursors_company_pool_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_connection_router_cursors
    ADD CONSTRAINT ai_connection_router_cursors_company_pool_fk FOREIGN KEY (company_id, pool_id) REFERENCES public.ai_connection_pools(company_id, id) ON DELETE CASCADE;


--
-- Name: ai_connection_router_cursors ai_connection_router_cursors_pool_id_ai_connection_pools_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_connection_router_cursors
    ADD CONSTRAINT ai_connection_router_cursors_pool_id_ai_connection_pools_id_fk FOREIGN KEY (pool_id) REFERENCES public.ai_connection_pools(id) ON DELETE CASCADE;


--
-- Name: ai_connection_task_pins ai_connection_task_pins_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_connection_task_pins
    ADD CONSTRAINT ai_connection_task_pins_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES public.agents(id) ON DELETE CASCADE;


--
-- Name: ai_connection_task_pins ai_connection_task_pins_company_agent_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_connection_task_pins
    ADD CONSTRAINT ai_connection_task_pins_company_agent_fk FOREIGN KEY (company_id, agent_id) REFERENCES public.agents(company_id, id) ON DELETE CASCADE;


--
-- Name: ai_connection_task_pins ai_connection_task_pins_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_connection_task_pins
    ADD CONSTRAINT ai_connection_task_pins_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: ai_connection_task_pins ai_connection_task_pins_company_pool_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_connection_task_pins
    ADD CONSTRAINT ai_connection_task_pins_company_pool_fk FOREIGN KEY (company_id, pool_id) REFERENCES public.ai_connection_pools(company_id, id) ON DELETE CASCADE;


--
-- Name: ai_connection_task_pins ai_connection_task_pins_pool_id_ai_connection_pools_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_connection_task_pins
    ADD CONSTRAINT ai_connection_task_pins_pool_id_ai_connection_pools_id_fk FOREIGN KEY (pool_id) REFERENCES public.ai_connection_pools(id) ON DELETE CASCADE;


--
-- Name: ai_provider_defaults ai_provider_defaults_company_grant_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_provider_defaults
    ADD CONSTRAINT ai_provider_defaults_company_grant_fk FOREIGN KEY (company_id, grant_id) REFERENCES public.connection_grants(company_id, id);


--
-- Name: ai_provider_defaults ai_provider_defaults_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_provider_defaults
    ADD CONSTRAINT ai_provider_defaults_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: approval_comments approval_comments_approval_id_approvals_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approval_comments
    ADD CONSTRAINT approval_comments_approval_id_approvals_id_fk FOREIGN KEY (approval_id) REFERENCES public.approvals(id) NOT VALID;


--
-- Name: approval_comments approval_comments_author_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approval_comments
    ADD CONSTRAINT approval_comments_author_agent_id_agents_id_fk FOREIGN KEY (author_agent_id) REFERENCES public.agents(id) NOT VALID;


--
-- Name: approval_comments approval_comments_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approval_comments
    ADD CONSTRAINT approval_comments_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: approvals approvals_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approvals
    ADD CONSTRAINT approvals_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: approvals approvals_requested_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approvals
    ADD CONSTRAINT approvals_requested_by_agent_id_agents_id_fk FOREIGN KEY (requested_by_agent_id) REFERENCES public.agents(id) NOT VALID;


--
-- Name: assets assets_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assets
    ADD CONSTRAINT assets_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: assets assets_created_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assets
    ADD CONSTRAINT assets_created_by_agent_id_agents_id_fk FOREIGN KEY (created_by_agent_id) REFERENCES public.agents(id) NOT VALID;


--
-- Name: board_api_keys board_api_keys_user_id_user_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.board_api_keys
    ADD CONSTRAINT board_api_keys_user_id_user_id_fk FOREIGN KEY (user_id) REFERENCES public."user"(id) ON DELETE CASCADE NOT VALID;


--
-- Name: browser_use_browsers browser_use_browsers_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.browser_use_browsers
    ADD CONSTRAINT browser_use_browsers_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: browser_use_browsers browser_use_browsers_session_id_browser_use_sessions_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.browser_use_browsers
    ADD CONSTRAINT browser_use_browsers_session_id_browser_use_sessions_id_fk FOREIGN KEY (session_id) REFERENCES public.browser_use_sessions(id);


--
-- Name: browser_use_runs browser_use_runs_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.browser_use_runs
    ADD CONSTRAINT browser_use_runs_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: browser_use_runs browser_use_runs_heartbeat_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.browser_use_runs
    ADD CONSTRAINT browser_use_runs_heartbeat_run_id_heartbeat_runs_id_fk FOREIGN KEY (heartbeat_run_id) REFERENCES public.heartbeat_runs(id);


--
-- Name: browser_use_runs browser_use_runs_session_id_browser_use_sessions_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.browser_use_runs
    ADD CONSTRAINT browser_use_runs_session_id_browser_use_sessions_id_fk FOREIGN KEY (session_id) REFERENCES public.browser_use_sessions(id);


--
-- Name: browser_use_sessions browser_use_sessions_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.browser_use_sessions
    ADD CONSTRAINT browser_use_sessions_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES public.agents(id);


--
-- Name: browser_use_sessions browser_use_sessions_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.browser_use_sessions
    ADD CONSTRAINT browser_use_sessions_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: browser_use_sessions browser_use_sessions_connection_id_tool_connections_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.browser_use_sessions
    ADD CONSTRAINT browser_use_sessions_connection_id_tool_connections_id_fk FOREIGN KEY (connection_id) REFERENCES public.tool_connections(id);


--
-- Name: browser_use_sessions browser_use_sessions_grant_id_connection_grants_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.browser_use_sessions
    ADD CONSTRAINT browser_use_sessions_grant_id_connection_grants_id_fk FOREIGN KEY (grant_id) REFERENCES public.connection_grants(id);


--
-- Name: browser_use_sessions browser_use_sessions_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.browser_use_sessions
    ADD CONSTRAINT browser_use_sessions_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id);


--
-- Name: browser_use_settings browser_use_settings_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.browser_use_settings
    ADD CONSTRAINT browser_use_settings_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: browser_use_settings browser_use_settings_grant_id_connection_grants_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.browser_use_settings
    ADD CONSTRAINT browser_use_settings_grant_id_connection_grants_id_fk FOREIGN KEY (grant_id) REFERENCES public.connection_grants(id);


--
-- Name: budget_incidents budget_incidents_approval_id_approvals_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.budget_incidents
    ADD CONSTRAINT budget_incidents_approval_id_approvals_id_fk FOREIGN KEY (approval_id) REFERENCES public.approvals(id) NOT VALID;


--
-- Name: budget_incidents budget_incidents_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.budget_incidents
    ADD CONSTRAINT budget_incidents_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: budget_incidents budget_incidents_policy_id_budget_policies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.budget_incidents
    ADD CONSTRAINT budget_incidents_policy_id_budget_policies_id_fk FOREIGN KEY (policy_id) REFERENCES public.budget_policies(id) NOT VALID;


--
-- Name: budget_policies budget_policies_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.budget_policies
    ADD CONSTRAINT budget_policies_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: built_in_managed_resources built_in_managed_resources_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.built_in_managed_resources
    ADD CONSTRAINT built_in_managed_resources_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: case_attachments case_attachments_asset_id_assets_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_attachments
    ADD CONSTRAINT case_attachments_asset_id_assets_id_fk FOREIGN KEY (asset_id) REFERENCES public.assets(id) ON DELETE CASCADE;


--
-- Name: case_attachments case_attachments_case_id_cases_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_attachments
    ADD CONSTRAINT case_attachments_case_id_cases_id_fk FOREIGN KEY (case_id) REFERENCES public.cases(id) ON DELETE CASCADE;


--
-- Name: case_attachments case_attachments_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_attachments
    ADD CONSTRAINT case_attachments_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: case_documents case_documents_case_id_cases_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_documents
    ADD CONSTRAINT case_documents_case_id_cases_id_fk FOREIGN KEY (case_id) REFERENCES public.cases(id) ON DELETE CASCADE;


--
-- Name: case_documents case_documents_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_documents
    ADD CONSTRAINT case_documents_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: case_documents case_documents_document_id_documents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_documents
    ADD CONSTRAINT case_documents_document_id_documents_id_fk FOREIGN KEY (document_id) REFERENCES public.documents(id) ON DELETE CASCADE;


--
-- Name: case_events case_events_actor_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_events
    ADD CONSTRAINT case_events_actor_agent_id_agents_id_fk FOREIGN KEY (actor_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: case_events case_events_case_id_cases_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_events
    ADD CONSTRAINT case_events_case_id_cases_id_fk FOREIGN KEY (case_id) REFERENCES public.cases(id) ON DELETE CASCADE;


--
-- Name: case_events case_events_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_events
    ADD CONSTRAINT case_events_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: case_issue_links case_issue_links_case_id_cases_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_issue_links
    ADD CONSTRAINT case_issue_links_case_id_cases_id_fk FOREIGN KEY (case_id) REFERENCES public.cases(id) ON DELETE CASCADE;


--
-- Name: case_issue_links case_issue_links_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_issue_links
    ADD CONSTRAINT case_issue_links_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: case_issue_links case_issue_links_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_issue_links
    ADD CONSTRAINT case_issue_links_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE CASCADE;


--
-- Name: case_labels case_labels_case_id_cases_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_labels
    ADD CONSTRAINT case_labels_case_id_cases_id_fk FOREIGN KEY (case_id) REFERENCES public.cases(id) ON DELETE CASCADE;


--
-- Name: case_labels case_labels_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_labels
    ADD CONSTRAINT case_labels_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: case_labels case_labels_label_id_labels_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_labels
    ADD CONSTRAINT case_labels_label_id_labels_id_fk FOREIGN KEY (label_id) REFERENCES public.labels(id) ON DELETE CASCADE;


--
-- Name: cases cases_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cases
    ADD CONSTRAINT cases_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: cases cases_created_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cases
    ADD CONSTRAINT cases_created_by_agent_id_agents_id_fk FOREIGN KEY (created_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: cases cases_parent_case_id_cases_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cases
    ADD CONSTRAINT cases_parent_case_id_cases_id_fk FOREIGN KEY (parent_case_id) REFERENCES public.cases(id) ON DELETE SET NULL;


--
-- Name: cases cases_project_id_projects_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cases
    ADD CONSTRAINT cases_project_id_projects_id_fk FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE SET NULL;


--
-- Name: chat_actions chat_actions_company_conversation_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_actions
    ADD CONSTRAINT chat_actions_company_conversation_fk FOREIGN KEY (company_id, conversation_id) REFERENCES public.chat_conversations(company_id, id);


--
-- Name: chat_actions chat_actions_company_delivery_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_actions
    ADD CONSTRAINT chat_actions_company_delivery_fk FOREIGN KEY (company_id, delivery_id) REFERENCES public.chat_deliveries(company_id, id);


--
-- Name: chat_actions chat_actions_company_endpoint_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_actions
    ADD CONSTRAINT chat_actions_company_endpoint_fk FOREIGN KEY (company_id, endpoint_id) REFERENCES public.chat_endpoints(company_id, id) ON DELETE CASCADE;


--
-- Name: chat_actions chat_actions_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_actions
    ADD CONSTRAINT chat_actions_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: chat_actions chat_actions_company_principal_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_actions
    ADD CONSTRAINT chat_actions_company_principal_fk FOREIGN KEY (company_id, principal_id) REFERENCES public.chat_external_principals(company_id, id);


--
-- Name: chat_actions chat_actions_delivery_id_chat_deliveries_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_actions
    ADD CONSTRAINT chat_actions_delivery_id_chat_deliveries_id_fk FOREIGN KEY (delivery_id) REFERENCES public.chat_deliveries(id) ON DELETE SET NULL;


--
-- Name: chat_agent_routes chat_agent_routes_company_destination_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_agent_routes
    ADD CONSTRAINT chat_agent_routes_company_destination_fk FOREIGN KEY (company_id, destination_endpoint_id) REFERENCES public.chat_endpoints(company_id, id) ON DELETE CASCADE;


--
-- Name: chat_agent_routes chat_agent_routes_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_agent_routes
    ADD CONSTRAINT chat_agent_routes_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: chat_agent_routes chat_agent_routes_company_source_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_agent_routes
    ADD CONSTRAINT chat_agent_routes_company_source_fk FOREIGN KEY (company_id, source_endpoint_id) REFERENCES public.chat_endpoints(company_id, id) ON DELETE CASCADE;


--
-- Name: chat_completion_deliveries chat_completion_deliveries_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_completion_deliveries
    ADD CONSTRAINT chat_completion_deliveries_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: chat_completion_deliveries chat_completion_deliveries_response_comment_id_issue_comments_i; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_completion_deliveries
    ADD CONSTRAINT chat_completion_deliveries_response_comment_id_issue_comments_i FOREIGN KEY (response_comment_id) REFERENCES public.issue_comments(id) ON DELETE SET NULL;


--
-- Name: chat_completion_deliveries chat_completion_deliveries_target_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_completion_deliveries
    ADD CONSTRAINT chat_completion_deliveries_target_run_id_heartbeat_runs_id_fk FOREIGN KEY (target_run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL;


--
-- Name: chat_completion_deliveries chat_completion_deliveries_task_id_chat_task_handoffs_task_id_f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_completion_deliveries
    ADD CONSTRAINT chat_completion_deliveries_task_id_chat_task_handoffs_task_id_f FOREIGN KEY (task_id) REFERENCES public.chat_task_handoffs(task_id) ON DELETE CASCADE;


--
-- Name: chat_conversations chat_conversations_company_endpoint_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_conversations
    ADD CONSTRAINT chat_conversations_company_endpoint_fk FOREIGN KEY (company_id, endpoint_id) REFERENCES public.chat_endpoints(company_id, id) ON DELETE CASCADE;


--
-- Name: chat_conversations chat_conversations_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_conversations
    ADD CONSTRAINT chat_conversations_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: chat_conversations chat_conversations_company_issue_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_conversations
    ADD CONSTRAINT chat_conversations_company_issue_fk FOREIGN KEY (company_id, issue_id) REFERENCES public.issues(company_id, id);


--
-- Name: chat_conversations chat_conversations_company_resource_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_conversations
    ADD CONSTRAINT chat_conversations_company_resource_fk FOREIGN KEY (company_id, resource_id) REFERENCES public.chat_endpoint_resources(company_id, id);


--
-- Name: chat_conversations chat_conversations_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_conversations
    ADD CONSTRAINT chat_conversations_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE RESTRICT;


--
-- Name: chat_conversations chat_conversations_resource_id_chat_endpoint_resources_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_conversations
    ADD CONSTRAINT chat_conversations_resource_id_chat_endpoint_resources_id_fk FOREIGN KEY (resource_id) REFERENCES public.chat_endpoint_resources(id) ON DELETE SET NULL;


--
-- Name: chat_deliveries chat_deliveries_company_conversation_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_deliveries
    ADD CONSTRAINT chat_deliveries_company_conversation_fk FOREIGN KEY (company_id, conversation_id) REFERENCES public.chat_conversations(company_id, id);


--
-- Name: chat_deliveries chat_deliveries_company_endpoint_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_deliveries
    ADD CONSTRAINT chat_deliveries_company_endpoint_fk FOREIGN KEY (company_id, endpoint_id) REFERENCES public.chat_endpoints(company_id, id) ON DELETE CASCADE;


--
-- Name: chat_deliveries chat_deliveries_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_deliveries
    ADD CONSTRAINT chat_deliveries_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: chat_deliveries chat_deliveries_company_principal_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_deliveries
    ADD CONSTRAINT chat_deliveries_company_principal_fk FOREIGN KEY (company_id, principal_id) REFERENCES public.chat_external_principals(company_id, id);


--
-- Name: chat_deliveries chat_deliveries_conversation_id_chat_conversations_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_deliveries
    ADD CONSTRAINT chat_deliveries_conversation_id_chat_conversations_id_fk FOREIGN KEY (conversation_id) REFERENCES public.chat_conversations(id) ON DELETE SET NULL;


--
-- Name: chat_deliveries chat_deliveries_principal_id_chat_external_principals_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_deliveries
    ADD CONSTRAINT chat_deliveries_principal_id_chat_external_principals_id_fk FOREIGN KEY (principal_id) REFERENCES public.chat_external_principals(id) ON DELETE SET NULL;


--
-- Name: chat_endpoint_leases chat_endpoint_leases_company_endpoint_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_endpoint_leases
    ADD CONSTRAINT chat_endpoint_leases_company_endpoint_fk FOREIGN KEY (company_id, endpoint_id) REFERENCES public.chat_endpoints(company_id, id) ON DELETE CASCADE;


--
-- Name: chat_endpoint_leases chat_endpoint_leases_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_endpoint_leases
    ADD CONSTRAINT chat_endpoint_leases_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: chat_endpoint_resources chat_endpoint_resources_company_endpoint_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_endpoint_resources
    ADD CONSTRAINT chat_endpoint_resources_company_endpoint_fk FOREIGN KEY (company_id, endpoint_id) REFERENCES public.chat_endpoints(company_id, id) ON DELETE CASCADE;


--
-- Name: chat_endpoint_resources chat_endpoint_resources_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_endpoint_resources
    ADD CONSTRAINT chat_endpoint_resources_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: chat_endpoints chat_endpoints_assigned_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_endpoints
    ADD CONSTRAINT chat_endpoints_assigned_agent_id_agents_id_fk FOREIGN KEY (assigned_agent_id) REFERENCES public.agents(id) ON DELETE RESTRICT;


--
-- Name: chat_endpoints chat_endpoints_company_agent_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_endpoints
    ADD CONSTRAINT chat_endpoints_company_agent_fk FOREIGN KEY (company_id, assigned_agent_id) REFERENCES public.agents(company_id, id);


--
-- Name: chat_endpoints chat_endpoints_company_connection_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_endpoints
    ADD CONSTRAINT chat_endpoints_company_connection_fk FOREIGN KEY (company_id, connection_id) REFERENCES public.tool_connections(company_id, id) ON DELETE CASCADE;


--
-- Name: chat_endpoints chat_endpoints_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_endpoints
    ADD CONSTRAINT chat_endpoints_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: chat_external_principals chat_external_principals_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_external_principals
    ADD CONSTRAINT chat_external_principals_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: chat_github_configurations chat_github_configurations_company_id_endpoint_id_chat_endpoint; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_github_configurations
    ADD CONSTRAINT chat_github_configurations_company_id_endpoint_id_chat_endpoint FOREIGN KEY (company_id, endpoint_id) REFERENCES public.chat_endpoints(company_id, id) ON DELETE CASCADE;


--
-- Name: chat_github_registrations chat_github_registrations_company_id_endpoint_id_chat_endpoints; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_github_registrations
    ADD CONSTRAINT chat_github_registrations_company_id_endpoint_id_chat_endpoints FOREIGN KEY (company_id, endpoint_id) REFERENCES public.chat_endpoints(company_id, id) ON DELETE CASCADE;


--
-- Name: chat_github_reviews chat_github_reviews_company_id_endpoint_id_chat_endpoints_compa; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_github_reviews
    ADD CONSTRAINT chat_github_reviews_company_id_endpoint_id_chat_endpoints_compa FOREIGN KEY (company_id, endpoint_id) REFERENCES public.chat_endpoints(company_id, id) ON DELETE CASCADE;


--
-- Name: chat_github_reviews chat_github_reviews_company_id_issue_id_issues_company_id_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_github_reviews
    ADD CONSTRAINT chat_github_reviews_company_id_issue_id_issues_company_id_id_fk FOREIGN KEY (company_id, issue_id) REFERENCES public.issues(company_id, id) ON DELETE RESTRICT;


--
-- Name: chat_github_reviews chat_github_reviews_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_github_reviews
    ADD CONSTRAINT chat_github_reviews_run_id_heartbeat_runs_id_fk FOREIGN KEY (run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL;


--
-- Name: chat_identity_links chat_identity_links_company_endpoint_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_identity_links
    ADD CONSTRAINT chat_identity_links_company_endpoint_fk FOREIGN KEY (company_id, endpoint_id) REFERENCES public.chat_endpoints(company_id, id) ON DELETE CASCADE;


--
-- Name: chat_identity_links chat_identity_links_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_identity_links
    ADD CONSTRAINT chat_identity_links_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: chat_identity_links chat_identity_links_company_principal_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_identity_links
    ADD CONSTRAINT chat_identity_links_company_principal_fk FOREIGN KEY (company_id, principal_id) REFERENCES public.chat_external_principals(company_id, id) ON DELETE CASCADE;


--
-- Name: chat_message_links chat_message_links_comment_id_issue_comments_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_message_links
    ADD CONSTRAINT chat_message_links_comment_id_issue_comments_id_fk FOREIGN KEY (comment_id) REFERENCES public.issue_comments(id) ON DELETE SET NULL;


--
-- Name: chat_message_links chat_message_links_company_comment_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_message_links
    ADD CONSTRAINT chat_message_links_company_comment_fk FOREIGN KEY (company_id, comment_id) REFERENCES public.issue_comments(company_id, id);


--
-- Name: chat_message_links chat_message_links_company_conversation_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_message_links
    ADD CONSTRAINT chat_message_links_company_conversation_fk FOREIGN KEY (company_id, conversation_id) REFERENCES public.chat_conversations(company_id, id) ON DELETE CASCADE;


--
-- Name: chat_message_links chat_message_links_company_delivery_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_message_links
    ADD CONSTRAINT chat_message_links_company_delivery_fk FOREIGN KEY (company_id, delivery_id) REFERENCES public.chat_deliveries(company_id, id);


--
-- Name: chat_message_links chat_message_links_company_endpoint_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_message_links
    ADD CONSTRAINT chat_message_links_company_endpoint_fk FOREIGN KEY (company_id, endpoint_id) REFERENCES public.chat_endpoints(company_id, id) ON DELETE CASCADE;


--
-- Name: chat_message_links chat_message_links_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_message_links
    ADD CONSTRAINT chat_message_links_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: chat_message_links chat_message_links_company_publication_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_message_links
    ADD CONSTRAINT chat_message_links_company_publication_fk FOREIGN KEY (company_id, publication_id) REFERENCES public.chat_publications(company_id, id);


--
-- Name: chat_message_links chat_message_links_delivery_id_chat_deliveries_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_message_links
    ADD CONSTRAINT chat_message_links_delivery_id_chat_deliveries_id_fk FOREIGN KEY (delivery_id) REFERENCES public.chat_deliveries(id) ON DELETE SET NULL;


--
-- Name: chat_message_links chat_message_links_publication_id_chat_publications_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_message_links
    ADD CONSTRAINT chat_message_links_publication_id_chat_publications_id_fk FOREIGN KEY (publication_id) REFERENCES public.chat_publications(id) ON DELETE SET NULL;


--
-- Name: chat_publications chat_publications_comment_id_issue_comments_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_publications
    ADD CONSTRAINT chat_publications_comment_id_issue_comments_id_fk FOREIGN KEY (comment_id) REFERENCES public.issue_comments(id) ON DELETE SET NULL;


--
-- Name: chat_publications chat_publications_company_comment_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_publications
    ADD CONSTRAINT chat_publications_company_comment_fk FOREIGN KEY (company_id, comment_id) REFERENCES public.issue_comments(company_id, id);


--
-- Name: chat_publications chat_publications_company_conversation_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_publications
    ADD CONSTRAINT chat_publications_company_conversation_fk FOREIGN KEY (company_id, conversation_id) REFERENCES public.chat_conversations(company_id, id) ON DELETE CASCADE;


--
-- Name: chat_publications chat_publications_company_endpoint_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_publications
    ADD CONSTRAINT chat_publications_company_endpoint_fk FOREIGN KEY (company_id, endpoint_id) REFERENCES public.chat_endpoints(company_id, id) ON DELETE CASCADE;


--
-- Name: chat_publications chat_publications_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_publications
    ADD CONSTRAINT chat_publications_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: chat_publications chat_publications_company_issue_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_publications
    ADD CONSTRAINT chat_publications_company_issue_fk FOREIGN KEY (company_id, issue_id) REFERENCES public.issues(company_id, id);


--
-- Name: chat_publications chat_publications_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_publications
    ADD CONSTRAINT chat_publications_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE RESTRICT;


--
-- Name: chat_sdk_state chat_sdk_state_company_endpoint_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_sdk_state
    ADD CONSTRAINT chat_sdk_state_company_endpoint_fk FOREIGN KEY (company_id, endpoint_id) REFERENCES public.chat_endpoints(company_id, id) ON DELETE CASCADE;


--
-- Name: chat_sdk_state chat_sdk_state_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_sdk_state
    ADD CONSTRAINT chat_sdk_state_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: chat_task_handoffs chat_task_handoffs_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_task_handoffs
    ADD CONSTRAINT chat_task_handoffs_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES public.agents(id) ON DELETE CASCADE;


--
-- Name: chat_task_handoffs chat_task_handoffs_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_task_handoffs
    ADD CONSTRAINT chat_task_handoffs_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: chat_task_handoffs chat_task_handoffs_conversation_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_task_handoffs
    ADD CONSTRAINT chat_task_handoffs_conversation_id_issues_id_fk FOREIGN KEY (conversation_id) REFERENCES public.issues(id) ON DELETE CASCADE;


--
-- Name: chat_task_handoffs chat_task_handoffs_task_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_task_handoffs
    ADD CONSTRAINT chat_task_handoffs_task_id_issues_id_fk FOREIGN KEY (task_id) REFERENCES public.issues(id) ON DELETE CASCADE;


--
-- Name: chat_teams_file_transfers chat_teams_file_transfers_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_teams_file_transfers
    ADD CONSTRAINT chat_teams_file_transfers_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: chat_teams_file_transfers chat_teams_file_transfers_company_id_conversation_id_chat_conve; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_teams_file_transfers
    ADD CONSTRAINT chat_teams_file_transfers_company_id_conversation_id_chat_conve FOREIGN KEY (company_id, conversation_id) REFERENCES public.chat_conversations(company_id, id) ON DELETE CASCADE;


--
-- Name: chat_teams_file_transfers chat_teams_file_transfers_company_id_endpoint_id_chat_endpoints; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_teams_file_transfers
    ADD CONSTRAINT chat_teams_file_transfers_company_id_endpoint_id_chat_endpoints FOREIGN KEY (company_id, endpoint_id) REFERENCES public.chat_endpoints(company_id, id) ON DELETE CASCADE;


--
-- Name: chat_teams_file_transfers chat_teams_file_transfers_company_id_principal_id_chat_external; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_teams_file_transfers
    ADD CONSTRAINT chat_teams_file_transfers_company_id_principal_id_chat_external FOREIGN KEY (company_id, principal_id) REFERENCES public.chat_external_principals(company_id, id);


--
-- Name: chat_teams_file_transfers chat_teams_file_transfers_company_id_publication_id_chat_public; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_teams_file_transfers
    ADD CONSTRAINT chat_teams_file_transfers_company_id_publication_id_chat_public FOREIGN KEY (company_id, publication_id) REFERENCES public.chat_publications(company_id, id) ON DELETE CASCADE;


--
-- Name: chat_teams_file_transfers chat_teams_file_transfers_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_teams_file_transfers
    ADD CONSTRAINT chat_teams_file_transfers_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE RESTRICT;


--
-- Name: cli_auth_challenges cli_auth_challenges_approved_by_user_id_user_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cli_auth_challenges
    ADD CONSTRAINT cli_auth_challenges_approved_by_user_id_user_id_fk FOREIGN KEY (approved_by_user_id) REFERENCES public."user"(id) ON DELETE SET NULL NOT VALID;


--
-- Name: cli_auth_challenges cli_auth_challenges_board_api_key_id_board_api_keys_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cli_auth_challenges
    ADD CONSTRAINT cli_auth_challenges_board_api_key_id_board_api_keys_id_fk FOREIGN KEY (board_api_key_id) REFERENCES public.board_api_keys(id) ON DELETE SET NULL NOT VALID;


--
-- Name: cli_auth_challenges cli_auth_challenges_requested_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cli_auth_challenges
    ADD CONSTRAINT cli_auth_challenges_requested_company_id_companies_id_fk FOREIGN KEY (requested_company_id) REFERENCES public.companies(id) ON DELETE SET NULL NOT VALID;


--
-- Name: company_logos company_logos_asset_id_assets_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_logos
    ADD CONSTRAINT company_logos_asset_id_assets_id_fk FOREIGN KEY (asset_id) REFERENCES public.assets(id) ON DELETE CASCADE NOT VALID;


--
-- Name: company_logos company_logos_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_logos
    ADD CONSTRAINT company_logos_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE NOT VALID;


--
-- Name: company_memberships company_memberships_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_memberships
    ADD CONSTRAINT company_memberships_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: company_onboarding_seeds company_onboarding_seeds_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_onboarding_seeds
    ADD CONSTRAINT company_onboarding_seeds_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: company_onboarding_seeds company_onboarding_seeds_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_onboarding_seeds
    ADD CONSTRAINT company_onboarding_seeds_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: company_onboarding_seeds company_onboarding_seeds_goal_id_goals_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_onboarding_seeds
    ADD CONSTRAINT company_onboarding_seeds_goal_id_goals_id_fk FOREIGN KEY (goal_id) REFERENCES public.goals(id) ON DELETE SET NULL;


--
-- Name: company_onboarding_seeds company_onboarding_seeds_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_onboarding_seeds
    ADD CONSTRAINT company_onboarding_seeds_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE SET NULL;


--
-- Name: company_secret_bindings company_secret_bindings_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_secret_bindings
    ADD CONSTRAINT company_secret_bindings_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: company_secret_bindings company_secret_bindings_secret_id_company_secrets_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_secret_bindings
    ADD CONSTRAINT company_secret_bindings_secret_id_company_secrets_id_fk FOREIGN KEY (secret_id) REFERENCES public.company_secrets(id) ON DELETE CASCADE NOT VALID;


--
-- Name: company_secret_proposals company_secret_proposals_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_secret_proposals
    ADD CONSTRAINT company_secret_proposals_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: company_secret_proposals company_secret_proposals_created_secret_id_company_secrets_id_f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_secret_proposals
    ADD CONSTRAINT company_secret_proposals_created_secret_id_company_secrets_id_f FOREIGN KEY (created_secret_id) REFERENCES public.company_secrets(id) ON DELETE SET NULL;


--
-- Name: company_secret_proposals company_secret_proposals_interaction_id_issue_thread_interactio; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_secret_proposals
    ADD CONSTRAINT company_secret_proposals_interaction_id_issue_thread_interactio FOREIGN KEY (interaction_id) REFERENCES public.issue_thread_interactions(id) ON DELETE SET NULL;


--
-- Name: company_secret_proposals company_secret_proposals_origin_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_secret_proposals
    ADD CONSTRAINT company_secret_proposals_origin_issue_id_issues_id_fk FOREIGN KEY (origin_issue_id) REFERENCES public.issues(id) ON DELETE SET NULL;


--
-- Name: company_secret_proposals company_secret_proposals_origin_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_secret_proposals
    ADD CONSTRAINT company_secret_proposals_origin_run_id_heartbeat_runs_id_fk FOREIGN KEY (origin_run_id) REFERENCES public.heartbeat_runs(id) ON DELETE CASCADE;


--
-- Name: company_secret_proposals company_secret_proposals_proposed_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_secret_proposals
    ADD CONSTRAINT company_secret_proposals_proposed_by_agent_id_agents_id_fk FOREIGN KEY (proposed_by_agent_id) REFERENCES public.agents(id) ON DELETE CASCADE;


--
-- Name: company_secret_proposals company_secret_proposals_secret_id_company_secrets_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_secret_proposals
    ADD CONSTRAINT company_secret_proposals_secret_id_company_secrets_id_fk FOREIGN KEY (secret_id) REFERENCES public.company_secrets(id) ON DELETE SET NULL;


--
-- Name: company_secret_proposals company_secret_proposals_secret_proposal_id_company_secret_prop; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_secret_proposals
    ADD CONSTRAINT company_secret_proposals_secret_proposal_id_company_secret_prop FOREIGN KEY (secret_proposal_id) REFERENCES public.company_secret_proposals(id) ON DELETE CASCADE;


--
-- Name: company_secret_proposals company_secret_proposals_target_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_secret_proposals
    ADD CONSTRAINT company_secret_proposals_target_id_agents_id_fk FOREIGN KEY (target_id) REFERENCES public.agents(id) ON DELETE CASCADE;


--
-- Name: company_secret_provider_configs company_secret_provider_configs_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_secret_provider_configs
    ADD CONSTRAINT company_secret_provider_configs_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE NOT VALID;


--
-- Name: company_secret_provider_configs company_secret_provider_configs_created_by_agent_id_agents_id_f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_secret_provider_configs
    ADD CONSTRAINT company_secret_provider_configs_created_by_agent_id_agents_id_f FOREIGN KEY (created_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL NOT VALID;


--
-- Name: company_secret_versions company_secret_versions_created_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_secret_versions
    ADD CONSTRAINT company_secret_versions_created_by_agent_id_agents_id_fk FOREIGN KEY (created_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL NOT VALID;


--
-- Name: company_secret_versions company_secret_versions_secret_id_company_secrets_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_secret_versions
    ADD CONSTRAINT company_secret_versions_secret_id_company_secrets_id_fk FOREIGN KEY (secret_id) REFERENCES public.company_secrets(id) ON DELETE CASCADE NOT VALID;


--
-- Name: company_secrets company_secrets_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_secrets
    ADD CONSTRAINT company_secrets_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: company_secrets company_secrets_created_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_secrets
    ADD CONSTRAINT company_secrets_created_by_agent_id_agents_id_fk FOREIGN KEY (created_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL NOT VALID;


--
-- Name: company_secrets company_secrets_provider_config_id_company_secret_provider_conf; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_secrets
    ADD CONSTRAINT company_secrets_provider_config_id_company_secret_provider_conf FOREIGN KEY (provider_config_id) REFERENCES public.company_secret_provider_configs(id) ON DELETE SET NULL;


--
-- Name: company_secrets company_secrets_user_secret_definition_id_user_secret_definitio; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_secrets
    ADD CONSTRAINT company_secrets_user_secret_definition_id_user_secret_definitio FOREIGN KEY (user_secret_definition_id) REFERENCES public.user_secret_definitions(id) ON DELETE SET NULL;


--
-- Name: company_skill_comments company_skill_comments_author_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_comments
    ADD CONSTRAINT company_skill_comments_author_agent_id_agents_id_fk FOREIGN KEY (author_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: company_skill_comments company_skill_comments_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_comments
    ADD CONSTRAINT company_skill_comments_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: company_skill_comments company_skill_comments_company_skill_id_company_skills_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_comments
    ADD CONSTRAINT company_skill_comments_company_skill_id_company_skills_id_fk FOREIGN KEY (company_skill_id) REFERENCES public.company_skills(id) ON DELETE CASCADE;


--
-- Name: company_skill_comments company_skill_comments_parent_comment_id_company_skill_comments; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_comments
    ADD CONSTRAINT company_skill_comments_parent_comment_id_company_skill_comments FOREIGN KEY (parent_comment_id) REFERENCES public.company_skill_comments(id) ON DELETE SET NULL;


--
-- Name: company_skill_policies company_skill_policies_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_policies
    ADD CONSTRAINT company_skill_policies_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: company_skill_source_entries company_skill_source_entries_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_source_entries
    ADD CONSTRAINT company_skill_source_entries_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: company_skill_source_entries company_skill_source_entries_skill_id_company_skills_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_source_entries
    ADD CONSTRAINT company_skill_source_entries_skill_id_company_skills_id_fk FOREIGN KEY (skill_id) REFERENCES public.company_skills(id) ON DELETE SET NULL;


--
-- Name: company_skill_source_entries company_skill_source_entries_source_id_company_skill_sources_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_source_entries
    ADD CONSTRAINT company_skill_source_entries_source_id_company_skill_sources_id FOREIGN KEY (source_id) REFERENCES public.company_skill_sources(id) ON DELETE CASCADE;


--
-- Name: company_skill_sources company_skill_sources_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_sources
    ADD CONSTRAINT company_skill_sources_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: company_skill_sources company_skill_sources_connection_id_tool_connections_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_sources
    ADD CONSTRAINT company_skill_sources_connection_id_tool_connections_id_fk FOREIGN KEY (connection_id) REFERENCES public.tool_connections(id) ON DELETE SET NULL;


--
-- Name: company_skill_stars company_skill_stars_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_stars
    ADD CONSTRAINT company_skill_stars_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES public.agents(id) ON DELETE CASCADE;


--
-- Name: company_skill_stars company_skill_stars_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_stars
    ADD CONSTRAINT company_skill_stars_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: company_skill_stars company_skill_stars_company_skill_id_company_skills_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_stars
    ADD CONSTRAINT company_skill_stars_company_skill_id_company_skills_id_fk FOREIGN KEY (company_skill_id) REFERENCES public.company_skills(id) ON DELETE CASCADE;


--
-- Name: company_skill_test_inputs company_skill_test_inputs_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_test_inputs
    ADD CONSTRAINT company_skill_test_inputs_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: company_skill_test_inputs company_skill_test_inputs_skill_id_company_skills_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_test_inputs
    ADD CONSTRAINT company_skill_test_inputs_skill_id_company_skills_id_fk FOREIGN KEY (skill_id) REFERENCES public.company_skills(id) ON DELETE CASCADE;


--
-- Name: company_skill_test_run_templates company_skill_test_run_templates_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_test_run_templates
    ADD CONSTRAINT company_skill_test_run_templates_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: company_skill_test_run_templates company_skill_test_run_templates_created_by_agent_id_agents_id_; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_test_run_templates
    ADD CONSTRAINT company_skill_test_run_templates_created_by_agent_id_agents_id_ FOREIGN KEY (created_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: company_skill_test_run_templates company_skill_test_run_templates_updated_by_agent_id_agents_id_; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_test_run_templates
    ADD CONSTRAINT company_skill_test_run_templates_updated_by_agent_id_agents_id_ FOREIGN KEY (updated_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: company_skill_test_runs company_skill_test_runs_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_test_runs
    ADD CONSTRAINT company_skill_test_runs_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES public.agents(id) ON DELETE RESTRICT;


--
-- Name: company_skill_test_runs company_skill_test_runs_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_test_runs
    ADD CONSTRAINT company_skill_test_runs_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: company_skill_test_runs company_skill_test_runs_input_id_company_skill_test_inputs_id_f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_test_runs
    ADD CONSTRAINT company_skill_test_runs_input_id_company_skill_test_inputs_id_f FOREIGN KEY (input_id) REFERENCES public.company_skill_test_inputs(id) ON DELETE SET NULL;


--
-- Name: company_skill_test_runs company_skill_test_runs_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_test_runs
    ADD CONSTRAINT company_skill_test_runs_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE RESTRICT;


--
-- Name: company_skill_test_runs company_skill_test_runs_skill_id_company_skills_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_test_runs
    ADD CONSTRAINT company_skill_test_runs_skill_id_company_skills_id_fk FOREIGN KEY (skill_id) REFERENCES public.company_skills(id) ON DELETE CASCADE;


--
-- Name: company_skill_test_runs company_skill_test_runs_skill_version_id_company_skill_versions; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_test_runs
    ADD CONSTRAINT company_skill_test_runs_skill_version_id_company_skill_versions FOREIGN KEY (skill_version_id) REFERENCES public.company_skill_versions(id) ON DELETE RESTRICT;


--
-- Name: company_skill_versions company_skill_versions_author_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_versions
    ADD CONSTRAINT company_skill_versions_author_agent_id_agents_id_fk FOREIGN KEY (author_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: company_skill_versions company_skill_versions_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_versions
    ADD CONSTRAINT company_skill_versions_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: company_skill_versions company_skill_versions_company_skill_id_company_skills_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skill_versions
    ADD CONSTRAINT company_skill_versions_company_skill_id_company_skills_id_fk FOREIGN KEY (company_skill_id) REFERENCES public.company_skills(id) ON DELETE CASCADE;


--
-- Name: company_skills company_skills_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skills
    ADD CONSTRAINT company_skills_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: company_skills company_skills_current_version_id_company_skill_versions_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skills
    ADD CONSTRAINT company_skills_current_version_id_company_skill_versions_id_fk FOREIGN KEY (current_version_id) REFERENCES public.company_skill_versions(id) ON DELETE SET NULL;


--
-- Name: company_skills company_skills_folder_id_folders_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skills
    ADD CONSTRAINT company_skills_folder_id_folders_id_fk FOREIGN KEY (folder_id) REFERENCES public.folders(id) ON DELETE SET NULL;


--
-- Name: company_skills company_skills_forked_from_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skills
    ADD CONSTRAINT company_skills_forked_from_company_id_companies_id_fk FOREIGN KEY (forked_from_company_id) REFERENCES public.companies(id) ON DELETE SET NULL;


--
-- Name: company_skills company_skills_forked_from_skill_id_company_skills_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_skills
    ADD CONSTRAINT company_skills_forked_from_skill_id_company_skills_id_fk FOREIGN KEY (forked_from_skill_id) REFERENCES public.company_skills(id) ON DELETE SET NULL;


--
-- Name: company_transfer_runs company_transfer_runs_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_transfer_runs
    ADD CONSTRAINT company_transfer_runs_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE SET NULL;


--
-- Name: company_user_sidebar_preferences company_user_sidebar_preferences_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_user_sidebar_preferences
    ADD CONSTRAINT company_user_sidebar_preferences_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE NOT VALID;


--
-- Name: completion_contracts completion_contracts_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.completion_contracts
    ADD CONSTRAINT completion_contracts_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: completion_contracts completion_contracts_issue_company_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.completion_contracts
    ADD CONSTRAINT completion_contracts_issue_company_fk FOREIGN KEY (company_id, issue_id) REFERENCES public.issues(company_id, id);


--
-- Name: completion_contracts completion_contracts_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.completion_contracts
    ADD CONSTRAINT completion_contracts_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id);


--
-- Name: completion_contracts completion_contracts_supersedes_owner_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.completion_contracts
    ADD CONSTRAINT completion_contracts_supersedes_owner_fk FOREIGN KEY (company_id, issue_id, supersedes_contract_id) REFERENCES public.completion_contracts(company_id, issue_id, id);


--
-- Name: connection_event_deliveries connection_event_deliveries_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.connection_event_deliveries
    ADD CONSTRAINT connection_event_deliveries_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: connection_grant_delegations connection_grant_delegations_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.connection_grant_delegations
    ADD CONSTRAINT connection_grant_delegations_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES public.agents(id) ON DELETE CASCADE;


--
-- Name: connection_grant_delegations connection_grant_delegations_company_grant_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.connection_grant_delegations
    ADD CONSTRAINT connection_grant_delegations_company_grant_fk FOREIGN KEY (company_id, grant_id) REFERENCES public.connection_grants(company_id, id) ON DELETE CASCADE;


--
-- Name: connection_grant_delegations connection_grant_delegations_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.connection_grant_delegations
    ADD CONSTRAINT connection_grant_delegations_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: connection_grant_members connection_grant_members_company_grant_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.connection_grant_members
    ADD CONSTRAINT connection_grant_members_company_grant_fk FOREIGN KEY (company_id, grant_id) REFERENCES public.connection_grants(company_id, id) ON DELETE CASCADE;


--
-- Name: connection_grant_members connection_grant_members_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.connection_grant_members
    ADD CONSTRAINT connection_grant_members_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: connection_grants connection_grants_company_connection_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.connection_grants
    ADD CONSTRAINT connection_grants_company_connection_fk FOREIGN KEY (company_id, connection_id) REFERENCES public.tool_connections(company_id, id) ON DELETE CASCADE;


--
-- Name: connection_grants connection_grants_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.connection_grants
    ADD CONSTRAINT connection_grants_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: connection_grants connection_grants_created_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.connection_grants
    ADD CONSTRAINT connection_grants_created_by_agent_id_agents_id_fk FOREIGN KEY (created_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: connection_grants connection_grants_revoked_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.connection_grants
    ADD CONSTRAINT connection_grants_revoked_by_agent_id_agents_id_fk FOREIGN KEY (revoked_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: connection_grants connection_grants_subject_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.connection_grants
    ADD CONSTRAINT connection_grants_subject_agent_id_agents_id_fk FOREIGN KEY (subject_agent_id) REFERENCES public.agents(id) ON DELETE CASCADE;


--
-- Name: connection_intent_deliveries connection_intent_deliveries_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.connection_intent_deliveries
    ADD CONSTRAINT connection_intent_deliveries_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: connection_intent_deliveries connection_intent_deliveries_interaction_id_issue_thread_intera; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.connection_intent_deliveries
    ADD CONSTRAINT connection_intent_deliveries_interaction_id_issue_thread_intera FOREIGN KEY (interaction_id) REFERENCES public.issue_thread_interactions(id) ON DELETE CASCADE;


--
-- Name: connection_token_issuances connection_token_issuances_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.connection_token_issuances
    ADD CONSTRAINT connection_token_issuances_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES public.agents(id) ON DELETE CASCADE;


--
-- Name: connection_token_issuances connection_token_issuances_application_id_tool_applications_id_; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.connection_token_issuances
    ADD CONSTRAINT connection_token_issuances_application_id_tool_applications_id_ FOREIGN KEY (application_id) REFERENCES public.tool_applications(id) ON DELETE SET NULL;


--
-- Name: connection_token_issuances connection_token_issuances_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.connection_token_issuances
    ADD CONSTRAINT connection_token_issuances_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: connection_token_issuances connection_token_issuances_connection_id_tool_connections_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.connection_token_issuances
    ADD CONSTRAINT connection_token_issuances_connection_id_tool_connections_id_fk FOREIGN KEY (connection_id) REFERENCES public.tool_connections(id) ON DELETE CASCADE;


--
-- Name: connection_token_issuances connection_token_issuances_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.connection_token_issuances
    ADD CONSTRAINT connection_token_issuances_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE SET NULL;


--
-- Name: connection_token_issuances connection_token_issuances_project_id_projects_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.connection_token_issuances
    ADD CONSTRAINT connection_token_issuances_project_id_projects_id_fk FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE SET NULL;


--
-- Name: connection_token_issuances connection_token_issuances_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.connection_token_issuances
    ADD CONSTRAINT connection_token_issuances_run_id_heartbeat_runs_id_fk FOREIGN KEY (run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL;


--
-- Name: cost_events cost_events_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cost_events
    ADD CONSTRAINT cost_events_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES public.agents(id) NOT VALID;


--
-- Name: cost_events cost_events_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cost_events
    ADD CONSTRAINT cost_events_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: cost_events cost_events_goal_id_goals_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cost_events
    ADD CONSTRAINT cost_events_goal_id_goals_id_fk FOREIGN KEY (goal_id) REFERENCES public.goals(id) NOT VALID;


--
-- Name: cost_events cost_events_heartbeat_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cost_events
    ADD CONSTRAINT cost_events_heartbeat_run_id_heartbeat_runs_id_fk FOREIGN KEY (heartbeat_run_id) REFERENCES public.heartbeat_runs(id) NOT VALID;


--
-- Name: cost_events cost_events_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cost_events
    ADD CONSTRAINT cost_events_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE SET NULL;


--
-- Name: cost_events cost_events_project_id_projects_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cost_events
    ADD CONSTRAINT cost_events_project_id_projects_id_fk FOREIGN KEY (project_id) REFERENCES public.projects(id) NOT VALID;


--
-- Name: decision_archive_notification_outbox decision_archive_notification_outbox_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_archive_notification_outbox
    ADD CONSTRAINT decision_archive_notification_outbox_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: decision_archive_notification_outbox decision_archive_notification_outbox_origin_agent_id_agents_id_; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_archive_notification_outbox
    ADD CONSTRAINT decision_archive_notification_outbox_origin_agent_id_agents_id_ FOREIGN KEY (origin_agent_id) REFERENCES public.agents(id);


--
-- Name: decision_bundles decision_bundles_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_bundles
    ADD CONSTRAINT decision_bundles_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: decision_bundles decision_bundles_origin_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_bundles
    ADD CONSTRAINT decision_bundles_origin_agent_id_agents_id_fk FOREIGN KEY (origin_agent_id) REFERENCES public.agents(id);


--
-- Name: decision_bundles decision_bundles_origin_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_bundles
    ADD CONSTRAINT decision_bundles_origin_issue_id_issues_id_fk FOREIGN KEY (origin_issue_id) REFERENCES public.issues(id);


--
-- Name: decision_bundles decision_bundles_origin_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_bundles
    ADD CONSTRAINT decision_bundles_origin_run_id_heartbeat_runs_id_fk FOREIGN KEY (origin_run_id) REFERENCES public.heartbeat_runs(id);


--
-- Name: decision_effect_executions decision_effect_executions_activity_log_id_activity_log_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_effect_executions
    ADD CONSTRAINT decision_effect_executions_activity_log_id_activity_log_id_fk FOREIGN KEY (activity_log_id) REFERENCES public.activity_log(id) ON DELETE SET NULL;


--
-- Name: decision_effect_executions decision_effect_executions_decision_id_decisions_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_effect_executions
    ADD CONSTRAINT decision_effect_executions_decision_id_decisions_id_fk FOREIGN KEY (decision_id) REFERENCES public.decisions(id) ON DELETE CASCADE;


--
-- Name: decision_effect_executions decision_effect_executions_target_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_effect_executions
    ADD CONSTRAINT decision_effect_executions_target_issue_id_issues_id_fk FOREIGN KEY (target_issue_id) REFERENCES public.issues(id);


--
-- Name: decision_queue_items decision_queue_items_added_by_agent_api_key_id_agent_api_keys_i; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_queue_items
    ADD CONSTRAINT decision_queue_items_added_by_agent_api_key_id_agent_api_keys_i FOREIGN KEY (added_by_agent_api_key_id) REFERENCES public.agent_api_keys(id);


--
-- Name: decision_queue_items decision_queue_items_added_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_queue_items
    ADD CONSTRAINT decision_queue_items_added_by_agent_id_agents_id_fk FOREIGN KEY (added_by_agent_id) REFERENCES public.agents(id);


--
-- Name: decision_queue_items decision_queue_items_added_by_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_queue_items
    ADD CONSTRAINT decision_queue_items_added_by_run_id_heartbeat_runs_id_fk FOREIGN KEY (added_by_run_id) REFERENCES public.heartbeat_runs(id);


--
-- Name: decision_queue_items decision_queue_items_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_queue_items
    ADD CONSTRAINT decision_queue_items_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: decision_queue_items decision_queue_items_queue_company_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_queue_items
    ADD CONSTRAINT decision_queue_items_queue_company_fk FOREIGN KEY (queue_id, company_id) REFERENCES public.decision_queues(id, company_id) ON DELETE CASCADE;


--
-- Name: decision_queues decision_queues_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_queues
    ADD CONSTRAINT decision_queues_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: decision_queues decision_queues_created_by_agent_api_key_id_agent_api_keys_id_f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_queues
    ADD CONSTRAINT decision_queues_created_by_agent_api_key_id_agent_api_keys_id_f FOREIGN KEY (created_by_agent_api_key_id) REFERENCES public.agent_api_keys(id);


--
-- Name: decision_queues decision_queues_created_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_queues
    ADD CONSTRAINT decision_queues_created_by_agent_id_agents_id_fk FOREIGN KEY (created_by_agent_id) REFERENCES public.agents(id);


--
-- Name: decision_queues decision_queues_created_by_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_queues
    ADD CONSTRAINT decision_queues_created_by_run_id_heartbeat_runs_id_fk FOREIGN KEY (created_by_run_id) REFERENCES public.heartbeat_runs(id);


--
-- Name: decision_retention decision_retention_archived_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_retention
    ADD CONSTRAINT decision_retention_archived_by_agent_id_agents_id_fk FOREIGN KEY (archived_by_agent_id) REFERENCES public.agents(id);


--
-- Name: decision_retention decision_retention_archived_by_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_retention
    ADD CONSTRAINT decision_retention_archived_by_run_id_heartbeat_runs_id_fk FOREIGN KEY (archived_by_run_id) REFERENCES public.heartbeat_runs(id);


--
-- Name: decision_retention decision_retention_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_retention
    ADD CONSTRAINT decision_retention_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: decision_target_issues decision_target_issues_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_target_issues
    ADD CONSTRAINT decision_target_issues_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: decision_target_issues decision_target_issues_decision_id_decisions_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_target_issues
    ADD CONSTRAINT decision_target_issues_decision_id_decisions_id_fk FOREIGN KEY (decision_id) REFERENCES public.decisions(id) ON DELETE CASCADE;


--
-- Name: decision_target_issues decision_target_issues_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_target_issues
    ADD CONSTRAINT decision_target_issues_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE CASCADE;


--
-- Name: decision_training_examples decision_training_examples_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_training_examples
    ADD CONSTRAINT decision_training_examples_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: decision_training_examples decision_training_examples_issue_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_training_examples
    ADD CONSTRAINT decision_training_examples_issue_id_fkey FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE CASCADE;


--
-- Name: decision_triage decision_triage_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_triage
    ADD CONSTRAINT decision_triage_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: decision_triage_events decision_triage_events_actor_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_triage_events
    ADD CONSTRAINT decision_triage_events_actor_agent_id_agents_id_fk FOREIGN KEY (actor_agent_id) REFERENCES public.agents(id);


--
-- Name: decision_triage_events decision_triage_events_actor_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_triage_events
    ADD CONSTRAINT decision_triage_events_actor_run_id_heartbeat_runs_id_fk FOREIGN KEY (actor_run_id) REFERENCES public.heartbeat_runs(id);


--
-- Name: decision_triage_events decision_triage_events_agent_api_key_id_agent_api_keys_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_triage_events
    ADD CONSTRAINT decision_triage_events_agent_api_key_id_agent_api_keys_id_fk FOREIGN KEY (agent_api_key_id) REFERENCES public.agent_api_keys(id);


--
-- Name: decision_triage_events decision_triage_events_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_triage_events
    ADD CONSTRAINT decision_triage_events_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: decision_triage_events decision_triage_events_queue_id_decision_queues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_triage_events
    ADD CONSTRAINT decision_triage_events_queue_id_decision_queues_id_fk FOREIGN KEY (queue_id) REFERENCES public.decision_queues(id);


--
-- Name: decision_triage decision_triage_set_by_agent_api_key_id_agent_api_keys_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_triage
    ADD CONSTRAINT decision_triage_set_by_agent_api_key_id_agent_api_keys_id_fk FOREIGN KEY (set_by_agent_api_key_id) REFERENCES public.agent_api_keys(id);


--
-- Name: decision_triage decision_triage_set_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_triage
    ADD CONSTRAINT decision_triage_set_by_agent_id_agents_id_fk FOREIGN KEY (set_by_agent_id) REFERENCES public.agents(id);


--
-- Name: decision_triage decision_triage_set_by_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_triage
    ADD CONSTRAINT decision_triage_set_by_run_id_heartbeat_runs_id_fk FOREIGN KEY (set_by_run_id) REFERENCES public.heartbeat_runs(id);


--
-- Name: decisions decisions_bundle_id_decision_bundles_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decisions
    ADD CONSTRAINT decisions_bundle_id_decision_bundles_id_fk FOREIGN KEY (bundle_id) REFERENCES public.decision_bundles(id) ON DELETE SET NULL;


--
-- Name: decisions decisions_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decisions
    ADD CONSTRAINT decisions_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: decisions decisions_origin_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decisions
    ADD CONSTRAINT decisions_origin_agent_id_agents_id_fk FOREIGN KEY (origin_agent_id) REFERENCES public.agents(id);


--
-- Name: decisions decisions_origin_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decisions
    ADD CONSTRAINT decisions_origin_issue_id_issues_id_fk FOREIGN KEY (origin_issue_id) REFERENCES public.issues(id);


--
-- Name: decisions decisions_origin_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decisions
    ADD CONSTRAINT decisions_origin_run_id_heartbeat_runs_id_fk FOREIGN KEY (origin_run_id) REFERENCES public.heartbeat_runs(id);


--
-- Name: document_annotation_anchor_snapshots document_annotation_anchor_snapshots_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_annotation_anchor_snapshots
    ADD CONSTRAINT document_annotation_anchor_snapshots_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: document_annotation_anchor_snapshots document_annotation_anchor_snapshots_document_id_documents_id_f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_annotation_anchor_snapshots
    ADD CONSTRAINT document_annotation_anchor_snapshots_document_id_documents_id_f FOREIGN KEY (document_id) REFERENCES public.documents(id) ON DELETE CASCADE;


--
-- Name: document_annotation_anchor_snapshots document_annotation_anchor_snapshots_from_revision_id_document_; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_annotation_anchor_snapshots
    ADD CONSTRAINT document_annotation_anchor_snapshots_from_revision_id_document_ FOREIGN KEY (from_revision_id) REFERENCES public.document_revisions(id) ON DELETE SET NULL;


--
-- Name: document_annotation_anchor_snapshots document_annotation_anchor_snapshots_thread_id_document_annotat; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_annotation_anchor_snapshots
    ADD CONSTRAINT document_annotation_anchor_snapshots_thread_id_document_annotat FOREIGN KEY (thread_id) REFERENCES public.document_annotation_threads(id) ON DELETE CASCADE;


--
-- Name: document_annotation_anchor_snapshots document_annotation_anchor_snapshots_to_revision_id_document_re; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_annotation_anchor_snapshots
    ADD CONSTRAINT document_annotation_anchor_snapshots_to_revision_id_document_re FOREIGN KEY (to_revision_id) REFERENCES public.document_revisions(id) ON DELETE SET NULL;


--
-- Name: document_annotation_comments document_annotation_comments_author_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_annotation_comments
    ADD CONSTRAINT document_annotation_comments_author_agent_id_agents_id_fk FOREIGN KEY (author_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: document_annotation_comments document_annotation_comments_case_id_cases_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_annotation_comments
    ADD CONSTRAINT document_annotation_comments_case_id_cases_id_fk FOREIGN KEY (case_id) REFERENCES public.cases(id) ON DELETE CASCADE;


--
-- Name: document_annotation_comments document_annotation_comments_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_annotation_comments
    ADD CONSTRAINT document_annotation_comments_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: document_annotation_comments document_annotation_comments_created_by_run_id_heartbeat_runs_i; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_annotation_comments
    ADD CONSTRAINT document_annotation_comments_created_by_run_id_heartbeat_runs_i FOREIGN KEY (created_by_run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL;


--
-- Name: document_annotation_comments document_annotation_comments_document_id_documents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_annotation_comments
    ADD CONSTRAINT document_annotation_comments_document_id_documents_id_fk FOREIGN KEY (document_id) REFERENCES public.documents(id) ON DELETE CASCADE;


--
-- Name: document_annotation_comments document_annotation_comments_issue_comment_id_issue_comments_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_annotation_comments
    ADD CONSTRAINT document_annotation_comments_issue_comment_id_issue_comments_id FOREIGN KEY (issue_comment_id) REFERENCES public.issue_comments(id) ON DELETE SET NULL;


--
-- Name: document_annotation_comments document_annotation_comments_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_annotation_comments
    ADD CONSTRAINT document_annotation_comments_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE CASCADE;


--
-- Name: document_annotation_comments document_annotation_comments_routine_id_routines_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_annotation_comments
    ADD CONSTRAINT document_annotation_comments_routine_id_routines_id_fk FOREIGN KEY (routine_id) REFERENCES public.routines(id) ON DELETE CASCADE;


--
-- Name: document_annotation_comments document_annotation_comments_thread_id_document_annotation_thre; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_annotation_comments
    ADD CONSTRAINT document_annotation_comments_thread_id_document_annotation_thre FOREIGN KEY (thread_id) REFERENCES public.document_annotation_threads(id) ON DELETE CASCADE;


--
-- Name: document_annotation_threads document_annotation_threads_case_id_cases_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_annotation_threads
    ADD CONSTRAINT document_annotation_threads_case_id_cases_id_fk FOREIGN KEY (case_id) REFERENCES public.cases(id) ON DELETE CASCADE;


--
-- Name: document_annotation_threads document_annotation_threads_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_annotation_threads
    ADD CONSTRAINT document_annotation_threads_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: document_annotation_threads document_annotation_threads_created_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_annotation_threads
    ADD CONSTRAINT document_annotation_threads_created_by_agent_id_agents_id_fk FOREIGN KEY (created_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: document_annotation_threads document_annotation_threads_current_revision_id_document_revisi; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_annotation_threads
    ADD CONSTRAINT document_annotation_threads_current_revision_id_document_revisi FOREIGN KEY (current_revision_id) REFERENCES public.document_revisions(id) ON DELETE SET NULL;


--
-- Name: document_annotation_threads document_annotation_threads_document_id_documents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_annotation_threads
    ADD CONSTRAINT document_annotation_threads_document_id_documents_id_fk FOREIGN KEY (document_id) REFERENCES public.documents(id) ON DELETE CASCADE;


--
-- Name: document_annotation_threads document_annotation_threads_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_annotation_threads
    ADD CONSTRAINT document_annotation_threads_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE CASCADE;


--
-- Name: document_annotation_threads document_annotation_threads_original_revision_id_document_revis; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_annotation_threads
    ADD CONSTRAINT document_annotation_threads_original_revision_id_document_revis FOREIGN KEY (original_revision_id) REFERENCES public.document_revisions(id) ON DELETE SET NULL;


--
-- Name: document_annotation_threads document_annotation_threads_resolved_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_annotation_threads
    ADD CONSTRAINT document_annotation_threads_resolved_by_agent_id_agents_id_fk FOREIGN KEY (resolved_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: document_annotation_threads document_annotation_threads_routine_id_routines_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_annotation_threads
    ADD CONSTRAINT document_annotation_threads_routine_id_routines_id_fk FOREIGN KEY (routine_id) REFERENCES public.routines(id) ON DELETE CASCADE;


--
-- Name: document_memberships document_memberships_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_memberships
    ADD CONSTRAINT document_memberships_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: document_memberships document_memberships_document_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_memberships
    ADD CONSTRAINT document_memberships_document_id_fkey FOREIGN KEY (document_id) REFERENCES public.documents(id) ON DELETE CASCADE;


--
-- Name: document_revisions document_revisions_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_revisions
    ADD CONSTRAINT document_revisions_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: document_revisions document_revisions_created_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_revisions
    ADD CONSTRAINT document_revisions_created_by_agent_id_agents_id_fk FOREIGN KEY (created_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL NOT VALID;


--
-- Name: document_revisions document_revisions_created_by_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_revisions
    ADD CONSTRAINT document_revisions_created_by_run_id_heartbeat_runs_id_fk FOREIGN KEY (created_by_run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL NOT VALID;


--
-- Name: document_revisions document_revisions_document_id_documents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_revisions
    ADD CONSTRAINT document_revisions_document_id_documents_id_fk FOREIGN KEY (document_id) REFERENCES public.documents(id) ON DELETE CASCADE NOT VALID;


--
-- Name: documents documents_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: documents documents_created_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_created_by_agent_id_agents_id_fk FOREIGN KEY (created_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL NOT VALID;


--
-- Name: documents documents_locked_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_locked_by_agent_id_agents_id_fk FOREIGN KEY (locked_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: documents documents_updated_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_updated_by_agent_id_agents_id_fk FOREIGN KEY (updated_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL NOT VALID;


--
-- Name: email_endpoints email_endpoints_company_id_endpoint_id_chat_endpoints_company_i; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_endpoints
    ADD CONSTRAINT email_endpoints_company_id_endpoint_id_chat_endpoints_company_i FOREIGN KEY (company_id, endpoint_id) REFERENCES public.chat_endpoints(company_id, id) ON DELETE CASCADE;


--
-- Name: email_messages email_messages_company_id_conversation_id_chat_conversations_co; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_messages
    ADD CONSTRAINT email_messages_company_id_conversation_id_chat_conversations_co FOREIGN KEY (company_id, conversation_id) REFERENCES public.chat_conversations(company_id, id) ON DELETE CASCADE;


--
-- Name: email_messages email_messages_company_id_endpoint_id_chat_endpoints_company_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_messages
    ADD CONSTRAINT email_messages_company_id_endpoint_id_chat_endpoints_company_id FOREIGN KEY (company_id, endpoint_id) REFERENCES public.chat_endpoints(company_id, id) ON DELETE CASCADE;


--
-- Name: email_sends email_sends_company_id_endpoint_id_chat_endpoints_company_id_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_sends
    ADD CONSTRAINT email_sends_company_id_endpoint_id_chat_endpoints_company_id_id FOREIGN KEY (company_id, endpoint_id) REFERENCES public.chat_endpoints(company_id, id) ON DELETE CASCADE;


--
-- Name: email_sends email_sends_company_id_publication_id_chat_publications_company; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_sends
    ADD CONSTRAINT email_sends_company_id_publication_id_chat_publications_company FOREIGN KEY (company_id, publication_id) REFERENCES public.chat_publications(company_id, id) ON DELETE CASCADE;


--
-- Name: environment_custom_image_setup_sessions environment_custom_image_setup_sessions_environment_id_environm; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.environment_custom_image_setup_sessions
    ADD CONSTRAINT environment_custom_image_setup_sessions_environment_id_environm FOREIGN KEY (environment_id) REFERENCES public.environments(id) ON DELETE CASCADE;


--
-- Name: environment_custom_image_setup_sessions environment_custom_image_setup_sessions_environment_lease_id_en; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.environment_custom_image_setup_sessions
    ADD CONSTRAINT environment_custom_image_setup_sessions_environment_lease_id_en FOREIGN KEY (environment_lease_id) REFERENCES public.environment_leases(id) ON DELETE SET NULL;


--
-- Name: environment_custom_image_setup_sessions environment_custom_image_setup_sessions_promoted_template_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.environment_custom_image_setup_sessions
    ADD CONSTRAINT environment_custom_image_setup_sessions_promoted_template_id_fk FOREIGN KEY (promoted_template_id) REFERENCES public.environment_custom_image_templates(id) ON DELETE SET NULL;


--
-- Name: environment_custom_image_setup_sessions environment_custom_image_setup_sessions_started_by_agent_id_age; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.environment_custom_image_setup_sessions
    ADD CONSTRAINT environment_custom_image_setup_sessions_started_by_agent_id_age FOREIGN KEY (started_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: environment_custom_image_setup_sessions environment_custom_image_setup_sessions_template_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.environment_custom_image_setup_sessions
    ADD CONSTRAINT environment_custom_image_setup_sessions_template_id_fk FOREIGN KEY (template_id) REFERENCES public.environment_custom_image_templates(id) ON DELETE SET NULL;


--
-- Name: environment_custom_image_templates environment_custom_image_templates_created_by_agent_id_agents_i; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.environment_custom_image_templates
    ADD CONSTRAINT environment_custom_image_templates_created_by_agent_id_agents_i FOREIGN KEY (created_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: environment_custom_image_templates environment_custom_image_templates_environment_id_environments_; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.environment_custom_image_templates
    ADD CONSTRAINT environment_custom_image_templates_environment_id_environments_ FOREIGN KEY (environment_id) REFERENCES public.environments(id) ON DELETE CASCADE;


--
-- Name: environment_custom_image_templates environment_custom_image_templates_superseded_by_template_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.environment_custom_image_templates
    ADD CONSTRAINT environment_custom_image_templates_superseded_by_template_id_fk FOREIGN KEY (superseded_by_template_id) REFERENCES public.environment_custom_image_templates(id) ON DELETE SET NULL;


--
-- Name: environment_leases environment_leases_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.environment_leases
    ADD CONSTRAINT environment_leases_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE NOT VALID;


--
-- Name: environment_leases environment_leases_environment_id_environments_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.environment_leases
    ADD CONSTRAINT environment_leases_environment_id_environments_id_fk FOREIGN KEY (environment_id) REFERENCES public.environments(id) ON DELETE SET NULL;


--
-- Name: environment_leases environment_leases_execution_workspace_id_execution_workspaces_; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.environment_leases
    ADD CONSTRAINT environment_leases_execution_workspace_id_execution_workspaces_ FOREIGN KEY (execution_workspace_id) REFERENCES public.execution_workspaces(id) ON DELETE SET NULL NOT VALID;


--
-- Name: environment_leases environment_leases_heartbeat_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.environment_leases
    ADD CONSTRAINT environment_leases_heartbeat_run_id_heartbeat_runs_id_fk FOREIGN KEY (heartbeat_run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL NOT VALID;


--
-- Name: environment_leases environment_leases_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.environment_leases
    ADD CONSTRAINT environment_leases_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE SET NULL NOT VALID;


--
-- Name: execution_workspace_runtime_leases execution_workspace_runtime_leases_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_workspace_runtime_leases
    ADD CONSTRAINT execution_workspace_runtime_leases_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: execution_workspace_runtime_leases execution_workspace_runtime_leases_execution_workspace_id_execu; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_workspace_runtime_leases
    ADD CONSTRAINT execution_workspace_runtime_leases_execution_workspace_id_execu FOREIGN KEY (execution_workspace_id) REFERENCES public.execution_workspaces(id) ON DELETE CASCADE;


--
-- Name: execution_workspace_runtime_leases execution_workspace_runtime_leases_owner_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_workspace_runtime_leases
    ADD CONSTRAINT execution_workspace_runtime_leases_owner_agent_id_agents_id_fk FOREIGN KEY (owner_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: execution_workspace_runtime_leases execution_workspace_runtime_leases_owner_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_workspace_runtime_leases
    ADD CONSTRAINT execution_workspace_runtime_leases_owner_issue_id_issues_id_fk FOREIGN KEY (owner_issue_id) REFERENCES public.issues(id) ON DELETE SET NULL;


--
-- Name: execution_workspace_runtime_leases execution_workspace_runtime_leases_owner_run_id_heartbeat_runs_; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_workspace_runtime_leases
    ADD CONSTRAINT execution_workspace_runtime_leases_owner_run_id_heartbeat_runs_ FOREIGN KEY (owner_run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL;


--
-- Name: execution_workspaces execution_workspaces_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_workspaces
    ADD CONSTRAINT execution_workspaces_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: execution_workspaces execution_workspaces_derived_from_execution_workspace_id_execut; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_workspaces
    ADD CONSTRAINT execution_workspaces_derived_from_execution_workspace_id_execut FOREIGN KEY (derived_from_execution_workspace_id) REFERENCES public.execution_workspaces(id) ON DELETE SET NULL NOT VALID;


--
-- Name: execution_workspaces execution_workspaces_project_id_projects_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_workspaces
    ADD CONSTRAINT execution_workspaces_project_id_projects_id_fk FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE NOT VALID;


--
-- Name: execution_workspaces execution_workspaces_project_workspace_id_project_workspaces_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_workspaces
    ADD CONSTRAINT execution_workspaces_project_workspace_id_project_workspaces_id FOREIGN KEY (project_workspace_id) REFERENCES public.project_workspaces(id) ON DELETE SET NULL NOT VALID;


--
-- Name: execution_workspaces execution_workspaces_source_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_workspaces
    ADD CONSTRAINT execution_workspaces_source_issue_id_issues_id_fk FOREIGN KEY (source_issue_id) REFERENCES public.issues(id) ON DELETE SET NULL NOT VALID;


--
-- Name: external_object_mentions external_object_mentions_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.external_object_mentions
    ADD CONSTRAINT external_object_mentions_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: external_object_mentions external_object_mentions_created_by_plugin_id_plugins_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.external_object_mentions
    ADD CONSTRAINT external_object_mentions_created_by_plugin_id_plugins_id_fk FOREIGN KEY (created_by_plugin_id) REFERENCES public.plugins(id) ON DELETE SET NULL;


--
-- Name: external_object_mentions external_object_mentions_object_id_external_objects_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.external_object_mentions
    ADD CONSTRAINT external_object_mentions_object_id_external_objects_id_fk FOREIGN KEY (object_id) REFERENCES public.external_objects(id) ON DELETE SET NULL;


--
-- Name: external_object_mentions external_object_mentions_source_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.external_object_mentions
    ADD CONSTRAINT external_object_mentions_source_issue_id_issues_id_fk FOREIGN KEY (source_issue_id) REFERENCES public.issues(id) ON DELETE CASCADE;


--
-- Name: external_objects external_objects_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.external_objects
    ADD CONSTRAINT external_objects_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: external_objects external_objects_plugin_id_plugins_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.external_objects
    ADD CONSTRAINT external_objects_plugin_id_plugins_id_fk FOREIGN KEY (plugin_id) REFERENCES public.plugins(id) ON DELETE SET NULL;


--
-- Name: feedback_exports feedback_exports_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.feedback_exports
    ADD CONSTRAINT feedback_exports_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: feedback_exports feedback_exports_feedback_vote_id_feedback_votes_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.feedback_exports
    ADD CONSTRAINT feedback_exports_feedback_vote_id_feedback_votes_id_fk FOREIGN KEY (feedback_vote_id) REFERENCES public.feedback_votes(id) ON DELETE CASCADE NOT VALID;


--
-- Name: feedback_exports feedback_exports_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.feedback_exports
    ADD CONSTRAINT feedback_exports_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE CASCADE NOT VALID;


--
-- Name: feedback_exports feedback_exports_project_id_projects_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.feedback_exports
    ADD CONSTRAINT feedback_exports_project_id_projects_id_fk FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE SET NULL NOT VALID;


--
-- Name: feedback_votes feedback_votes_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.feedback_votes
    ADD CONSTRAINT feedback_votes_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: feedback_votes feedback_votes_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.feedback_votes
    ADD CONSTRAINT feedback_votes_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE CASCADE;


--
-- Name: finance_events finance_events_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finance_events
    ADD CONSTRAINT finance_events_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES public.agents(id) NOT VALID;


--
-- Name: finance_events finance_events_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finance_events
    ADD CONSTRAINT finance_events_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: finance_events finance_events_cost_event_id_cost_events_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finance_events
    ADD CONSTRAINT finance_events_cost_event_id_cost_events_id_fk FOREIGN KEY (cost_event_id) REFERENCES public.cost_events(id) NOT VALID;


--
-- Name: finance_events finance_events_goal_id_goals_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finance_events
    ADD CONSTRAINT finance_events_goal_id_goals_id_fk FOREIGN KEY (goal_id) REFERENCES public.goals(id) NOT VALID;


--
-- Name: finance_events finance_events_heartbeat_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finance_events
    ADD CONSTRAINT finance_events_heartbeat_run_id_heartbeat_runs_id_fk FOREIGN KEY (heartbeat_run_id) REFERENCES public.heartbeat_runs(id) NOT VALID;


--
-- Name: finance_events finance_events_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finance_events
    ADD CONSTRAINT finance_events_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE SET NULL;


--
-- Name: finance_events finance_events_project_id_projects_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finance_events
    ADD CONSTRAINT finance_events_project_id_projects_id_fk FOREIGN KEY (project_id) REFERENCES public.projects(id) NOT VALID;


--
-- Name: folders folders_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.folders
    ADD CONSTRAINT folders_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: folders folders_parent_id_folders_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.folders
    ADD CONSTRAINT folders_parent_id_folders_id_fk FOREIGN KEY (parent_id) REFERENCES public.folders(id) ON DELETE RESTRICT;


--
-- Name: goals goals_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goals
    ADD CONSTRAINT goals_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: goals goals_owner_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goals
    ADD CONSTRAINT goals_owner_agent_id_agents_id_fk FOREIGN KEY (owner_agent_id) REFERENCES public.agents(id) NOT VALID;


--
-- Name: goals goals_parent_id_goals_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goals
    ADD CONSTRAINT goals_parent_id_goals_id_fk FOREIGN KEY (parent_id) REFERENCES public.goals(id) NOT VALID;


--
-- Name: heartbeat_run_events heartbeat_run_events_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.heartbeat_run_events
    ADD CONSTRAINT heartbeat_run_events_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES public.agents(id) NOT VALID;


--
-- Name: heartbeat_run_events heartbeat_run_events_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.heartbeat_run_events
    ADD CONSTRAINT heartbeat_run_events_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: heartbeat_run_events heartbeat_run_events_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.heartbeat_run_events
    ADD CONSTRAINT heartbeat_run_events_run_id_heartbeat_runs_id_fk FOREIGN KEY (run_id) REFERENCES public.heartbeat_runs(id) NOT VALID;


--
-- Name: heartbeat_run_watchdog_decisions heartbeat_run_watchdog_decisions_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.heartbeat_run_watchdog_decisions
    ADD CONSTRAINT heartbeat_run_watchdog_decisions_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: heartbeat_run_watchdog_decisions heartbeat_run_watchdog_decisions_created_by_agent_id_agents_id_; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.heartbeat_run_watchdog_decisions
    ADD CONSTRAINT heartbeat_run_watchdog_decisions_created_by_agent_id_agents_id_ FOREIGN KEY (created_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL NOT VALID;


--
-- Name: heartbeat_run_watchdog_decisions heartbeat_run_watchdog_decisions_created_by_run_id_heartbeat_ru; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.heartbeat_run_watchdog_decisions
    ADD CONSTRAINT heartbeat_run_watchdog_decisions_created_by_run_id_heartbeat_ru FOREIGN KEY (created_by_run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL NOT VALID;


--
-- Name: heartbeat_run_watchdog_decisions heartbeat_run_watchdog_decisions_evaluation_issue_id_issues_id_; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.heartbeat_run_watchdog_decisions
    ADD CONSTRAINT heartbeat_run_watchdog_decisions_evaluation_issue_id_issues_id_ FOREIGN KEY (evaluation_issue_id) REFERENCES public.issues(id) ON DELETE SET NULL NOT VALID;


--
-- Name: heartbeat_run_watchdog_decisions heartbeat_run_watchdog_decisions_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.heartbeat_run_watchdog_decisions
    ADD CONSTRAINT heartbeat_run_watchdog_decisions_run_id_heartbeat_runs_id_fk FOREIGN KEY (run_id) REFERENCES public.heartbeat_runs(id) ON DELETE CASCADE NOT VALID;


--
-- Name: heartbeat_runs heartbeat_runs_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.heartbeat_runs
    ADD CONSTRAINT heartbeat_runs_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES public.agents(id) NOT VALID;


--
-- Name: heartbeat_runs heartbeat_runs_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.heartbeat_runs
    ADD CONSTRAINT heartbeat_runs_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: heartbeat_runs heartbeat_runs_retry_of_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.heartbeat_runs
    ADD CONSTRAINT heartbeat_runs_retry_of_run_id_heartbeat_runs_id_fk FOREIGN KEY (retry_of_run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL NOT VALID;


--
-- Name: heartbeat_runs heartbeat_runs_wakeup_request_id_agent_wakeup_requests_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.heartbeat_runs
    ADD CONSTRAINT heartbeat_runs_wakeup_request_id_agent_wakeup_requests_id_fk FOREIGN KEY (wakeup_request_id) REFERENCES public.agent_wakeup_requests(id) NOT VALID;


--
-- Name: inbox_dismissals inbox_dismissals_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inbox_dismissals
    ADD CONSTRAINT inbox_dismissals_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: instance_settings instance_settings_default_environment_id_environments_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.instance_settings
    ADD CONSTRAINT instance_settings_default_environment_id_environments_id_fk FOREIGN KEY (default_environment_id) REFERENCES public.environments(id) ON DELETE SET NULL;


--
-- Name: invites invites_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invites
    ADD CONSTRAINT invites_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: issue_approvals issue_approvals_approval_id_approvals_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_approvals
    ADD CONSTRAINT issue_approvals_approval_id_approvals_id_fk FOREIGN KEY (approval_id) REFERENCES public.approvals(id) ON DELETE CASCADE NOT VALID;


--
-- Name: issue_approvals issue_approvals_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_approvals
    ADD CONSTRAINT issue_approvals_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: issue_approvals issue_approvals_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_approvals
    ADD CONSTRAINT issue_approvals_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE CASCADE NOT VALID;


--
-- Name: issue_approvals issue_approvals_linked_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_approvals
    ADD CONSTRAINT issue_approvals_linked_by_agent_id_agents_id_fk FOREIGN KEY (linked_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL NOT VALID;


--
-- Name: issue_attachments issue_attachments_asset_id_assets_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_attachments
    ADD CONSTRAINT issue_attachments_asset_id_assets_id_fk FOREIGN KEY (asset_id) REFERENCES public.assets(id) ON DELETE CASCADE NOT VALID;


--
-- Name: issue_attachments issue_attachments_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_attachments
    ADD CONSTRAINT issue_attachments_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: issue_attachments issue_attachments_issue_comment_id_issue_comments_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_attachments
    ADD CONSTRAINT issue_attachments_issue_comment_id_issue_comments_id_fk FOREIGN KEY (issue_comment_id) REFERENCES public.issue_comments(id) ON DELETE SET NULL NOT VALID;


--
-- Name: issue_attachments issue_attachments_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_attachments
    ADD CONSTRAINT issue_attachments_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE CASCADE NOT VALID;


--
-- Name: issue_attachments issue_attachments_originating_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_attachments
    ADD CONSTRAINT issue_attachments_originating_run_id_heartbeat_runs_id_fk FOREIGN KEY (originating_run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL;


--
-- Name: issue_comments issue_comments_author_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_comments
    ADD CONSTRAINT issue_comments_author_agent_id_agents_id_fk FOREIGN KEY (author_agent_id) REFERENCES public.agents(id) NOT VALID;


--
-- Name: issue_comments issue_comments_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_comments
    ADD CONSTRAINT issue_comments_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: issue_comments issue_comments_created_by_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_comments
    ADD CONSTRAINT issue_comments_created_by_run_id_heartbeat_runs_id_fk FOREIGN KEY (created_by_run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL NOT VALID;


--
-- Name: issue_comments issue_comments_deleted_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_comments
    ADD CONSTRAINT issue_comments_deleted_by_agent_id_agents_id_fk FOREIGN KEY (deleted_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: issue_comments issue_comments_deleted_by_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_comments
    ADD CONSTRAINT issue_comments_deleted_by_run_id_heartbeat_runs_id_fk FOREIGN KEY (deleted_by_run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL;


--
-- Name: issue_comments issue_comments_derived_author_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_comments
    ADD CONSTRAINT issue_comments_derived_author_agent_id_agents_id_fk FOREIGN KEY (derived_author_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: issue_comments issue_comments_derived_created_by_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_comments
    ADD CONSTRAINT issue_comments_derived_created_by_run_id_heartbeat_runs_id_fk FOREIGN KEY (derived_created_by_run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL;


--
-- Name: issue_comments issue_comments_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_comments
    ADD CONSTRAINT issue_comments_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE CASCADE;


--
-- Name: issue_comments issue_comments_on_behalf_of_user_id_user_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_comments
    ADD CONSTRAINT issue_comments_on_behalf_of_user_id_user_id_fk FOREIGN KEY (on_behalf_of_user_id) REFERENCES public."user"(id) ON DELETE SET NULL;


--
-- Name: issue_create_idempotency_keys issue_create_idempotency_keys_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_create_idempotency_keys
    ADD CONSTRAINT issue_create_idempotency_keys_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: issue_create_idempotency_keys issue_create_idempotency_keys_issue_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_create_idempotency_keys
    ADD CONSTRAINT issue_create_idempotency_keys_issue_id_fkey FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE CASCADE;


--
-- Name: issue_documents issue_documents_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_documents
    ADD CONSTRAINT issue_documents_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: issue_documents issue_documents_document_id_documents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_documents
    ADD CONSTRAINT issue_documents_document_id_documents_id_fk FOREIGN KEY (document_id) REFERENCES public.documents(id) ON DELETE CASCADE NOT VALID;


--
-- Name: issue_documents issue_documents_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_documents
    ADD CONSTRAINT issue_documents_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE CASCADE NOT VALID;


--
-- Name: issue_execution_decisions issue_execution_decisions_actor_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_execution_decisions
    ADD CONSTRAINT issue_execution_decisions_actor_agent_id_agents_id_fk FOREIGN KEY (actor_agent_id) REFERENCES public.agents(id) NOT VALID;


--
-- Name: issue_execution_decisions issue_execution_decisions_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_execution_decisions
    ADD CONSTRAINT issue_execution_decisions_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: issue_execution_decisions issue_execution_decisions_created_by_run_id_heartbeat_runs_id_f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_execution_decisions
    ADD CONSTRAINT issue_execution_decisions_created_by_run_id_heartbeat_runs_id_f FOREIGN KEY (created_by_run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL NOT VALID;


--
-- Name: issue_execution_decisions issue_execution_decisions_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_execution_decisions
    ADD CONSTRAINT issue_execution_decisions_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE CASCADE NOT VALID;


--
-- Name: issue_inbox_archives issue_inbox_archives_archived_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_inbox_archives
    ADD CONSTRAINT issue_inbox_archives_archived_by_agent_id_agents_id_fk FOREIGN KEY (archived_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: issue_inbox_archives issue_inbox_archives_archived_by_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_inbox_archives
    ADD CONSTRAINT issue_inbox_archives_archived_by_run_id_heartbeat_runs_id_fk FOREIGN KEY (archived_by_run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL;


--
-- Name: issue_inbox_archives issue_inbox_archives_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_inbox_archives
    ADD CONSTRAINT issue_inbox_archives_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: issue_inbox_archives issue_inbox_archives_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_inbox_archives
    ADD CONSTRAINT issue_inbox_archives_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE CASCADE;


--
-- Name: issue_labels issue_labels_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_labels
    ADD CONSTRAINT issue_labels_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE NOT VALID;


--
-- Name: issue_labels issue_labels_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_labels
    ADD CONSTRAINT issue_labels_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE CASCADE NOT VALID;


--
-- Name: issue_labels issue_labels_label_id_labels_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_labels
    ADD CONSTRAINT issue_labels_label_id_labels_id_fk FOREIGN KEY (label_id) REFERENCES public.labels(id) ON DELETE CASCADE NOT VALID;


--
-- Name: issue_plan_decompositions issue_plan_decompositions_accepted_interaction_id_issue_thread_; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_plan_decompositions
    ADD CONSTRAINT issue_plan_decompositions_accepted_interaction_id_issue_thread_ FOREIGN KEY (accepted_interaction_id) REFERENCES public.issue_thread_interactions(id) ON DELETE SET NULL;


--
-- Name: issue_plan_decompositions issue_plan_decompositions_accepted_plan_revision_id_document_re; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_plan_decompositions
    ADD CONSTRAINT issue_plan_decompositions_accepted_plan_revision_id_document_re FOREIGN KEY (accepted_plan_revision_id) REFERENCES public.document_revisions(id) ON DELETE CASCADE;


--
-- Name: issue_plan_decompositions issue_plan_decompositions_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_plan_decompositions
    ADD CONSTRAINT issue_plan_decompositions_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: issue_plan_decompositions issue_plan_decompositions_owner_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_plan_decompositions
    ADD CONSTRAINT issue_plan_decompositions_owner_agent_id_agents_id_fk FOREIGN KEY (owner_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: issue_plan_decompositions issue_plan_decompositions_owner_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_plan_decompositions
    ADD CONSTRAINT issue_plan_decompositions_owner_run_id_heartbeat_runs_id_fk FOREIGN KEY (owner_run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL;


--
-- Name: issue_plan_decompositions issue_plan_decompositions_source_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_plan_decompositions
    ADD CONSTRAINT issue_plan_decompositions_source_issue_id_issues_id_fk FOREIGN KEY (source_issue_id) REFERENCES public.issues(id) ON DELETE CASCADE;


--
-- Name: issue_question_response_deliveries issue_question_response_deliveries_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_question_response_deliveries
    ADD CONSTRAINT issue_question_response_deliveries_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: issue_question_response_deliveries issue_question_response_deliveries_interaction_id_issue_thread_; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_question_response_deliveries
    ADD CONSTRAINT issue_question_response_deliveries_interaction_id_issue_thread_ FOREIGN KEY (interaction_id) REFERENCES public.issue_thread_interactions(id) ON DELETE CASCADE;


--
-- Name: issue_question_response_deliveries issue_question_response_deliveries_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_question_response_deliveries
    ADD CONSTRAINT issue_question_response_deliveries_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE CASCADE;


--
-- Name: issue_question_response_deliveries issue_question_response_deliveries_source_run_id_heartbeat_runs; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_question_response_deliveries
    ADD CONSTRAINT issue_question_response_deliveries_source_run_id_heartbeat_runs FOREIGN KEY (source_run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL;


--
-- Name: issue_question_response_deliveries issue_question_response_deliveries_target_run_id_heartbeat_runs; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_question_response_deliveries
    ADD CONSTRAINT issue_question_response_deliveries_target_run_id_heartbeat_runs FOREIGN KEY (target_run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL;


--
-- Name: issue_read_states issue_read_states_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_read_states
    ADD CONSTRAINT issue_read_states_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: issue_read_states issue_read_states_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_read_states
    ADD CONSTRAINT issue_read_states_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE CASCADE;


--
-- Name: issue_recovery_actions issue_recovery_actions_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_recovery_actions
    ADD CONSTRAINT issue_recovery_actions_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: issue_recovery_actions issue_recovery_actions_corrective_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_recovery_actions
    ADD CONSTRAINT issue_recovery_actions_corrective_run_id_heartbeat_runs_id_fk FOREIGN KEY (corrective_run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL;


--
-- Name: issue_recovery_actions issue_recovery_actions_corrective_wakeup_request_id_agent_wakeu; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_recovery_actions
    ADD CONSTRAINT issue_recovery_actions_corrective_wakeup_request_id_agent_wakeu FOREIGN KEY (corrective_wakeup_request_id) REFERENCES public.agent_wakeup_requests(id) ON DELETE SET NULL;


--
-- Name: issue_recovery_actions issue_recovery_actions_owner_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_recovery_actions
    ADD CONSTRAINT issue_recovery_actions_owner_agent_id_agents_id_fk FOREIGN KEY (owner_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: issue_recovery_actions issue_recovery_actions_previous_owner_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_recovery_actions
    ADD CONSTRAINT issue_recovery_actions_previous_owner_agent_id_agents_id_fk FOREIGN KEY (previous_owner_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: issue_recovery_actions issue_recovery_actions_recovery_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_recovery_actions
    ADD CONSTRAINT issue_recovery_actions_recovery_issue_id_issues_id_fk FOREIGN KEY (recovery_issue_id) REFERENCES public.issues(id) ON DELETE SET NULL;


--
-- Name: issue_recovery_actions issue_recovery_actions_return_owner_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_recovery_actions
    ADD CONSTRAINT issue_recovery_actions_return_owner_agent_id_agents_id_fk FOREIGN KEY (return_owner_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: issue_recovery_actions issue_recovery_actions_source_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_recovery_actions
    ADD CONSTRAINT issue_recovery_actions_source_issue_id_issues_id_fk FOREIGN KEY (source_issue_id) REFERENCES public.issues(id) ON DELETE CASCADE;


--
-- Name: issue_reference_mentions issue_reference_mentions_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_reference_mentions
    ADD CONSTRAINT issue_reference_mentions_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: issue_reference_mentions issue_reference_mentions_source_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_reference_mentions
    ADD CONSTRAINT issue_reference_mentions_source_issue_id_issues_id_fk FOREIGN KEY (source_issue_id) REFERENCES public.issues(id) ON DELETE CASCADE NOT VALID;


--
-- Name: issue_reference_mentions issue_reference_mentions_target_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_reference_mentions
    ADD CONSTRAINT issue_reference_mentions_target_issue_id_issues_id_fk FOREIGN KEY (target_issue_id) REFERENCES public.issues(id) ON DELETE CASCADE NOT VALID;


--
-- Name: issue_relations issue_relations_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_relations
    ADD CONSTRAINT issue_relations_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: issue_relations issue_relations_created_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_relations
    ADD CONSTRAINT issue_relations_created_by_agent_id_agents_id_fk FOREIGN KEY (created_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL NOT VALID;


--
-- Name: issue_relations issue_relations_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_relations
    ADD CONSTRAINT issue_relations_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE CASCADE NOT VALID;


--
-- Name: issue_relations issue_relations_related_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_relations
    ADD CONSTRAINT issue_relations_related_issue_id_issues_id_fk FOREIGN KEY (related_issue_id) REFERENCES public.issues(id) ON DELETE CASCADE NOT VALID;


--
-- Name: issue_thread_interactions issue_thread_interactions_addressee_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_thread_interactions
    ADD CONSTRAINT issue_thread_interactions_addressee_agent_id_agents_id_fk FOREIGN KEY (addressee_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: issue_thread_interactions issue_thread_interactions_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_thread_interactions
    ADD CONSTRAINT issue_thread_interactions_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: issue_thread_interactions issue_thread_interactions_created_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_thread_interactions
    ADD CONSTRAINT issue_thread_interactions_created_by_agent_id_agents_id_fk FOREIGN KEY (created_by_agent_id) REFERENCES public.agents(id) NOT VALID;


--
-- Name: issue_thread_interactions issue_thread_interactions_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_thread_interactions
    ADD CONSTRAINT issue_thread_interactions_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE CASCADE;


--
-- Name: issue_thread_interactions issue_thread_interactions_resolved_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_thread_interactions
    ADD CONSTRAINT issue_thread_interactions_resolved_by_agent_id_agents_id_fk FOREIGN KEY (resolved_by_agent_id) REFERENCES public.agents(id) NOT VALID;


--
-- Name: issue_thread_interactions issue_thread_interactions_resolved_by_run_id_heartbeat_runs_id_; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_thread_interactions
    ADD CONSTRAINT issue_thread_interactions_resolved_by_run_id_heartbeat_runs_id_ FOREIGN KEY (resolved_by_run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL;


--
-- Name: issue_thread_interactions issue_thread_interactions_source_comment_id_issue_comments_id_f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_thread_interactions
    ADD CONSTRAINT issue_thread_interactions_source_comment_id_issue_comments_id_f FOREIGN KEY (source_comment_id) REFERENCES public.issue_comments(id) ON DELETE SET NULL NOT VALID;


--
-- Name: issue_thread_interactions issue_thread_interactions_source_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_thread_interactions
    ADD CONSTRAINT issue_thread_interactions_source_run_id_heartbeat_runs_id_fk FOREIGN KEY (source_run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL NOT VALID;


--
-- Name: issue_tree_hold_members issue_tree_hold_members_active_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_tree_hold_members
    ADD CONSTRAINT issue_tree_hold_members_active_run_id_heartbeat_runs_id_fk FOREIGN KEY (active_run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL NOT VALID;


--
-- Name: issue_tree_hold_members issue_tree_hold_members_assignee_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_tree_hold_members
    ADD CONSTRAINT issue_tree_hold_members_assignee_agent_id_agents_id_fk FOREIGN KEY (assignee_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL NOT VALID;


--
-- Name: issue_tree_hold_members issue_tree_hold_members_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_tree_hold_members
    ADD CONSTRAINT issue_tree_hold_members_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: issue_tree_hold_members issue_tree_hold_members_hold_id_issue_tree_holds_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_tree_hold_members
    ADD CONSTRAINT issue_tree_hold_members_hold_id_issue_tree_holds_id_fk FOREIGN KEY (hold_id) REFERENCES public.issue_tree_holds(id) ON DELETE CASCADE NOT VALID;


--
-- Name: issue_tree_hold_members issue_tree_hold_members_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_tree_hold_members
    ADD CONSTRAINT issue_tree_hold_members_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE CASCADE NOT VALID;


--
-- Name: issue_tree_hold_members issue_tree_hold_members_parent_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_tree_hold_members
    ADD CONSTRAINT issue_tree_hold_members_parent_issue_id_issues_id_fk FOREIGN KEY (parent_issue_id) REFERENCES public.issues(id) ON DELETE SET NULL NOT VALID;


--
-- Name: issue_tree_holds issue_tree_holds_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_tree_holds
    ADD CONSTRAINT issue_tree_holds_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: issue_tree_holds issue_tree_holds_created_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_tree_holds
    ADD CONSTRAINT issue_tree_holds_created_by_agent_id_agents_id_fk FOREIGN KEY (created_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL NOT VALID;


--
-- Name: issue_tree_holds issue_tree_holds_created_by_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_tree_holds
    ADD CONSTRAINT issue_tree_holds_created_by_run_id_heartbeat_runs_id_fk FOREIGN KEY (created_by_run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL NOT VALID;


--
-- Name: issue_tree_holds issue_tree_holds_released_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_tree_holds
    ADD CONSTRAINT issue_tree_holds_released_by_agent_id_agents_id_fk FOREIGN KEY (released_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL NOT VALID;


--
-- Name: issue_tree_holds issue_tree_holds_released_by_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_tree_holds
    ADD CONSTRAINT issue_tree_holds_released_by_run_id_heartbeat_runs_id_fk FOREIGN KEY (released_by_run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL NOT VALID;


--
-- Name: issue_tree_holds issue_tree_holds_root_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_tree_holds
    ADD CONSTRAINT issue_tree_holds_root_issue_id_issues_id_fk FOREIGN KEY (root_issue_id) REFERENCES public.issues(id) ON DELETE CASCADE NOT VALID;


--
-- Name: issue_watchdogs issue_watchdogs_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_watchdogs
    ADD CONSTRAINT issue_watchdogs_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: issue_watchdogs issue_watchdogs_created_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_watchdogs
    ADD CONSTRAINT issue_watchdogs_created_by_agent_id_agents_id_fk FOREIGN KEY (created_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: issue_watchdogs issue_watchdogs_created_by_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_watchdogs
    ADD CONSTRAINT issue_watchdogs_created_by_run_id_heartbeat_runs_id_fk FOREIGN KEY (created_by_run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL;


--
-- Name: issue_watchdogs issue_watchdogs_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_watchdogs
    ADD CONSTRAINT issue_watchdogs_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE CASCADE;


--
-- Name: issue_watchdogs issue_watchdogs_updated_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_watchdogs
    ADD CONSTRAINT issue_watchdogs_updated_by_agent_id_agents_id_fk FOREIGN KEY (updated_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: issue_watchdogs issue_watchdogs_updated_by_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_watchdogs
    ADD CONSTRAINT issue_watchdogs_updated_by_run_id_heartbeat_runs_id_fk FOREIGN KEY (updated_by_run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL;


--
-- Name: issue_watchdogs issue_watchdogs_watchdog_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_watchdogs
    ADD CONSTRAINT issue_watchdogs_watchdog_agent_id_agents_id_fk FOREIGN KEY (watchdog_agent_id) REFERENCES public.agents(id);


--
-- Name: issue_watchdogs issue_watchdogs_watchdog_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_watchdogs
    ADD CONSTRAINT issue_watchdogs_watchdog_issue_id_issues_id_fk FOREIGN KEY (watchdog_issue_id) REFERENCES public.issues(id) ON DELETE SET NULL;


--
-- Name: issue_work_products issue_work_products_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_work_products
    ADD CONSTRAINT issue_work_products_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: issue_work_products issue_work_products_created_by_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_work_products
    ADD CONSTRAINT issue_work_products_created_by_run_id_heartbeat_runs_id_fk FOREIGN KEY (created_by_run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL NOT VALID;


--
-- Name: issue_work_products issue_work_products_execution_workspace_id_execution_workspaces; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_work_products
    ADD CONSTRAINT issue_work_products_execution_workspace_id_execution_workspaces FOREIGN KEY (execution_workspace_id) REFERENCES public.execution_workspaces(id) ON DELETE SET NULL NOT VALID;


--
-- Name: issue_work_products issue_work_products_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_work_products
    ADD CONSTRAINT issue_work_products_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE CASCADE NOT VALID;


--
-- Name: issue_work_products issue_work_products_project_id_projects_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_work_products
    ADD CONSTRAINT issue_work_products_project_id_projects_id_fk FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE SET NULL NOT VALID;


--
-- Name: issue_work_products issue_work_products_runtime_service_id_workspace_runtime_servic; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_work_products
    ADD CONSTRAINT issue_work_products_runtime_service_id_workspace_runtime_servic FOREIGN KEY (runtime_service_id) REFERENCES public.workspace_runtime_services(id) ON DELETE SET NULL NOT VALID;


--
-- Name: issues issues_assignee_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issues
    ADD CONSTRAINT issues_assignee_agent_id_agents_id_fk FOREIGN KEY (assignee_agent_id) REFERENCES public.agents(id) NOT VALID;


--
-- Name: issues issues_checkout_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issues
    ADD CONSTRAINT issues_checkout_run_id_heartbeat_runs_id_fk FOREIGN KEY (checkout_run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL NOT VALID;


--
-- Name: issues issues_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issues
    ADD CONSTRAINT issues_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: issues issues_conversation_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issues
    ADD CONSTRAINT issues_conversation_agent_id_agents_id_fk FOREIGN KEY (conversation_agent_id) REFERENCES public.agents(id);


--
-- Name: issues issues_created_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issues
    ADD CONSTRAINT issues_created_by_agent_id_agents_id_fk FOREIGN KEY (created_by_agent_id) REFERENCES public.agents(id) NOT VALID;


--
-- Name: issues issues_execution_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issues
    ADD CONSTRAINT issues_execution_run_id_heartbeat_runs_id_fk FOREIGN KEY (execution_run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL NOT VALID;


--
-- Name: issues issues_execution_workspace_id_execution_workspaces_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issues
    ADD CONSTRAINT issues_execution_workspace_id_execution_workspaces_id_fk FOREIGN KEY (execution_workspace_id) REFERENCES public.execution_workspaces(id) ON DELETE SET NULL NOT VALID;


--
-- Name: issues issues_goal_id_goals_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issues
    ADD CONSTRAINT issues_goal_id_goals_id_fk FOREIGN KEY (goal_id) REFERENCES public.goals(id) NOT VALID;


--
-- Name: issues issues_parent_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issues
    ADD CONSTRAINT issues_parent_id_issues_id_fk FOREIGN KEY (parent_id) REFERENCES public.issues(id) NOT VALID;


--
-- Name: issues issues_project_id_projects_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issues
    ADD CONSTRAINT issues_project_id_projects_id_fk FOREIGN KEY (project_id) REFERENCES public.projects(id) NOT VALID;


--
-- Name: issues issues_project_workspace_id_project_workspaces_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issues
    ADD CONSTRAINT issues_project_workspace_id_project_workspaces_id_fk FOREIGN KEY (project_workspace_id) REFERENCES public.project_workspaces(id) ON DELETE SET NULL NOT VALID;


--
-- Name: join_requests join_requests_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.join_requests
    ADD CONSTRAINT join_requests_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: join_requests join_requests_created_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.join_requests
    ADD CONSTRAINT join_requests_created_agent_id_agents_id_fk FOREIGN KEY (created_agent_id) REFERENCES public.agents(id) NOT VALID;


--
-- Name: join_requests join_requests_invite_id_invites_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.join_requests
    ADD CONSTRAINT join_requests_invite_id_invites_id_fk FOREIGN KEY (invite_id) REFERENCES public.invites(id) NOT VALID;


--
-- Name: labels labels_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.labels
    ADD CONSTRAINT labels_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE NOT VALID;


--
-- Name: managed_agent_profiles managed_agent_profiles_api_key_secret_id_company_secrets_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.managed_agent_profiles
    ADD CONSTRAINT managed_agent_profiles_api_key_secret_id_company_secrets_id_fk FOREIGN KEY (api_key_secret_id) REFERENCES public.company_secrets(id) ON DELETE RESTRICT;


--
-- Name: managed_agent_profiles managed_agent_profiles_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.managed_agent_profiles
    ADD CONSTRAINT managed_agent_profiles_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: native_run_finalizations native_run_finalizations_assessment_owner_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.native_run_finalizations
    ADD CONSTRAINT native_run_finalizations_assessment_owner_fk FOREIGN KEY (company_id, issue_id, run_id, assessment_id) REFERENCES public.work_assessments(company_id, issue_id, run_id, id);


--
-- Name: native_run_finalizations native_run_finalizations_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.native_run_finalizations
    ADD CONSTRAINT native_run_finalizations_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: native_run_finalizations native_run_finalizations_decision_owner_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.native_run_finalizations
    ADD CONSTRAINT native_run_finalizations_decision_owner_fk FOREIGN KEY (company_id, issue_id, run_id, assessment_id, decision_id) REFERENCES public.status_decisions(company_id, issue_id, run_id, assessment_id, id);


--
-- Name: native_run_finalizations native_run_finalizations_issue_company_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.native_run_finalizations
    ADD CONSTRAINT native_run_finalizations_issue_company_fk FOREIGN KEY (company_id, issue_id) REFERENCES public.issues(company_id, id);


--
-- Name: native_run_finalizations native_run_finalizations_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.native_run_finalizations
    ADD CONSTRAINT native_run_finalizations_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id);


--
-- Name: native_run_finalizations native_run_finalizations_result_id_native_run_results_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.native_run_finalizations
    ADD CONSTRAINT native_run_finalizations_result_id_native_run_results_id_fk FOREIGN KEY (result_id) REFERENCES public.native_run_results(id);


--
-- Name: native_run_finalizations native_run_finalizations_result_owner_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.native_run_finalizations
    ADD CONSTRAINT native_run_finalizations_result_owner_fk FOREIGN KEY (company_id, issue_id, run_id, result_id) REFERENCES public.native_run_results(company_id, issue_id, run_id, id);


--
-- Name: native_run_finalizations native_run_finalizations_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.native_run_finalizations
    ADD CONSTRAINT native_run_finalizations_run_id_heartbeat_runs_id_fk FOREIGN KEY (run_id) REFERENCES public.heartbeat_runs(id);


--
-- Name: native_run_finalizations native_run_finalizations_run_owner_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.native_run_finalizations
    ADD CONSTRAINT native_run_finalizations_run_owner_fk FOREIGN KEY (company_id, issue_id, run_id) REFERENCES public.heartbeat_runs(company_id, native_issue_id, id);


--
-- Name: native_run_results native_run_results_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.native_run_results
    ADD CONSTRAINT native_run_results_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: native_run_results native_run_results_completion_contract_id_completion_contracts_; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.native_run_results
    ADD CONSTRAINT native_run_results_completion_contract_id_completion_contracts_ FOREIGN KEY (completion_contract_id) REFERENCES public.completion_contracts(id);


--
-- Name: native_run_results native_run_results_completion_contract_owner_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.native_run_results
    ADD CONSTRAINT native_run_results_completion_contract_owner_fk FOREIGN KEY (company_id, issue_id, completion_contract_id) REFERENCES public.completion_contracts(company_id, issue_id, id);


--
-- Name: native_run_results native_run_results_issue_company_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.native_run_results
    ADD CONSTRAINT native_run_results_issue_company_fk FOREIGN KEY (company_id, issue_id) REFERENCES public.issues(company_id, id);


--
-- Name: native_run_results native_run_results_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.native_run_results
    ADD CONSTRAINT native_run_results_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id);


--
-- Name: native_run_results native_run_results_run_contract_owner_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.native_run_results
    ADD CONSTRAINT native_run_results_run_contract_owner_fk FOREIGN KEY (company_id, issue_id, run_id, completion_contract_id) REFERENCES public.heartbeat_runs(company_id, native_issue_id, id, completion_contract_id);


--
-- Name: native_run_results native_run_results_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.native_run_results
    ADD CONSTRAINT native_run_results_run_id_heartbeat_runs_id_fk FOREIGN KEY (run_id) REFERENCES public.heartbeat_runs(id);


--
-- Name: pipeline_automation_executions pipeline_automation_executions_case_id_pipeline_cases_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_automation_executions
    ADD CONSTRAINT pipeline_automation_executions_case_id_pipeline_cases_id_fk FOREIGN KEY (case_id) REFERENCES public.pipeline_cases(id) ON DELETE CASCADE;


--
-- Name: pipeline_automation_executions pipeline_automation_executions_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_automation_executions
    ADD CONSTRAINT pipeline_automation_executions_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: pipeline_automation_executions pipeline_automation_executions_execution_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_automation_executions
    ADD CONSTRAINT pipeline_automation_executions_execution_issue_id_issues_id_fk FOREIGN KEY (execution_issue_id) REFERENCES public.issues(id) ON DELETE SET NULL;


--
-- Name: pipeline_automation_executions pipeline_automation_executions_routine_id_routines_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_automation_executions
    ADD CONSTRAINT pipeline_automation_executions_routine_id_routines_id_fk FOREIGN KEY (routine_id) REFERENCES public.routines(id) ON DELETE CASCADE;


--
-- Name: pipeline_case_blockers pipeline_case_blockers_blocked_by_case_id_pipeline_cases_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_case_blockers
    ADD CONSTRAINT pipeline_case_blockers_blocked_by_case_id_pipeline_cases_id_fk FOREIGN KEY (blocked_by_case_id) REFERENCES public.pipeline_cases(id) ON DELETE CASCADE;


--
-- Name: pipeline_case_blockers pipeline_case_blockers_case_id_pipeline_cases_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_case_blockers
    ADD CONSTRAINT pipeline_case_blockers_case_id_pipeline_cases_id_fk FOREIGN KEY (case_id) REFERENCES public.pipeline_cases(id) ON DELETE CASCADE;


--
-- Name: pipeline_case_blockers pipeline_case_blockers_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_case_blockers
    ADD CONSTRAINT pipeline_case_blockers_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: pipeline_case_documents pipeline_case_documents_case_id_pipeline_cases_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_case_documents
    ADD CONSTRAINT pipeline_case_documents_case_id_pipeline_cases_id_fk FOREIGN KEY (case_id) REFERENCES public.pipeline_cases(id) ON DELETE CASCADE;


--
-- Name: pipeline_case_documents pipeline_case_documents_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_case_documents
    ADD CONSTRAINT pipeline_case_documents_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: pipeline_case_documents pipeline_case_documents_document_id_documents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_case_documents
    ADD CONSTRAINT pipeline_case_documents_document_id_documents_id_fk FOREIGN KEY (document_id) REFERENCES public.documents(id) ON DELETE CASCADE;


--
-- Name: pipeline_case_events pipeline_case_events_actor_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_case_events
    ADD CONSTRAINT pipeline_case_events_actor_agent_id_agents_id_fk FOREIGN KEY (actor_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: pipeline_case_events pipeline_case_events_case_id_pipeline_cases_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_case_events
    ADD CONSTRAINT pipeline_case_events_case_id_pipeline_cases_id_fk FOREIGN KEY (case_id) REFERENCES public.pipeline_cases(id) ON DELETE CASCADE;


--
-- Name: pipeline_case_events pipeline_case_events_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_case_events
    ADD CONSTRAINT pipeline_case_events_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: pipeline_case_events pipeline_case_events_from_stage_id_pipeline_stages_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_case_events
    ADD CONSTRAINT pipeline_case_events_from_stage_id_pipeline_stages_id_fk FOREIGN KEY (from_stage_id) REFERENCES public.pipeline_stages(id) ON DELETE SET NULL;


--
-- Name: pipeline_case_events pipeline_case_events_to_stage_id_pipeline_stages_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_case_events
    ADD CONSTRAINT pipeline_case_events_to_stage_id_pipeline_stages_id_fk FOREIGN KEY (to_stage_id) REFERENCES public.pipeline_stages(id) ON DELETE SET NULL;


--
-- Name: pipeline_case_issue_links pipeline_case_issue_links_case_id_pipeline_cases_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_case_issue_links
    ADD CONSTRAINT pipeline_case_issue_links_case_id_pipeline_cases_id_fk FOREIGN KEY (case_id) REFERENCES public.pipeline_cases(id) ON DELETE CASCADE;


--
-- Name: pipeline_case_issue_links pipeline_case_issue_links_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_case_issue_links
    ADD CONSTRAINT pipeline_case_issue_links_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: pipeline_case_issue_links pipeline_case_issue_links_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_case_issue_links
    ADD CONSTRAINT pipeline_case_issue_links_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE CASCADE;


--
-- Name: pipeline_cases pipeline_cases_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_cases
    ADD CONSTRAINT pipeline_cases_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: pipeline_cases pipeline_cases_created_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_cases
    ADD CONSTRAINT pipeline_cases_created_by_agent_id_agents_id_fk FOREIGN KEY (created_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: pipeline_cases pipeline_cases_lease_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_cases
    ADD CONSTRAINT pipeline_cases_lease_agent_id_agents_id_fk FOREIGN KEY (lease_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: pipeline_cases pipeline_cases_parent_case_id_pipeline_cases_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_cases
    ADD CONSTRAINT pipeline_cases_parent_case_id_pipeline_cases_id_fk FOREIGN KEY (parent_case_id) REFERENCES public.pipeline_cases(id) ON DELETE SET NULL;


--
-- Name: pipeline_cases pipeline_cases_pipeline_id_pipelines_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_cases
    ADD CONSTRAINT pipeline_cases_pipeline_id_pipelines_id_fk FOREIGN KEY (pipeline_id) REFERENCES public.pipelines(id) ON DELETE CASCADE;


--
-- Name: pipeline_cases pipeline_cases_stage_id_pipeline_stages_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_cases
    ADD CONSTRAINT pipeline_cases_stage_id_pipeline_stages_id_fk FOREIGN KEY (stage_id) REFERENCES public.pipeline_stages(id);


--
-- Name: pipeline_documents pipeline_documents_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_documents
    ADD CONSTRAINT pipeline_documents_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: pipeline_documents pipeline_documents_document_id_documents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_documents
    ADD CONSTRAINT pipeline_documents_document_id_documents_id_fk FOREIGN KEY (document_id) REFERENCES public.documents(id) ON DELETE CASCADE;


--
-- Name: pipeline_documents pipeline_documents_pipeline_id_pipelines_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_documents
    ADD CONSTRAINT pipeline_documents_pipeline_id_pipelines_id_fk FOREIGN KEY (pipeline_id) REFERENCES public.pipelines(id) ON DELETE CASCADE;


--
-- Name: pipeline_stages pipeline_stages_pipeline_id_pipelines_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_stages
    ADD CONSTRAINT pipeline_stages_pipeline_id_pipelines_id_fk FOREIGN KEY (pipeline_id) REFERENCES public.pipelines(id) ON DELETE CASCADE;


--
-- Name: pipeline_transitions pipeline_transitions_from_stage_id_pipeline_stages_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_transitions
    ADD CONSTRAINT pipeline_transitions_from_stage_id_pipeline_stages_id_fk FOREIGN KEY (from_stage_id) REFERENCES public.pipeline_stages(id) ON DELETE CASCADE;


--
-- Name: pipeline_transitions pipeline_transitions_pipeline_id_pipelines_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_transitions
    ADD CONSTRAINT pipeline_transitions_pipeline_id_pipelines_id_fk FOREIGN KEY (pipeline_id) REFERENCES public.pipelines(id) ON DELETE CASCADE;


--
-- Name: pipeline_transitions pipeline_transitions_to_stage_id_pipeline_stages_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_transitions
    ADD CONSTRAINT pipeline_transitions_to_stage_id_pipeline_stages_id_fk FOREIGN KEY (to_stage_id) REFERENCES public.pipeline_stages(id) ON DELETE CASCADE;


--
-- Name: pipelines pipelines_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipelines
    ADD CONSTRAINT pipelines_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: pipelines pipelines_created_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipelines
    ADD CONSTRAINT pipelines_created_by_agent_id_agents_id_fk FOREIGN KEY (created_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: pipelines pipelines_project_id_projects_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipelines
    ADD CONSTRAINT pipelines_project_id_projects_id_fk FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE SET NULL;


--
-- Name: plugin_company_settings plugin_company_settings_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugin_company_settings
    ADD CONSTRAINT plugin_company_settings_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE NOT VALID;


--
-- Name: plugin_company_settings plugin_company_settings_plugin_id_plugins_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugin_company_settings
    ADD CONSTRAINT plugin_company_settings_plugin_id_plugins_id_fk FOREIGN KEY (plugin_id) REFERENCES public.plugins(id) ON DELETE CASCADE NOT VALID;


--
-- Name: plugin_config plugin_config_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugin_config
    ADD CONSTRAINT plugin_config_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: plugin_config plugin_config_plugin_id_plugins_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugin_config
    ADD CONSTRAINT plugin_config_plugin_id_plugins_id_fk FOREIGN KEY (plugin_id) REFERENCES public.plugins(id) ON DELETE CASCADE NOT VALID;


--
-- Name: plugin_database_namespaces plugin_database_namespaces_plugin_id_plugins_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugin_database_namespaces
    ADD CONSTRAINT plugin_database_namespaces_plugin_id_plugins_id_fk FOREIGN KEY (plugin_id) REFERENCES public.plugins(id) ON DELETE CASCADE NOT VALID;


--
-- Name: plugin_entities plugin_entities_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugin_entities
    ADD CONSTRAINT plugin_entities_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: plugin_entities plugin_entities_plugin_id_plugins_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugin_entities
    ADD CONSTRAINT plugin_entities_plugin_id_plugins_id_fk FOREIGN KEY (plugin_id) REFERENCES public.plugins(id) ON DELETE CASCADE NOT VALID;


--
-- Name: plugin_job_runs plugin_job_runs_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugin_job_runs
    ADD CONSTRAINT plugin_job_runs_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: plugin_job_runs plugin_job_runs_job_id_plugin_jobs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugin_job_runs
    ADD CONSTRAINT plugin_job_runs_job_id_plugin_jobs_id_fk FOREIGN KEY (job_id) REFERENCES public.plugin_jobs(id) ON DELETE CASCADE NOT VALID;


--
-- Name: plugin_job_runs plugin_job_runs_plugin_id_plugins_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugin_job_runs
    ADD CONSTRAINT plugin_job_runs_plugin_id_plugins_id_fk FOREIGN KEY (plugin_id) REFERENCES public.plugins(id) ON DELETE CASCADE NOT VALID;


--
-- Name: plugin_jobs plugin_jobs_plugin_id_plugins_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugin_jobs
    ADD CONSTRAINT plugin_jobs_plugin_id_plugins_id_fk FOREIGN KEY (plugin_id) REFERENCES public.plugins(id) ON DELETE CASCADE NOT VALID;


--
-- Name: plugin_logs plugin_logs_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugin_logs
    ADD CONSTRAINT plugin_logs_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: plugin_logs plugin_logs_plugin_id_plugins_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugin_logs
    ADD CONSTRAINT plugin_logs_plugin_id_plugins_id_fk FOREIGN KEY (plugin_id) REFERENCES public.plugins(id) ON DELETE CASCADE NOT VALID;


--
-- Name: plugin_managed_resources plugin_managed_resources_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugin_managed_resources
    ADD CONSTRAINT plugin_managed_resources_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE NOT VALID;


--
-- Name: plugin_managed_resources plugin_managed_resources_plugin_id_plugins_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugin_managed_resources
    ADD CONSTRAINT plugin_managed_resources_plugin_id_plugins_id_fk FOREIGN KEY (plugin_id) REFERENCES public.plugins(id) ON DELETE CASCADE NOT VALID;


--
-- Name: plugin_migrations plugin_migrations_plugin_id_plugins_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugin_migrations
    ADD CONSTRAINT plugin_migrations_plugin_id_plugins_id_fk FOREIGN KEY (plugin_id) REFERENCES public.plugins(id) ON DELETE CASCADE NOT VALID;


--
-- Name: plugin_state plugin_state_plugin_id_plugins_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugin_state
    ADD CONSTRAINT plugin_state_plugin_id_plugins_id_fk FOREIGN KEY (plugin_id) REFERENCES public.plugins(id) ON DELETE CASCADE NOT VALID;


--
-- Name: plugin_webhook_deliveries plugin_webhook_deliveries_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugin_webhook_deliveries
    ADD CONSTRAINT plugin_webhook_deliveries_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: plugin_webhook_deliveries plugin_webhook_deliveries_plugin_id_plugins_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugin_webhook_deliveries
    ADD CONSTRAINT plugin_webhook_deliveries_plugin_id_plugins_id_fk FOREIGN KEY (plugin_id) REFERENCES public.plugins(id) ON DELETE CASCADE NOT VALID;


--
-- Name: principal_permission_grants principal_permission_grants_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.principal_permission_grants
    ADD CONSTRAINT principal_permission_grants_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: project_goals project_goals_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_goals
    ADD CONSTRAINT project_goals_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: project_goals project_goals_goal_id_goals_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_goals
    ADD CONSTRAINT project_goals_goal_id_goals_id_fk FOREIGN KEY (goal_id) REFERENCES public.goals(id) ON DELETE CASCADE NOT VALID;


--
-- Name: project_goals project_goals_project_id_projects_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_goals
    ADD CONSTRAINT project_goals_project_id_projects_id_fk FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE NOT VALID;


--
-- Name: project_memberships project_memberships_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_memberships
    ADD CONSTRAINT project_memberships_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: project_memberships project_memberships_project_id_projects_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_memberships
    ADD CONSTRAINT project_memberships_project_id_projects_id_fk FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: project_workspaces project_workspaces_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_workspaces
    ADD CONSTRAINT project_workspaces_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: project_workspaces project_workspaces_project_id_projects_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_workspaces
    ADD CONSTRAINT project_workspaces_project_id_projects_id_fk FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE NOT VALID;


--
-- Name: projects projects_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT projects_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: projects projects_goal_id_goals_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT projects_goal_id_goals_id_fk FOREIGN KEY (goal_id) REFERENCES public.goals(id) NOT VALID;


--
-- Name: projects projects_lead_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT projects_lead_agent_id_agents_id_fk FOREIGN KEY (lead_agent_id) REFERENCES public.agents(id) NOT VALID;


--
-- Name: provider_trace_records provider_trace_records_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_trace_records
    ADD CONSTRAINT provider_trace_records_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: provider_trace_records provider_trace_records_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_trace_records
    ADD CONSTRAINT provider_trace_records_run_id_heartbeat_runs_id_fk FOREIGN KEY (run_id) REFERENCES public.heartbeat_runs(id) ON DELETE CASCADE;


--
-- Name: remote_agent_profiles remote_agent_profiles_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.remote_agent_profiles
    ADD CONSTRAINT remote_agent_profiles_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: resource_lifecycle_events resource_lifecycle_events_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_lifecycle_events
    ADD CONSTRAINT resource_lifecycle_events_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: routine_documents routine_documents_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routine_documents
    ADD CONSTRAINT routine_documents_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: routine_documents routine_documents_document_id_documents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routine_documents
    ADD CONSTRAINT routine_documents_document_id_documents_id_fk FOREIGN KEY (document_id) REFERENCES public.documents(id) ON DELETE CASCADE;


--
-- Name: routine_documents routine_documents_routine_id_routines_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routine_documents
    ADD CONSTRAINT routine_documents_routine_id_routines_id_fk FOREIGN KEY (routine_id) REFERENCES public.routines(id) ON DELETE CASCADE;


--
-- Name: routine_revisions routine_revisions_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routine_revisions
    ADD CONSTRAINT routine_revisions_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE NOT VALID;


--
-- Name: routine_revisions routine_revisions_created_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routine_revisions
    ADD CONSTRAINT routine_revisions_created_by_agent_id_agents_id_fk FOREIGN KEY (created_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL NOT VALID;


--
-- Name: routine_revisions routine_revisions_created_by_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routine_revisions
    ADD CONSTRAINT routine_revisions_created_by_run_id_heartbeat_runs_id_fk FOREIGN KEY (created_by_run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL NOT VALID;


--
-- Name: routine_revisions routine_revisions_restored_from_revision_id_routine_revisions_i; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routine_revisions
    ADD CONSTRAINT routine_revisions_restored_from_revision_id_routine_revisions_i FOREIGN KEY (restored_from_revision_id) REFERENCES public.routine_revisions(id) ON DELETE SET NULL NOT VALID;


--
-- Name: routine_revisions routine_revisions_routine_id_routines_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routine_revisions
    ADD CONSTRAINT routine_revisions_routine_id_routines_id_fk FOREIGN KEY (routine_id) REFERENCES public.routines(id) ON DELETE CASCADE NOT VALID;


--
-- Name: routine_runs routine_runs_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routine_runs
    ADD CONSTRAINT routine_runs_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE NOT VALID;


--
-- Name: routine_runs routine_runs_linked_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routine_runs
    ADD CONSTRAINT routine_runs_linked_issue_id_issues_id_fk FOREIGN KEY (linked_issue_id) REFERENCES public.issues(id) ON DELETE SET NULL NOT VALID;


--
-- Name: routine_runs routine_runs_routine_id_routines_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routine_runs
    ADD CONSTRAINT routine_runs_routine_id_routines_id_fk FOREIGN KEY (routine_id) REFERENCES public.routines(id) ON DELETE CASCADE NOT VALID;


--
-- Name: routine_runs routine_runs_routine_revision_id_routine_revisions_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routine_runs
    ADD CONSTRAINT routine_runs_routine_revision_id_routine_revisions_id_fk FOREIGN KEY (routine_revision_id) REFERENCES public.routine_revisions(id) ON DELETE SET NULL;


--
-- Name: routine_runs routine_runs_trigger_id_routine_triggers_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routine_runs
    ADD CONSTRAINT routine_runs_trigger_id_routine_triggers_id_fk FOREIGN KEY (trigger_id) REFERENCES public.routine_triggers(id) ON DELETE SET NULL NOT VALID;


--
-- Name: routine_triggers routine_triggers_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routine_triggers
    ADD CONSTRAINT routine_triggers_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE NOT VALID;


--
-- Name: routine_triggers routine_triggers_created_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routine_triggers
    ADD CONSTRAINT routine_triggers_created_by_agent_id_agents_id_fk FOREIGN KEY (created_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL NOT VALID;


--
-- Name: routine_triggers routine_triggers_routine_id_routines_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routine_triggers
    ADD CONSTRAINT routine_triggers_routine_id_routines_id_fk FOREIGN KEY (routine_id) REFERENCES public.routines(id) ON DELETE CASCADE NOT VALID;


--
-- Name: routine_triggers routine_triggers_secret_id_company_secrets_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routine_triggers
    ADD CONSTRAINT routine_triggers_secret_id_company_secrets_id_fk FOREIGN KEY (secret_id) REFERENCES public.company_secrets(id) ON DELETE SET NULL NOT VALID;


--
-- Name: routine_triggers routine_triggers_updated_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routine_triggers
    ADD CONSTRAINT routine_triggers_updated_by_agent_id_agents_id_fk FOREIGN KEY (updated_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL NOT VALID;


--
-- Name: routine_webhook_test_receipts routine_webhook_test_receipts_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routine_webhook_test_receipts
    ADD CONSTRAINT routine_webhook_test_receipts_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: routine_webhook_test_receipts routine_webhook_test_receipts_trigger_id_routine_triggers_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routine_webhook_test_receipts
    ADD CONSTRAINT routine_webhook_test_receipts_trigger_id_routine_triggers_id_fk FOREIGN KEY (trigger_id) REFERENCES public.routine_triggers(id) ON DELETE CASCADE;


--
-- Name: routines routines_assignee_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routines
    ADD CONSTRAINT routines_assignee_agent_id_agents_id_fk FOREIGN KEY (assignee_agent_id) REFERENCES public.agents(id) NOT VALID;


--
-- Name: routines routines_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routines
    ADD CONSTRAINT routines_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE NOT VALID;


--
-- Name: routines routines_created_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routines
    ADD CONSTRAINT routines_created_by_agent_id_agents_id_fk FOREIGN KEY (created_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL NOT VALID;


--
-- Name: routines routines_folder_id_folders_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routines
    ADD CONSTRAINT routines_folder_id_folders_id_fk FOREIGN KEY (folder_id) REFERENCES public.folders(id) ON DELETE SET NULL;


--
-- Name: routines routines_goal_id_goals_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routines
    ADD CONSTRAINT routines_goal_id_goals_id_fk FOREIGN KEY (goal_id) REFERENCES public.goals(id) ON DELETE SET NULL NOT VALID;


--
-- Name: routines routines_parent_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routines
    ADD CONSTRAINT routines_parent_issue_id_issues_id_fk FOREIGN KEY (parent_issue_id) REFERENCES public.issues(id) ON DELETE SET NULL NOT VALID;


--
-- Name: routines routines_project_id_projects_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routines
    ADD CONSTRAINT routines_project_id_projects_id_fk FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE NOT VALID;


--
-- Name: routines routines_updated_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routines
    ADD CONSTRAINT routines_updated_by_agent_id_agents_id_fk FOREIGN KEY (updated_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL NOT VALID;


--
-- Name: run_identity_contexts run_identity_contexts_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.run_identity_contexts
    ADD CONSTRAINT run_identity_contexts_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: runner_api_response_reservations runner_api_response_reservations_asset_id_assets_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.runner_api_response_reservations
    ADD CONSTRAINT runner_api_response_reservations_asset_id_assets_id_fk FOREIGN KEY (asset_id) REFERENCES public.assets(id) ON DELETE CASCADE;


--
-- Name: runner_api_response_reservations runner_api_response_reservations_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.runner_api_response_reservations
    ADD CONSTRAINT runner_api_response_reservations_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: runner_api_response_reservations runner_api_response_reservations_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.runner_api_response_reservations
    ADD CONSTRAINT runner_api_response_reservations_run_id_heartbeat_runs_id_fk FOREIGN KEY (run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL;


--
-- Name: secret_access_events secret_access_events_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_access_events
    ADD CONSTRAINT secret_access_events_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: secret_access_events secret_access_events_heartbeat_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_access_events
    ADD CONSTRAINT secret_access_events_heartbeat_run_id_heartbeat_runs_id_fk FOREIGN KEY (heartbeat_run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL NOT VALID;


--
-- Name: secret_access_events secret_access_events_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_access_events
    ADD CONSTRAINT secret_access_events_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE SET NULL NOT VALID;


--
-- Name: secret_access_events secret_access_events_plugin_id_plugins_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_access_events
    ADD CONSTRAINT secret_access_events_plugin_id_plugins_id_fk FOREIGN KEY (plugin_id) REFERENCES public.plugins(id) ON DELETE SET NULL NOT VALID;


--
-- Name: secret_access_events secret_access_events_secret_id_company_secrets_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_access_events
    ADD CONSTRAINT secret_access_events_secret_id_company_secrets_id_fk FOREIGN KEY (secret_id) REFERENCES public.company_secrets(id) ON DELETE CASCADE NOT VALID;


--
-- Name: secret_access_events secret_access_events_user_secret_definition_id_user_secret_defi; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_access_events
    ADD CONSTRAINT secret_access_events_user_secret_definition_id_user_secret_defi FOREIGN KEY (user_secret_definition_id) REFERENCES public.user_secret_definitions(id) ON DELETE SET NULL;


--
-- Name: session session_user_id_user_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.session
    ADD CONSTRAINT session_user_id_user_id_fk FOREIGN KEY (user_id) REFERENCES public."user"(id) ON DELETE CASCADE NOT VALID;


--
-- Name: smoke_run_steps smoke_run_steps_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.smoke_run_steps
    ADD CONSTRAINT smoke_run_steps_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: smoke_run_steps smoke_run_steps_run_id_smoke_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.smoke_run_steps
    ADD CONSTRAINT smoke_run_steps_run_id_smoke_runs_id_fk FOREIGN KEY (run_id) REFERENCES public.smoke_runs(id) ON DELETE CASCADE;


--
-- Name: smoke_runs smoke_runs_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.smoke_runs
    ADD CONSTRAINT smoke_runs_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: status_card_updates status_card_updates_card_id_status_cards_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.status_card_updates
    ADD CONSTRAINT status_card_updates_card_id_status_cards_id_fk FOREIGN KEY (card_id) REFERENCES public.status_cards(id) ON DELETE CASCADE;


--
-- Name: status_card_updates status_card_updates_generation_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.status_card_updates
    ADD CONSTRAINT status_card_updates_generation_issue_id_issues_id_fk FOREIGN KEY (generation_issue_id) REFERENCES public.issues(id) ON DELETE SET NULL;


--
-- Name: status_card_updates status_card_updates_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.status_card_updates
    ADD CONSTRAINT status_card_updates_run_id_heartbeat_runs_id_fk FOREIGN KEY (run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL;


--
-- Name: status_cards status_cards_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.status_cards
    ADD CONSTRAINT status_cards_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: status_cards status_cards_archived_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.status_cards
    ADD CONSTRAINT status_cards_archived_by_agent_id_agents_id_fk FOREIGN KEY (archived_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: status_cards status_cards_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.status_cards
    ADD CONSTRAINT status_cards_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: status_cards status_cards_created_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.status_cards
    ADD CONSTRAINT status_cards_created_by_agent_id_agents_id_fk FOREIGN KEY (created_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: status_cards status_cards_document_id_documents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.status_cards
    ADD CONSTRAINT status_cards_document_id_documents_id_fk FOREIGN KEY (document_id) REFERENCES public.documents(id) ON DELETE SET NULL;


--
-- Name: status_cards status_cards_generating_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.status_cards
    ADD CONSTRAINT status_cards_generating_issue_id_issues_id_fk FOREIGN KEY (generating_issue_id) REFERENCES public.issues(id) ON DELETE SET NULL;


--
-- Name: status_cards status_cards_query_compiled_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.status_cards
    ADD CONSTRAINT status_cards_query_compiled_by_agent_id_agents_id_fk FOREIGN KEY (query_compiled_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: status_decision_effects status_decision_effects_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.status_decision_effects
    ADD CONSTRAINT status_decision_effects_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: status_decision_effects status_decision_effects_decision_id_status_decisions_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.status_decision_effects
    ADD CONSTRAINT status_decision_effects_decision_id_status_decisions_id_fk FOREIGN KEY (decision_id) REFERENCES public.status_decisions(id);


--
-- Name: status_decision_effects status_decision_effects_decision_owner_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.status_decision_effects
    ADD CONSTRAINT status_decision_effects_decision_owner_fk FOREIGN KEY (company_id, issue_id, decision_id) REFERENCES public.status_decisions(company_id, issue_id, id);


--
-- Name: status_decision_effects status_decision_effects_issue_company_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.status_decision_effects
    ADD CONSTRAINT status_decision_effects_issue_company_fk FOREIGN KEY (company_id, issue_id) REFERENCES public.issues(company_id, id);


--
-- Name: status_decision_effects status_decision_effects_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.status_decision_effects
    ADD CONSTRAINT status_decision_effects_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id);


--
-- Name: status_decisions status_decisions_assessment_id_work_assessments_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.status_decisions
    ADD CONSTRAINT status_decisions_assessment_id_work_assessments_id_fk FOREIGN KEY (assessment_id) REFERENCES public.work_assessments(id);


--
-- Name: status_decisions status_decisions_assessment_owner_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.status_decisions
    ADD CONSTRAINT status_decisions_assessment_owner_fk FOREIGN KEY (company_id, issue_id, run_id, assessment_id) REFERENCES public.work_assessments(company_id, issue_id, run_id, id);


--
-- Name: status_decisions status_decisions_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.status_decisions
    ADD CONSTRAINT status_decisions_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: status_decisions status_decisions_issue_company_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.status_decisions
    ADD CONSTRAINT status_decisions_issue_company_fk FOREIGN KEY (company_id, issue_id) REFERENCES public.issues(company_id, id);


--
-- Name: status_decisions status_decisions_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.status_decisions
    ADD CONSTRAINT status_decisions_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id);


--
-- Name: status_decisions status_decisions_supersedes_owner_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.status_decisions
    ADD CONSTRAINT status_decisions_supersedes_owner_fk FOREIGN KEY (company_id, issue_id, supersedes_decision_id) REFERENCES public.status_decisions(company_id, issue_id, id);


--
-- Name: summary_slots summary_slots_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.summary_slots
    ADD CONSTRAINT summary_slots_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: summary_slots summary_slots_document_id_documents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.summary_slots
    ADD CONSTRAINT summary_slots_document_id_documents_id_fk FOREIGN KEY (document_id) REFERENCES public.documents(id) ON DELETE SET NULL;


--
-- Name: summary_slots summary_slots_generating_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.summary_slots
    ADD CONSTRAINT summary_slots_generating_issue_id_issues_id_fk FOREIGN KEY (generating_issue_id) REFERENCES public.issues(id) ON DELETE SET NULL;


--
-- Name: summary_slots summary_slots_last_generated_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.summary_slots
    ADD CONSTRAINT summary_slots_last_generated_by_agent_id_agents_id_fk FOREIGN KEY (last_generated_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: tool_access_audit_events tool_access_audit_events_catalog_entry_id_tool_catalog_entries_; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_access_audit_events
    ADD CONSTRAINT tool_access_audit_events_catalog_entry_id_tool_catalog_entries_ FOREIGN KEY (catalog_entry_id) REFERENCES public.tool_catalog_entries(id) ON DELETE SET NULL;


--
-- Name: tool_access_audit_events tool_access_audit_events_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_access_audit_events
    ADD CONSTRAINT tool_access_audit_events_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: tool_access_audit_events tool_access_audit_events_connection_id_tool_connections_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_access_audit_events
    ADD CONSTRAINT tool_access_audit_events_connection_id_tool_connections_id_fk FOREIGN KEY (connection_id) REFERENCES public.tool_connections(id) ON DELETE SET NULL;


--
-- Name: tool_access_audit_events tool_access_audit_events_gateway_id_tool_mcp_gateways_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_access_audit_events
    ADD CONSTRAINT tool_access_audit_events_gateway_id_tool_mcp_gateways_id_fk FOREIGN KEY (gateway_id) REFERENCES public.tool_mcp_gateways(id) ON DELETE SET NULL;


--
-- Name: tool_access_audit_events tool_access_audit_events_gateway_token_id_tool_mcp_gateway_toke; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_access_audit_events
    ADD CONSTRAINT tool_access_audit_events_gateway_token_id_tool_mcp_gateway_toke FOREIGN KEY (gateway_token_id) REFERENCES public.tool_mcp_gateway_tokens(id) ON DELETE SET NULL;


--
-- Name: tool_action_deliveries tool_action_deliveries_action_request_id_tool_action_requests_i; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_action_deliveries
    ADD CONSTRAINT tool_action_deliveries_action_request_id_tool_action_requests_i FOREIGN KEY (action_request_id) REFERENCES public.tool_action_requests(id) ON DELETE CASCADE;


--
-- Name: tool_action_deliveries tool_action_deliveries_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_action_deliveries
    ADD CONSTRAINT tool_action_deliveries_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: tool_action_deliveries tool_action_deliveries_interaction_id_issue_thread_interactions; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_action_deliveries
    ADD CONSTRAINT tool_action_deliveries_interaction_id_issue_thread_interactions FOREIGN KEY (interaction_id) REFERENCES public.issue_thread_interactions(id) ON DELETE CASCADE;


--
-- Name: tool_action_deliveries tool_action_deliveries_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_action_deliveries
    ADD CONSTRAINT tool_action_deliveries_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE CASCADE;


--
-- Name: tool_action_requests tool_action_requests_approval_id_approvals_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_action_requests
    ADD CONSTRAINT tool_action_requests_approval_id_approvals_id_fk FOREIGN KEY (approval_id) REFERENCES public.approvals(id) ON DELETE SET NULL;


--
-- Name: tool_action_requests tool_action_requests_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_action_requests
    ADD CONSTRAINT tool_action_requests_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: tool_action_requests tool_action_requests_decided_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_action_requests
    ADD CONSTRAINT tool_action_requests_decided_by_agent_id_agents_id_fk FOREIGN KEY (decided_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: tool_action_requests tool_action_requests_interaction_id_issue_thread_interactions_i; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_action_requests
    ADD CONSTRAINT tool_action_requests_interaction_id_issue_thread_interactions_i FOREIGN KEY (interaction_id) REFERENCES public.issue_thread_interactions(id) ON DELETE SET NULL;


--
-- Name: tool_action_requests tool_action_requests_invocation_id_tool_invocations_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_action_requests
    ADD CONSTRAINT tool_action_requests_invocation_id_tool_invocations_id_fk FOREIGN KEY (invocation_id) REFERENCES public.tool_invocations(id) ON DELETE CASCADE;


--
-- Name: tool_action_requests tool_action_requests_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_action_requests
    ADD CONSTRAINT tool_action_requests_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE SET NULL;


--
-- Name: tool_action_requests tool_action_requests_requested_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_action_requests
    ADD CONSTRAINT tool_action_requests_requested_by_agent_id_agents_id_fk FOREIGN KEY (requested_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: tool_action_requests tool_action_requests_resolved_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_action_requests
    ADD CONSTRAINT tool_action_requests_resolved_by_agent_id_agents_id_fk FOREIGN KEY (resolved_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: tool_applications tool_applications_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_applications
    ADD CONSTRAINT tool_applications_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: tool_applications tool_applications_owner_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_applications
    ADD CONSTRAINT tool_applications_owner_agent_id_agents_id_fk FOREIGN KEY (owner_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: tool_applications tool_applications_plugin_id_plugins_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_applications
    ADD CONSTRAINT tool_applications_plugin_id_plugins_id_fk FOREIGN KEY (plugin_id) REFERENCES public.plugins(id) ON DELETE SET NULL;


--
-- Name: tool_call_events tool_call_events_action_request_id_tool_action_requests_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_call_events
    ADD CONSTRAINT tool_call_events_action_request_id_tool_action_requests_id_fk FOREIGN KEY (action_request_id) REFERENCES public.tool_action_requests(id) ON DELETE SET NULL;


--
-- Name: tool_call_events tool_call_events_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_call_events
    ADD CONSTRAINT tool_call_events_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: tool_call_events tool_call_events_application_id_tool_applications_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_call_events
    ADD CONSTRAINT tool_call_events_application_id_tool_applications_id_fk FOREIGN KEY (application_id) REFERENCES public.tool_applications(id) ON DELETE SET NULL;


--
-- Name: tool_call_events tool_call_events_catalog_entry_id_tool_catalog_entries_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_call_events
    ADD CONSTRAINT tool_call_events_catalog_entry_id_tool_catalog_entries_id_fk FOREIGN KEY (catalog_entry_id) REFERENCES public.tool_catalog_entries(id) ON DELETE SET NULL;


--
-- Name: tool_call_events tool_call_events_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_call_events
    ADD CONSTRAINT tool_call_events_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: tool_call_events tool_call_events_connection_id_tool_connections_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_call_events
    ADD CONSTRAINT tool_call_events_connection_id_tool_connections_id_fk FOREIGN KEY (connection_id) REFERENCES public.tool_connections(id) ON DELETE SET NULL;


--
-- Name: tool_call_events tool_call_events_gateway_id_tool_mcp_gateways_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_call_events
    ADD CONSTRAINT tool_call_events_gateway_id_tool_mcp_gateways_id_fk FOREIGN KEY (gateway_id) REFERENCES public.tool_mcp_gateways(id) ON DELETE SET NULL;


--
-- Name: tool_call_events tool_call_events_gateway_token_id_tool_mcp_gateway_tokens_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_call_events
    ADD CONSTRAINT tool_call_events_gateway_token_id_tool_mcp_gateway_tokens_id_fk FOREIGN KEY (gateway_token_id) REFERENCES public.tool_mcp_gateway_tokens(id) ON DELETE SET NULL;


--
-- Name: tool_call_events tool_call_events_invocation_id_tool_invocations_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_call_events
    ADD CONSTRAINT tool_call_events_invocation_id_tool_invocations_id_fk FOREIGN KEY (invocation_id) REFERENCES public.tool_invocations(id) ON DELETE SET NULL;


--
-- Name: tool_call_events tool_call_events_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_call_events
    ADD CONSTRAINT tool_call_events_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE SET NULL;


--
-- Name: tool_call_events tool_call_events_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_call_events
    ADD CONSTRAINT tool_call_events_run_id_heartbeat_runs_id_fk FOREIGN KEY (run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL;


--
-- Name: tool_call_events tool_call_events_runtime_slot_id_tool_runtime_slots_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_call_events
    ADD CONSTRAINT tool_call_events_runtime_slot_id_tool_runtime_slots_id_fk FOREIGN KEY (runtime_slot_id) REFERENCES public.tool_runtime_slots(id) ON DELETE SET NULL;


--
-- Name: tool_catalog_entries tool_catalog_entries_application_id_tool_applications_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_catalog_entries
    ADD CONSTRAINT tool_catalog_entries_application_id_tool_applications_id_fk FOREIGN KEY (application_id) REFERENCES public.tool_applications(id) ON DELETE CASCADE;


--
-- Name: tool_catalog_entries tool_catalog_entries_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_catalog_entries
    ADD CONSTRAINT tool_catalog_entries_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: tool_catalog_entries tool_catalog_entries_connection_id_tool_connections_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_catalog_entries
    ADD CONSTRAINT tool_catalog_entries_connection_id_tool_connections_id_fk FOREIGN KEY (connection_id) REFERENCES public.tool_connections(id) ON DELETE CASCADE;


--
-- Name: tool_catalog_entries tool_catalog_entries_reviewed_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_catalog_entries
    ADD CONSTRAINT tool_catalog_entries_reviewed_by_agent_id_agents_id_fk FOREIGN KEY (reviewed_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: tool_connection_app_snapshots tool_connection_app_snapshots_company_connection_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_connection_app_snapshots
    ADD CONSTRAINT tool_connection_app_snapshots_company_connection_fk FOREIGN KEY (company_id, connection_id) REFERENCES public.tool_connections(company_id, id) ON DELETE CASCADE;


--
-- Name: tool_connection_app_snapshots tool_connection_app_snapshots_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_connection_app_snapshots
    ADD CONSTRAINT tool_connection_app_snapshots_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: tool_connection_app_syncs tool_connection_app_syncs_company_connection_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_connection_app_syncs
    ADD CONSTRAINT tool_connection_app_syncs_company_connection_fk FOREIGN KEY (company_id, connection_id) REFERENCES public.tool_connections(company_id, id) ON DELETE CASCADE;


--
-- Name: tool_connection_app_syncs tool_connection_app_syncs_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_connection_app_syncs
    ADD CONSTRAINT tool_connection_app_syncs_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: tool_connection_installs tool_connection_installs_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_connection_installs
    ADD CONSTRAINT tool_connection_installs_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: tool_connection_installs tool_connection_installs_connection_id_tool_connections_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_connection_installs
    ADD CONSTRAINT tool_connection_installs_connection_id_tool_connections_id_fk FOREIGN KEY (connection_id) REFERENCES public.tool_connections(id) ON DELETE CASCADE;


--
-- Name: tool_connection_installs tool_connection_installs_created_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_connection_installs
    ADD CONSTRAINT tool_connection_installs_created_by_agent_id_agents_id_fk FOREIGN KEY (created_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: tool_connections tool_connections_application_id_tool_applications_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_connections
    ADD CONSTRAINT tool_connections_application_id_tool_applications_id_fk FOREIGN KEY (application_id) REFERENCES public.tool_applications(id);


--
-- Name: tool_connections tool_connections_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_connections
    ADD CONSTRAINT tool_connections_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: tool_connections tool_connections_created_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_connections
    ADD CONSTRAINT tool_connections_created_by_agent_id_agents_id_fk FOREIGN KEY (created_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: tool_gateway_rate_limit_counters tool_gateway_rate_limit_counters_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_gateway_rate_limit_counters
    ADD CONSTRAINT tool_gateway_rate_limit_counters_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: tool_gateway_sessions tool_gateway_sessions_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_gateway_sessions
    ADD CONSTRAINT tool_gateway_sessions_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES public.agents(id) ON DELETE CASCADE;


--
-- Name: tool_gateway_sessions tool_gateway_sessions_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_gateway_sessions
    ADD CONSTRAINT tool_gateway_sessions_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: tool_gateway_sessions tool_gateway_sessions_gateway_id_tool_mcp_gateways_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_gateway_sessions
    ADD CONSTRAINT tool_gateway_sessions_gateway_id_tool_mcp_gateways_id_fk FOREIGN KEY (gateway_id) REFERENCES public.tool_mcp_gateways(id) ON DELETE SET NULL;


--
-- Name: tool_gateway_sessions tool_gateway_sessions_gateway_token_id_tool_mcp_gateway_tokens_; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_gateway_sessions
    ADD CONSTRAINT tool_gateway_sessions_gateway_token_id_tool_mcp_gateway_tokens_ FOREIGN KEY (gateway_token_id) REFERENCES public.tool_mcp_gateway_tokens(id) ON DELETE SET NULL;


--
-- Name: tool_gateway_sessions tool_gateway_sessions_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_gateway_sessions
    ADD CONSTRAINT tool_gateway_sessions_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE SET NULL;


--
-- Name: tool_gateway_sessions tool_gateway_sessions_project_id_projects_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_gateway_sessions
    ADD CONSTRAINT tool_gateway_sessions_project_id_projects_id_fk FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE SET NULL;


--
-- Name: tool_gateway_sessions tool_gateway_sessions_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_gateway_sessions
    ADD CONSTRAINT tool_gateway_sessions_run_id_heartbeat_runs_id_fk FOREIGN KEY (run_id) REFERENCES public.heartbeat_runs(id) ON DELETE CASCADE;


--
-- Name: tool_invocations tool_invocations_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_invocations
    ADD CONSTRAINT tool_invocations_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: tool_invocations tool_invocations_application_id_tool_applications_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_invocations
    ADD CONSTRAINT tool_invocations_application_id_tool_applications_id_fk FOREIGN KEY (application_id) REFERENCES public.tool_applications(id) ON DELETE SET NULL;


--
-- Name: tool_invocations tool_invocations_catalog_entry_id_tool_catalog_entries_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_invocations
    ADD CONSTRAINT tool_invocations_catalog_entry_id_tool_catalog_entries_id_fk FOREIGN KEY (catalog_entry_id) REFERENCES public.tool_catalog_entries(id) ON DELETE SET NULL;


--
-- Name: tool_invocations tool_invocations_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_invocations
    ADD CONSTRAINT tool_invocations_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: tool_invocations tool_invocations_connection_id_tool_connections_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_invocations
    ADD CONSTRAINT tool_invocations_connection_id_tool_connections_id_fk FOREIGN KEY (connection_id) REFERENCES public.tool_connections(id) ON DELETE SET NULL;


--
-- Name: tool_invocations tool_invocations_gateway_id_tool_mcp_gateways_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_invocations
    ADD CONSTRAINT tool_invocations_gateway_id_tool_mcp_gateways_id_fk FOREIGN KEY (gateway_id) REFERENCES public.tool_mcp_gateways(id) ON DELETE SET NULL;


--
-- Name: tool_invocations tool_invocations_gateway_token_id_tool_mcp_gateway_tokens_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_invocations
    ADD CONSTRAINT tool_invocations_gateway_token_id_tool_mcp_gateway_tokens_id_fk FOREIGN KEY (gateway_token_id) REFERENCES public.tool_mcp_gateway_tokens(id) ON DELETE SET NULL;


--
-- Name: tool_invocations tool_invocations_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_invocations
    ADD CONSTRAINT tool_invocations_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE SET NULL;


--
-- Name: tool_invocations tool_invocations_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_invocations
    ADD CONSTRAINT tool_invocations_run_id_heartbeat_runs_id_fk FOREIGN KEY (run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL;


--
-- Name: tool_mcp_gateway_tokens tool_mcp_gateway_tokens_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_mcp_gateway_tokens
    ADD CONSTRAINT tool_mcp_gateway_tokens_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: tool_mcp_gateway_tokens tool_mcp_gateway_tokens_expiry_override_by_agent_id_agents_id_f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_mcp_gateway_tokens
    ADD CONSTRAINT tool_mcp_gateway_tokens_expiry_override_by_agent_id_agents_id_f FOREIGN KEY (expiry_override_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: tool_mcp_gateway_tokens tool_mcp_gateway_tokens_gateway_id_tool_mcp_gateways_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_mcp_gateway_tokens
    ADD CONSTRAINT tool_mcp_gateway_tokens_gateway_id_tool_mcp_gateways_id_fk FOREIGN KEY (gateway_id) REFERENCES public.tool_mcp_gateways(id) ON DELETE CASCADE;


--
-- Name: tool_mcp_gateways tool_mcp_gateways_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_mcp_gateways
    ADD CONSTRAINT tool_mcp_gateways_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: tool_mcp_gateways tool_mcp_gateways_approval_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_mcp_gateways
    ADD CONSTRAINT tool_mcp_gateways_approval_issue_id_issues_id_fk FOREIGN KEY (approval_issue_id) REFERENCES public.issues(id) ON DELETE SET NULL;


--
-- Name: tool_mcp_gateways tool_mcp_gateways_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_mcp_gateways
    ADD CONSTRAINT tool_mcp_gateways_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: tool_mcp_gateways tool_mcp_gateways_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_mcp_gateways
    ADD CONSTRAINT tool_mcp_gateways_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE SET NULL;


--
-- Name: tool_mcp_gateways tool_mcp_gateways_profile_id_tool_profiles_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_mcp_gateways
    ADD CONSTRAINT tool_mcp_gateways_profile_id_tool_profiles_id_fk FOREIGN KEY (profile_id) REFERENCES public.tool_profiles(id) ON DELETE RESTRICT;


--
-- Name: tool_mcp_gateways tool_mcp_gateways_project_id_projects_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_mcp_gateways
    ADD CONSTRAINT tool_mcp_gateways_project_id_projects_id_fk FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE SET NULL;


--
-- Name: tool_oauth_states tool_oauth_states_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_oauth_states
    ADD CONSTRAINT tool_oauth_states_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: tool_oauth_states tool_oauth_states_connection_id_tool_connections_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_oauth_states
    ADD CONSTRAINT tool_oauth_states_connection_id_tool_connections_id_fk FOREIGN KEY (connection_id) REFERENCES public.tool_connections(id) ON DELETE CASCADE;


--
-- Name: tool_oauth_states tool_oauth_states_subject_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_oauth_states
    ADD CONSTRAINT tool_oauth_states_subject_agent_id_agents_id_fk FOREIGN KEY (subject_agent_id) REFERENCES public.agents(id) ON DELETE CASCADE;


--
-- Name: tool_policies tool_policies_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_policies
    ADD CONSTRAINT tool_policies_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: tool_policies tool_policies_created_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_policies
    ADD CONSTRAINT tool_policies_created_by_agent_id_agents_id_fk FOREIGN KEY (created_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: tool_profile_bindings tool_profile_bindings_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_profile_bindings
    ADD CONSTRAINT tool_profile_bindings_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: tool_profile_bindings tool_profile_bindings_created_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_profile_bindings
    ADD CONSTRAINT tool_profile_bindings_created_by_agent_id_agents_id_fk FOREIGN KEY (created_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: tool_profile_bindings tool_profile_bindings_profile_id_tool_profiles_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_profile_bindings
    ADD CONSTRAINT tool_profile_bindings_profile_id_tool_profiles_id_fk FOREIGN KEY (profile_id) REFERENCES public.tool_profiles(id) ON DELETE CASCADE;


--
-- Name: tool_profile_entries tool_profile_entries_application_id_tool_applications_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_profile_entries
    ADD CONSTRAINT tool_profile_entries_application_id_tool_applications_id_fk FOREIGN KEY (application_id) REFERENCES public.tool_applications(id) ON DELETE CASCADE;


--
-- Name: tool_profile_entries tool_profile_entries_catalog_entry_id_tool_catalog_entries_id_f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_profile_entries
    ADD CONSTRAINT tool_profile_entries_catalog_entry_id_tool_catalog_entries_id_f FOREIGN KEY (catalog_entry_id) REFERENCES public.tool_catalog_entries(id) ON DELETE CASCADE;


--
-- Name: tool_profile_entries tool_profile_entries_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_profile_entries
    ADD CONSTRAINT tool_profile_entries_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: tool_profile_entries tool_profile_entries_connection_id_tool_connections_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_profile_entries
    ADD CONSTRAINT tool_profile_entries_connection_id_tool_connections_id_fk FOREIGN KEY (connection_id) REFERENCES public.tool_connections(id) ON DELETE CASCADE;


--
-- Name: tool_profile_entries tool_profile_entries_profile_id_tool_profiles_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_profile_entries
    ADD CONSTRAINT tool_profile_entries_profile_id_tool_profiles_id_fk FOREIGN KEY (profile_id) REFERENCES public.tool_profiles(id) ON DELETE CASCADE;


--
-- Name: tool_profiles tool_profiles_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_profiles
    ADD CONSTRAINT tool_profiles_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: tool_rate_limit_counters tool_rate_limit_counters_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_rate_limit_counters
    ADD CONSTRAINT tool_rate_limit_counters_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: tool_rate_limit_counters tool_rate_limit_counters_policy_id_tool_policies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_rate_limit_counters
    ADD CONSTRAINT tool_rate_limit_counters_policy_id_tool_policies_id_fk FOREIGN KEY (policy_id) REFERENCES public.tool_policies(id) ON DELETE CASCADE;


--
-- Name: tool_runtime_metric_counters tool_runtime_metric_counters_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_runtime_metric_counters
    ADD CONSTRAINT tool_runtime_metric_counters_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: tool_runtime_slots tool_runtime_slots_application_id_tool_applications_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_runtime_slots
    ADD CONSTRAINT tool_runtime_slots_application_id_tool_applications_id_fk FOREIGN KEY (application_id) REFERENCES public.tool_applications(id) ON DELETE SET NULL;


--
-- Name: tool_runtime_slots tool_runtime_slots_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_runtime_slots
    ADD CONSTRAINT tool_runtime_slots_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: tool_runtime_slots tool_runtime_slots_connection_id_tool_connections_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_runtime_slots
    ADD CONSTRAINT tool_runtime_slots_connection_id_tool_connections_id_fk FOREIGN KEY (connection_id) REFERENCES public.tool_connections(id) ON DELETE CASCADE;


--
-- Name: tool_runtime_slots tool_runtime_slots_execution_workspace_id_execution_workspaces_; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_runtime_slots
    ADD CONSTRAINT tool_runtime_slots_execution_workspace_id_execution_workspaces_ FOREIGN KEY (execution_workspace_id) REFERENCES public.execution_workspaces(id) ON DELETE SET NULL;


--
-- Name: tool_runtime_slots tool_runtime_slots_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_runtime_slots
    ADD CONSTRAINT tool_runtime_slots_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE SET NULL;


--
-- Name: tool_runtime_slots tool_runtime_slots_project_workspace_id_project_workspaces_id_f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_runtime_slots
    ADD CONSTRAINT tool_runtime_slots_project_workspace_id_project_workspaces_id_f FOREIGN KEY (project_workspace_id) REFERENCES public.project_workspaces(id) ON DELETE SET NULL;


--
-- Name: tool_stdio_command_templates tool_stdio_command_templates_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_stdio_command_templates
    ADD CONSTRAINT tool_stdio_command_templates_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: tool_stdio_command_templates tool_stdio_command_templates_created_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_stdio_command_templates
    ADD CONSTRAINT tool_stdio_command_templates_created_by_agent_id_agents_id_fk FOREIGN KEY (created_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: user_inbox_agent_policies user_inbox_agent_policies_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_inbox_agent_policies
    ADD CONSTRAINT user_inbox_agent_policies_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: user_secret_declarations user_secret_declarations_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_secret_declarations
    ADD CONSTRAINT user_secret_declarations_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: user_secret_declarations user_secret_declarations_user_secret_definition_id_user_secret_; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_secret_declarations
    ADD CONSTRAINT user_secret_declarations_user_secret_definition_id_user_secret_ FOREIGN KEY (user_secret_definition_id) REFERENCES public.user_secret_definitions(id) ON DELETE CASCADE;


--
-- Name: user_secret_definitions user_secret_definitions_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_secret_definitions
    ADD CONSTRAINT user_secret_definitions_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: user_secret_definitions user_secret_definitions_created_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_secret_definitions
    ADD CONSTRAINT user_secret_definitions_created_by_agent_id_agents_id_fk FOREIGN KEY (created_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: user_secret_definitions user_secret_definitions_provider_config_id_company_secret_provi; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_secret_definitions
    ADD CONSTRAINT user_secret_definitions_provider_config_id_company_secret_provi FOREIGN KEY (provider_config_id) REFERENCES public.company_secret_provider_configs(id) ON DELETE SET NULL;


--
-- Name: user_secret_definitions user_secret_definitions_updated_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_secret_definitions
    ADD CONSTRAINT user_secret_definitions_updated_by_agent_id_agents_id_fk FOREIGN KEY (updated_by_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: work_assessments work_assessments_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_assessments
    ADD CONSTRAINT work_assessments_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: work_assessments work_assessments_contract_id_completion_contracts_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_assessments
    ADD CONSTRAINT work_assessments_contract_id_completion_contracts_id_fk FOREIGN KEY (contract_id) REFERENCES public.completion_contracts(id);


--
-- Name: work_assessments work_assessments_contract_owner_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_assessments
    ADD CONSTRAINT work_assessments_contract_owner_fk FOREIGN KEY (company_id, issue_id, contract_id) REFERENCES public.completion_contracts(company_id, issue_id, id);


--
-- Name: work_assessments work_assessments_issue_company_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_assessments
    ADD CONSTRAINT work_assessments_issue_company_fk FOREIGN KEY (company_id, issue_id) REFERENCES public.issues(company_id, id);


--
-- Name: work_assessments work_assessments_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_assessments
    ADD CONSTRAINT work_assessments_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id);


--
-- Name: work_assessments work_assessments_result_id_native_run_results_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_assessments
    ADD CONSTRAINT work_assessments_result_id_native_run_results_id_fk FOREIGN KEY (result_id) REFERENCES public.native_run_results(id);


--
-- Name: work_assessments work_assessments_result_owner_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_assessments
    ADD CONSTRAINT work_assessments_result_owner_fk FOREIGN KEY (company_id, issue_id, run_id, result_id) REFERENCES public.native_run_results(company_id, issue_id, run_id, id);


--
-- Name: work_assessments work_assessments_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_assessments
    ADD CONSTRAINT work_assessments_run_id_heartbeat_runs_id_fk FOREIGN KEY (run_id) REFERENCES public.heartbeat_runs(id);


--
-- Name: work_assessments work_assessments_run_owner_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_assessments
    ADD CONSTRAINT work_assessments_run_owner_fk FOREIGN KEY (company_id, issue_id, run_id) REFERENCES public.heartbeat_runs(company_id, native_issue_id, id);


--
-- Name: work_assessments work_assessments_supersedes_owner_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_assessments
    ADD CONSTRAINT work_assessments_supersedes_owner_fk FOREIGN KEY (company_id, issue_id, run_id, supersedes_assessment_id) REFERENCES public.work_assessments(company_id, issue_id, run_id, id);


--
-- Name: work_assessments work_assessments_trigger_actor_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_assessments
    ADD CONSTRAINT work_assessments_trigger_actor_company_id_companies_id_fk FOREIGN KEY (trigger_actor_company_id) REFERENCES public.companies(id);


--
-- Name: workspace_operations workspace_operations_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_operations
    ADD CONSTRAINT workspace_operations_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: workspace_operations workspace_operations_execution_workspace_id_execution_workspace; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_operations
    ADD CONSTRAINT workspace_operations_execution_workspace_id_execution_workspace FOREIGN KEY (execution_workspace_id) REFERENCES public.execution_workspaces(id) ON DELETE SET NULL NOT VALID;


--
-- Name: workspace_operations workspace_operations_heartbeat_run_id_heartbeat_runs_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_operations
    ADD CONSTRAINT workspace_operations_heartbeat_run_id_heartbeat_runs_id_fk FOREIGN KEY (heartbeat_run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL NOT VALID;


--
-- Name: workspace_operations workspace_operations_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_operations
    ADD CONSTRAINT workspace_operations_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE SET NULL;


--
-- Name: workspace_runtime_services workspace_runtime_services_company_id_companies_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_runtime_services
    ADD CONSTRAINT workspace_runtime_services_company_id_companies_id_fk FOREIGN KEY (company_id) REFERENCES public.companies(id) NOT VALID;


--
-- Name: workspace_runtime_services workspace_runtime_services_execution_workspace_id_execution_wor; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_runtime_services
    ADD CONSTRAINT workspace_runtime_services_execution_workspace_id_execution_wor FOREIGN KEY (execution_workspace_id) REFERENCES public.execution_workspaces(id) ON DELETE SET NULL NOT VALID;


--
-- Name: workspace_runtime_services workspace_runtime_services_issue_id_issues_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_runtime_services
    ADD CONSTRAINT workspace_runtime_services_issue_id_issues_id_fk FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE SET NULL NOT VALID;


--
-- Name: workspace_runtime_services workspace_runtime_services_owner_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_runtime_services
    ADD CONSTRAINT workspace_runtime_services_owner_agent_id_agents_id_fk FOREIGN KEY (owner_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL NOT VALID;


--
-- Name: workspace_runtime_services workspace_runtime_services_project_id_projects_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_runtime_services
    ADD CONSTRAINT workspace_runtime_services_project_id_projects_id_fk FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE SET NULL NOT VALID;


--
-- Name: workspace_runtime_services workspace_runtime_services_project_workspace_id_project_workspa; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_runtime_services
    ADD CONSTRAINT workspace_runtime_services_project_workspace_id_project_workspa FOREIGN KEY (project_workspace_id) REFERENCES public.project_workspaces(id) ON DELETE SET NULL NOT VALID;


--
-- Name: workspace_runtime_services workspace_runtime_services_started_by_run_id_heartbeat_runs_id_; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_runtime_services
    ADD CONSTRAINT workspace_runtime_services_started_by_run_id_heartbeat_runs_id_ FOREIGN KEY (started_by_run_id) REFERENCES public.heartbeat_runs(id) ON DELETE SET NULL NOT VALID;


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

\unrestrict kruxrSR3rfDfiu7HBsx07WzR94MUWxeagqxAabjIq5AneSX2n7E1c2fMtTGaKWV

