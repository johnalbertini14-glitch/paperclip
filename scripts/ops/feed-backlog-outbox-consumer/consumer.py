"""Company-root control-plane consumer for the durable feed-backlog outbox.

Context (REVA-27715 / REVA-27685 / REVA-27714): the Signatiq product repo
(RevCortex) no longer talks to the Paperclip control-plane API directly.
`backend/core/services/feed_backlog_outbox.py` instead persists durable
"intent" documents to the `gtm_backlog_outbox` MongoDB collection. This
module is the downstream consumer referenced in that file's own docstrings
("Populated by the downstream consumer (Ops Agent, REVA-27715)"): it reads
pending intents, renders them to real Paperclip issues via the internal
Paperclip API, and writes the acknowledgement/failure back to the same
outbox collection.

This module intentionally duplicates the outbox schema contract (collection
name, field names, state-machine transitions) rather than importing
RevCortex code — the two repos are independent (product vs. platform) and
share only a documented data contract, not a code dependency.

No Paperclip credential is read or written by the product repo. This
process owns the only PAPERCLIP_API_KEY reference in the whole pipeline.

Required environment variables (names only; values are never logged):
    MONGO_URL                 - RevCortex MongoDB connection string
    DB_NAME                   - RevCortex MongoDB database name
    PAPERCLIP_API_URL         - Paperclip control-plane base URL
    PAPERCLIP_API_KEY         - Paperclip control-plane bearer credential
    PAPERCLIP_COMPANY_ID      - Paperclip company id to create issues under

Optional environment variables:
    FEED_BACKLOG_CONSUMER_PROJECT_ID     - projectId applied to created issues
    FEED_BACKLOG_CONSUMER_CTO_AGENT_ID   - agent id the "local-board" symbolic
                                           assignee resolves to (CTO escalation
                                           routing); if unset, escalation
                                           intents are created unassigned and
                                           flagged in the description instead
                                           of guessing an id
    FEED_BACKLOG_CONSUMER_BATCH_LIMIT    - max pending intents per cycle
                                           (default 25)
    PAPERCLIP_RUN_ID                     - forwarded as X-Paperclip-Run-Id on
                                           mutating calls, if set
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import sys
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import urlsplit, urlunsplit

import requests
from pymongo import MongoClient, ReturnDocument
from pymongo.collection import Collection

logger = logging.getLogger("feed_backlog_outbox_consumer")

OUTBOX_COLLECTION_NAME = "gtm_backlog_outbox"

INTENT_KIND_CREATE = "create"
INTENT_KIND_UPDATE = "update"
INTENT_KIND_SUPERSESSION = "supersession"
INTENT_KIND_ESCALATION = "escalation"

DELIVERY_STATE_PENDING = "pending"
DELIVERY_STATE_ACKNOWLEDGED = "acknowledged"
DELIVERY_STATE_FAILED = "failed"

MAX_LAST_ERROR_CHARS = 512
MAX_DESCRIPTION_CHARS = 20000
DEFAULT_BATCH_LIMIT = 25
CLAIM_LEASE_SECONDS = 300
# Once a worker has recorded that it started a remote dispatch call
# (`dispatchStartedAt`), NO automatic, timer-based mechanism may ever
# reclaim the intent -- a fixed grace period only shrinks the probability
# of a second worker preempting a still-in-flight call, it cannot make
# that probability zero, because the gap between "the fence check passed"
# and "the HTTP call actually executes" can itself be stalled arbitrarily
# long by a process pause (REVA-27715 review round 6: reconciling a
# duplicate away after the fact does not satisfy the ticket's
# no-second-create requirement -- the second create must never happen).
# An intent stuck with `dispatchStartedAt` set requires a deliberate
# operator action (`force_release_stuck_dispatch`) to become reclaimable
# again, not a timeout.

MARKER_TEMPLATE = "<!-- outbox-intent:{key} -->"
MARKER_RE = re.compile(r"<!-- outbox-intent:(?P<key>\S+?) -->")

ASSIGNEE_SYMBOL_LOCAL_BOARD = "local-board"
_AGENT_ID_SHAPE_RE = re.compile(r"^[0-9a-f-]{20,}$", re.IGNORECASE)


# --------------------------------------------------------------------- #
# PII / credential redaction — independently ported from the reviewed
# contract in RevCortex's feed_backlog_outbox.safe_error_summary. Any
# free-form exception text must pass through this before it is persisted
# to gtm_backlog_outbox.lastError or logged.
# --------------------------------------------------------------------- #
_COOKIE_PATTERN = re.compile(r"(?i)\bcookie\s*:\s*[^\n;]+")
_AUTH_SCHEME_PATTERN = re.compile(r"(?i)\b(bearer|basic|digest|token)\s+[A-Za-z0-9._\-+/=]+")
_AUTH_BARE_PATTERN = re.compile(r"(?i)\bauthorization\s*:\s*[A-Za-z0-9._\-+/=]{16,}")
_KV_SECRET_PATTERN = re.compile(
    r"(?i)\b(api[_-]?key|token|secret|password)\s*[:=]\s*['\"]?[A-Za-z0-9._\-+/=]{6,}['\"]?"
)
_EMAIL_PATTERN = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
_LONG_OPAQUE_PATTERN = re.compile(r"\b[A-Za-z0-9._\-+/=]{32,}\b")
_SHORT_OPAQUE_PATTERN = re.compile(r"\b[A-Za-z0-9._\-+/=]{16,31}\b")
_DIGIT_RUN_PATTERN = re.compile(r"\b\d{12,}\b")


def safe_error_summary(error: Any) -> str:
    """Redact credential/PII-shaped substrings, then bound to 512 chars.

    First strips URI userinfo from any HTTP / Redis / Mongo form that may
    appear in the text (e.g. a `ServerSelectionTimeoutError` whose message
    includes `mongodb://user:pass@atlas/...`), then applies the opaque-
    token / KV-secret / email / cookie / auth-scheme redactors. Without
    the URI step, a short username/password in a non-HTTP scheme URI
    (length below the opaque-token threshold) would survive this function
    and be persisted to `gtm_backlog_outbox.lastError`.
    """
    text = str(error or "")
    text = _URI_WITH_USERINFO_PATTERN.sub(_strip_uri_userinfo_from_match, text)
    text = _COOKIE_PATTERN.sub("<cookie>", text)
    text = _AUTH_SCHEME_PATTERN.sub("<auth>", text)
    text = _AUTH_BARE_PATTERN.sub("<auth>", text)
    text = _KV_SECRET_PATTERN.sub("<credential>", text)
    text = _EMAIL_PATTERN.sub("<email>", text)
    text = _LONG_OPAQUE_PATTERN.sub("<long_id>", text)
    text = _SHORT_OPAQUE_PATTERN.sub("<short_token>", text)
    text = _DIGIT_RUN_PATTERN.sub("<long_id>", text)
    return text[:MAX_LAST_ERROR_CHARS]


# Schemes whose URIs may carry userinfo (username[:password]@host) and must
# be redacted before persistence. This covers the full surface mentioned in
# the REVA-27985 review: HTTPS / MongoDB (plain + SRV) / Redis (plain + TLS).
# REVA-27985 finding #1 (security): the previous regex only matched `http(s)://`
# and therefore leaked Redis and MongoDB userinfo into `forceReleaseLog.note`
# whenever the operator note referenced such a URI. The pattern now matches
# every one of those schemes in a single pass.
_URI_SCHEMES_WITH_USERINFO = "(?:https?|rediss?|mongodb(?:\\+srv)?)"
_URI_WITH_USERINFO_PATTERN = re.compile(
    rf"{_URI_SCHEMES_WITH_USERINFO}://[^\s]+",
    re.IGNORECASE,
)


def _strip_uri_userinfo(uri: str) -> str:
    """Return `uri` with any `user[:password]@` component removed.

    Returns `uri` unchanged when it has no credentials.
    """
    parsed = urlsplit(uri)
    if parsed.username is None and parsed.password is None:
        return uri
    host = parsed.hostname or ""
    if parsed.port is not None:
        host = f"{host}:{parsed.port}"
    return urlunsplit((parsed.scheme, host, parsed.path, parsed.query, parsed.fragment))


def _strip_uri_userinfo_from_match(match: re.Match[str]) -> str:
    """`re.sub` replacement adapter that strips userinfo from the matched URI."""
    return _strip_uri_userinfo(match.group(0))


def sanitize_operator_note(note: str) -> str:
    """Persist a bounded note without URI userinfo or credential-shaped text.

    Strips the `user[:password]@` component from every supported URI scheme
    (http, https, redis, rediss, mongodb, mongodb+srv) before applying the
    general PII / credential redactor. The username / password must NEVER
    survive this function, regardless of which scheme the URI uses — the
    safe summary then catches any other credential-shaped substring (KV
    secrets, JWTs, opaque tokens) that might still be in the note.
    """
    without_userinfo = _URI_WITH_USERINFO_PATTERN.sub(_strip_uri_userinfo_from_match, note)
    return safe_error_summary(without_userinfo)


def _iso_now() -> str:
    return datetime.now(timezone.utc).isoformat()


class DispositionError(Exception):
    """The intent cannot be dispatched at all; mark it failed."""


class DeferIntent(Exception):
    """The intent isn't ready yet (a dependency hasn't been acknowledged);
    leave it pending untouched for a later cycle."""


class LostClaimError(Exception):
    """This worker's claim was superseded by another worker between
    claim_intent and the point of remote dispatch. The remote Paperclip
    mutation must NOT be attempted when this is raised."""


@dataclass(frozen=True)
class ConsumerConfig:
    mongo_url: str
    db_name: str
    paperclip_api_url: str
    paperclip_api_key: str
    paperclip_company_id: str
    project_id: Optional[str]
    cto_agent_id: Optional[str]
    batch_limit: int

    @classmethod
    def from_env(cls) -> "ConsumerConfig":
        required = ("MONGO_URL", "DB_NAME", "PAPERCLIP_API_URL", "PAPERCLIP_API_KEY", "PAPERCLIP_COMPANY_ID")
        missing = [name for name in required if not os.environ.get(name)]
        if missing:
            raise RuntimeError(f"Missing required env var(s): {', '.join(missing)}")
        return cls(
            mongo_url=os.environ["MONGO_URL"],
            db_name=os.environ["DB_NAME"],
            paperclip_api_url=os.environ["PAPERCLIP_API_URL"].rstrip("/"),
            paperclip_api_key=os.environ["PAPERCLIP_API_KEY"],
            paperclip_company_id=os.environ["PAPERCLIP_COMPANY_ID"],
            project_id=os.environ.get("FEED_BACKLOG_CONSUMER_PROJECT_ID") or None,
            cto_agent_id=os.environ.get("FEED_BACKLOG_CONSUMER_CTO_AGENT_ID") or None,
            batch_limit=int(os.environ.get("FEED_BACKLOG_CONSUMER_BATCH_LIMIT", str(DEFAULT_BATCH_LIMIT))),
        )


class PaperclipClient:
    """Thin wrapper around the internal Paperclip API. Holds the only
    PAPERCLIP_API_KEY reference in this pipeline; never logs it."""

    def __init__(self, config: ConsumerConfig, run_id: Optional[str] = None):
        self._base = config.paperclip_api_url
        self._company_id = config.paperclip_company_id
        self._session = requests.Session()
        self._session.headers["Authorization"] = f"Bearer {config.paperclip_api_key}"
        if run_id:
            self._session.headers["X-Paperclip-Run-Id"] = run_id

    def search_issues(self, query: str) -> List[Dict[str, Any]]:
        resp = self._session.get(
            f"{self._base}/api/companies/{self._company_id}/issues",
            params={"q": query},
            timeout=60,
        )
        resp.raise_for_status()
        data = resp.json()
        return data if isinstance(data, list) else data.get("items", [])

    def get_issue(self, issue_id: str) -> Dict[str, Any]:
        resp = self._session.get(f"{self._base}/api/issues/{issue_id}", timeout=60)
        resp.raise_for_status()
        return resp.json()

    def create_issue(self, body: Dict[str, Any]) -> Dict[str, Any]:
        resp = self._session.post(
            f"{self._base}/api/companies/{self._company_id}/issues",
            json=body,
            timeout=60,
        )
        resp.raise_for_status()
        return resp.json()

    def patch_issue(self, issue_id: str, body: Dict[str, Any]) -> Dict[str, Any]:
        resp = self._session.patch(f"{self._base}/api/issues/{issue_id}", json=body, timeout=60)
        resp.raise_for_status()
        return resp.json()

    def list_comments(self, issue_id: str) -> List[Dict[str, Any]]:
        resp = self._session.get(f"{self._base}/api/issues/{issue_id}/comments", timeout=60)
        resp.raise_for_status()
        data = resp.json()
        return data if isinstance(data, list) else data.get("items", [])

    def post_comment(self, issue_id: str, body: str) -> Dict[str, Any]:
        resp = self._session.post(f"{self._base}/api/issues/{issue_id}/comments", json={"body": body}, timeout=60)
        resp.raise_for_status()
        return resp.json()


# --------------------------------------------------------------------- #
# Idempotency marker — embedded in issue descriptions/comments so a
# retry after a remote-success/local-ack-write failure can find the
# already-created issue/comment instead of duplicating it.
# --------------------------------------------------------------------- #
def embed_marker(text: str, idempotency_key: str) -> str:
    return f"{text}\n\n{MARKER_TEMPLATE.format(key=idempotency_key)}"


def find_marker(text: Optional[str]) -> Optional[str]:
    match = MARKER_RE.search(text or "")
    return match.group("key") if match else None


def embed_marker_bounded(text: str, idempotency_key: str, max_chars: int = MAX_DESCRIPTION_CHARS) -> str:
    """Embed the marker and bound the result to max_chars, truncating the
    body content (never the marker) to make room. The old embed-then-
    truncate order could cut the marker off entirely at the size limit,
    which makes a replay after a remote-success/local-write failure unable
    to find the prior issue/comment and duplicates the external mutation
    (REVA-27715 review finding #1)."""
    suffix = f"\n\n{MARKER_TEMPLATE.format(key=idempotency_key)}"
    if len(suffix) >= max_chars:
        return suffix[-max_chars:] if max_chars > 0 else ""
    budget = max_chars - len(suffix)
    return f"{text[:budget]}{suffix}"


def find_existing_by_marker(client: PaperclipClient, idempotency_key: str) -> Optional[Dict[str, Any]]:
    for candidate in client.search_issues(idempotency_key):
        if find_marker(candidate.get("description")) == idempotency_key:
            return candidate
    return None


def reconcile_created_issue(
    client: PaperclipClient, idempotency_key: str, created_id: str, created_status: str
) -> Tuple[str, str]:
    """Called immediately after a remote create_issue call succeeds in
    dispatch_create/dispatch_escalation, AND on the marker-hit replay branch
    of both (a prior run, possibly this same worker resuming after an
    ambiguous crash, already found an existing issue for this idempotency
    key). This is defense-in-depth, not the primary duplicate-prevention
    mechanism: since REVA-27715 review round 6, `claim_intent` never
    reclaims an intent whose `dispatchStartedAt` is set (see its docstring)
    except via a deliberate operator call to `force_release_stuck_dispatch`,
    which is what actually stops a second worker from ever making a second
    real create_issue call for the same intent. This function's job is to
    converge state if a duplicate somehow still exists anyway -- e.g. an
    operator force-released a stuck dispatch before confirming remote state
    correctly, a bug predates this fix, or an intent was reprocessed after a
    manual data correction. It re-queries the real remote state for every
    issue carrying this exact idempotency marker. If more than one exists,
    the earliest-created issue is the canonical winner and every other one
    is immediately closed with a comment pointing at the canonical id, so at
    most one *live* issue for a given idempotency key survives being touched
    by this consumer again, regardless of how the duplicate arose."""
    candidates = [
        candidate
        for candidate in client.search_issues(idempotency_key)
        if find_marker(candidate.get("description")) == idempotency_key
    ]
    if len(candidates) <= 1:
        return created_id, created_status

    def sort_key(candidate: Dict[str, Any]) -> Tuple[str, str]:
        return (str(candidate.get("createdAt") or ""), str(candidate.get("id") or ""))

    canonical = min(candidates, key=sort_key)
    for duplicate in candidates:
        if duplicate["id"] == canonical["id"] or duplicate.get("status") == "done":
            continue
        client.patch_issue(
            duplicate["id"],
            {
                "status": "done",
                "comment": (
                    f"Closed as a concurrent-dispatch duplicate of {canonical['id']} "
                    f"(same outbox idempotency key `{idempotency_key}`); no manual action needed."
                ),
            },
        )
    return canonical["id"], canonical.get("status", created_status)


def comment_already_posted(client: PaperclipClient, issue_id: str, idempotency_key: str) -> bool:
    for comment in client.list_comments(issue_id):
        text = comment.get("body") if comment.get("body") is not None else comment.get("comment")
        if find_marker(text) == idempotency_key:
            return True
    return False


def _looks_like_agent_id(value: str) -> bool:
    return bool(_AGENT_ID_SHAPE_RE.match(value or ""))


def resolve_assignee(payload: Dict[str, Any], config: ConsumerConfig) -> Optional[str]:
    raw = payload.get("assigneeAgentId")
    if not raw:
        return None
    if raw == ASSIGNEE_SYMBOL_LOCAL_BOARD:
        if not config.cto_agent_id:
            logger.warning(
                "assignee symbol 'local-board' seen but FEED_BACKLOG_CONSUMER_CTO_AGENT_ID is unset; "
                "leaving issue unassigned"
            )
            return None
        return config.cto_agent_id
    if _looks_like_agent_id(raw):
        return raw
    logger.warning("unmapped assignee symbol %r; leaving issue unassigned", raw)
    return None


def render_description(payload: Dict[str, Any], idempotency_key: str, intent: Dict[str, Any]) -> str:
    body = str(payload.get("body") or payload.get("description") or "").strip()
    metadata_lines = ["", "---", "**Feed metadata** (from durable outbox intent; product-native, not user-authored):"]
    for key in (
        "feedFingerprint",
        "feedRecurrenceCount",
        "feedBlockedPlaceholder",
        "feedPriorityScoreBreakdown",
        "crmMutation",
        "goalId",
        "governance_note",
        "tags",
        "autonomy_gate_bypass_provenance",
    ):
        value = payload.get(key)
        if value not in (None, "", [], {}):
            metadata_lines.append(f"- `{key}`: {value}")
    metadata_lines.append(f"- `retrospectiveRunId`: {intent.get('retrospectiveRunId', 'unknown')}")
    metadata_lines.append(f"- `intentId`: {intent.get('id', 'unknown')}")
    rendered = body + "\n" + "\n".join(metadata_lines)
    return embed_marker_bounded(rendered, idempotency_key, MAX_DESCRIPTION_CHARS)


# --------------------------------------------------------------------- #
# Per-kind dispatch. Each returns (externalIssueId, externalIssueStatus)
# or raises DeferIntent / propagates for the caller to mark failed.
# --------------------------------------------------------------------- #
def _fence_dispatch(collection: Collection, intent: Dict[str, Any], owner: str) -> None:
    """Must be called immediately before the remote Paperclip mutation in
    every dispatch_* function, after the pre-existing-marker check and
    after all local, non-mutating computation. Atomically re-verifies (via
    a single Mongo write scoped to `claimOwner: owner`) that this worker
    still owns the claim at the last possible moment before the network
    call. If the claim was lost — e.g. this worker stalled between its
    marker search and this point long enough for its lease to expire and a
    newer worker to legitimately reclaim and fully dispatch — this raises
    LostClaimError instead of allowing a second remote mutation for the
    same intent (REVA-27715 review round 4 finding #1)."""
    if not mark_dispatch_started(collection, intent["id"], intent["workspaceId"], owner):
        raise LostClaimError(f"claim lost before remote dispatch for intent {intent['id']}")


def dispatch_create(
    client: PaperclipClient, config: ConsumerConfig, collection: Collection, intent: Dict[str, Any], owner: str
) -> Tuple[str, str]:
    payload = intent.get("payload") or {}
    idempotency_key = intent["idempotencyKey"]

    existing = find_existing_by_marker(client, idempotency_key)
    if existing is not None:
        # A replay path (e.g. resuming after an ambiguous crash whose
        # outcome was unknown) must reconcile too, not just the
        # freshly-created path below -- otherwise a duplicate left over
        # from before this worker ever ran (concurrent dispatch, a manual
        # force-release, or any other source) is silently ignored forever
        # instead of being closed on the very next cycle that touches this
        # idempotency key (REVA-27715 review round 6 finding).
        return reconcile_created_issue(
            client, idempotency_key, existing["id"], existing.get("status", "unknown")
        )

    title = str(payload.get("title") or intent.get("signalType") or "Feed backlog item")[:200]
    body: Dict[str, Any] = {
        "title": title,
        "description": render_description(payload, idempotency_key, intent),
        "priority": payload.get("priority") or "medium",
        "projectId": config.project_id,
    }
    assignee = resolve_assignee(payload, config)
    if assignee:
        body["assigneeAgentId"] = assignee
    if payload.get("parentId"):
        body["parentId"] = payload["parentId"]
    body = {key: value for key, value in body.items() if value is not None}

    _fence_dispatch(collection, intent, owner)
    created = client.create_issue(body)
    return reconcile_created_issue(client, idempotency_key, created["id"], created.get("status", "todo"))


def dispatch_update(
    client: PaperclipClient, config: ConsumerConfig, collection: Collection, intent: Dict[str, Any], owner: str
) -> Tuple[str, str]:
    payload = intent.get("payload") or {}
    target_id = intent.get("targetsExternalIssueId")
    if not target_id:
        raise DeferIntent("update intent has no targetsExternalIssueId yet; root CREATE not acknowledged")

    idempotency_key = intent["idempotencyKey"]
    if comment_already_posted(client, target_id, idempotency_key):
        issue = client.get_issue(target_id)
        return target_id, issue.get("status", "unknown")

    comment_body = str(payload.get("body") or payload.get("description") or "Feed evidence update.")
    comment_body = embed_marker_bounded(comment_body, idempotency_key, MAX_DESCRIPTION_CHARS)

    _fence_dispatch(collection, intent, owner)
    client.post_comment(target_id, comment_body)
    return target_id, "updated"


def dispatch_supersession(
    client: PaperclipClient, config: ConsumerConfig, collection: Collection, intent: Dict[str, Any], owner: str
) -> Tuple[str, str]:
    payload = intent.get("payload") or {}
    superseded_intent_id = intent.get("supersedesIntentId")
    if not superseded_intent_id:
        raise DispositionError("supersession intent missing supersedesIntentId")

    superseded_intent = collection.find_one(
        {"id": superseded_intent_id, "workspaceId": intent["workspaceId"]}
    )
    superseded_external_id = (superseded_intent or {}).get("externalIssueId")
    if not superseded_external_id:
        raise DeferIntent("superseded intent not yet acknowledged; no externalIssueId to close")

    idempotency_key = intent["idempotencyKey"]
    if comment_already_posted(client, superseded_external_id, idempotency_key):
        issue = client.get_issue(superseded_external_id)
        return superseded_external_id, issue.get("status", "unknown")

    note = str(payload.get("resolutionNote") or payload.get("body") or "Superseded by a newer executable intent.")
    comment = embed_marker_bounded(note, idempotency_key, MAX_DESCRIPTION_CHARS)

    _fence_dispatch(collection, intent, owner)
    client.patch_issue(superseded_external_id, {"status": "done", "comment": comment})
    return superseded_external_id, "done"


def dispatch_escalation(
    client: PaperclipClient, config: ConsumerConfig, collection: Collection, intent: Dict[str, Any], owner: str
) -> Tuple[str, str]:
    payload = intent.get("payload") or {}
    idempotency_key = intent["idempotencyKey"]

    existing = find_existing_by_marker(client, idempotency_key)
    if existing is not None:
        # See dispatch_create's identical comment: the replay path must
        # reconcile too, not just the freshly-created path below.
        return reconcile_created_issue(
            client, idempotency_key, existing["id"], existing.get("status", "unknown")
        )

    title = str(payload.get("title") or f"[Feed Escalation] {intent.get('signalType', 'unknown')}")[:200]
    body: Dict[str, Any] = {
        "title": title,
        "description": render_description(payload, idempotency_key, intent),
        "priority": payload.get("priority") or "high",
        "projectId": config.project_id,
    }
    assignee = resolve_assignee(payload, config)
    if assignee:
        body["assigneeAgentId"] = assignee
    body = {key: value for key, value in body.items() if value is not None}

    _fence_dispatch(collection, intent, owner)
    created = client.create_issue(body)
    return reconcile_created_issue(client, idempotency_key, created["id"], created.get("status", "todo"))


# --------------------------------------------------------------------- #
# Outbox persistence — mirrors the reviewed state machine in
# feed_backlog_outbox.py: pending/failed -> acknowledged (terminal),
# pending -> failed. Scoped by (id, workspaceId) on every write.
# --------------------------------------------------------------------- #
def get_collection(config: ConsumerConfig) -> Collection:
    client: MongoClient = MongoClient(config.mongo_url, serverSelectionTimeoutMS=60000)
    collection = client[config.db_name][OUTBOX_COLLECTION_NAME]
    # Retain the owning client on the collection so CLI commands can close it
    # deterministically after a one-shot operation.
    setattr(collection, "_feed_backlog_client", client)
    return collection


def close_collection(collection: Collection) -> None:
    client = getattr(collection, "_feed_backlog_client", None)
    if client is not None:
        client.close()


def fetch_pending_intents(collection: Collection, limit: int) -> List[Dict[str, Any]]:
    cursor = collection.find({"deliveryState": DELIVERY_STATE_PENDING}).sort("createdAt", 1).limit(limit)
    return list(cursor)


def claim_intent(
    collection: Collection, intent_id: str, workspace_id: str, owner: str, lease_seconds: int = CLAIM_LEASE_SECONDS
) -> Optional[Dict[str, Any]]:
    """Atomically claim a pending intent before any remote dispatch, so two
    concurrent consumer invocations can't both observe the same unclaimed
    pending intent and both issue the remote mutation (REVA-27715 review
    finding #2). Matches only if the intent is still pending AND either:
    unclaimed; or its previous claim's ordinary lease has expired AND that
    worker never reached the point of starting a remote dispatch call
    (`dispatchStartedAt` unset). Once `dispatchStartedAt` is set, this
    function will NEVER match that intent again on its own, however long
    ago that was: a timer cannot distinguish "the owning worker crashed
    before its HTTP call reached the server" from "the owning worker paused
    and its HTTP call is still going to land any moment", and matching in
    the latter case is exactly what lets a second worker also fire a real
    remote mutation for the same intent (REVA-27715 review round 6 finding
    -- reconciling the resulting duplicate away afterward does not satisfy
    the ticket's no-second-create requirement). An intent stuck with
    `dispatchStartedAt` set is left pending-but-unclaimable until
    `force_release_stuck_dispatch` is called deliberately by an operator who
    has confirmed out-of-band (e.g. via a marker search against live
    Paperclip state) that reclaiming it is safe. The atomicity of the claim
    itself comes from Mongo's single-document find_one_and_update, not from
    any read-then-write in this process."""
    now = datetime.now(timezone.utc)
    now_iso = now.isoformat()
    lease_expires_at = (now + timedelta(seconds=lease_seconds)).isoformat()
    unclaimed = {"$or": [{"claimOwner": {"$exists": False}}, {"claimOwner": None}]}
    dispatch_never_started = {"$or": [{"dispatchStartedAt": {"$exists": False}}, {"dispatchStartedAt": None}]}
    # Sibling top-level keys in a Mongo filter document are implicitly
    # ANDed, so merging the lease-expiry field predicate with the
    # dispatch_never_started $or clause here has the same effect as an
    # explicit $and without needing one.
    lease_expired_and_reclaimable = {"claimLeaseExpiresAt": {"$lt": now_iso}, **dispatch_never_started}
    return collection.find_one_and_update(
        {
            "id": intent_id,
            "workspaceId": workspace_id,
            "deliveryState": DELIVERY_STATE_PENDING,
            "$or": [unclaimed, lease_expired_and_reclaimable],
        },
        {
            "$set": {"claimOwner": owner, "claimedAt": now_iso, "claimLeaseExpiresAt": lease_expires_at},
        },
        return_document=ReturnDocument.AFTER,
    )


def mark_dispatch_started(collection: Collection, intent_id: str, workspace_id: str, owner: str) -> bool:
    """Atomically records that `owner` is about to make the remote
    Paperclip call for this intent, scoped to `owner` still holding the
    claim right now. Returns False (and the caller must NOT proceed to the
    remote call) if the claim was already lost to a newer worker. This is
    the fencing check that closes the non-atomic marker-search -> create
    gap: without it, a worker that stalls after checking for an existing
    marker has nothing stopping it from calling the remote API even after
    its claim has been legitimately reclaimed (REVA-27715 review round 4
    finding #1)."""
    result = collection.update_one(
        {"id": intent_id, "workspaceId": workspace_id, "claimOwner": owner},
        {"$set": {"dispatchStartedAt": _iso_now()}},
    )
    return result.matched_count > 0


def release_claim(collection: Collection, intent_id: str, workspace_id: str, owner: str) -> None:
    """Only clears the claim if `owner` still holds it. Without this scope,
    a worker whose lease already expired (and was superseded by a newer
    worker's claim_intent call) could still wipe that newer worker's live
    claim when its own stalled dispatch finally returns, letting a third
    worker claim the same intent while the second worker is still
    mid-dispatch (REVA-27715 review finding #3)."""
    collection.update_one(
        {"id": intent_id, "workspaceId": workspace_id, "claimOwner": owner},
        {"$unset": {"claimOwner": "", "claimedAt": "", "claimLeaseExpiresAt": "", "dispatchStartedAt": ""}},
    )


def verify_remote_marker_state(
    client: PaperclipClient, idempotency_key: str
) -> Dict[str, Any]:
    matches = [
        candidate
        for candidate in client.search_issues(idempotency_key)
        if find_marker(candidate.get("description")) == idempotency_key
    ]
    return {
        "idempotencyKey": idempotency_key,
        "issueCount": len(matches),
        "issueIds": [str(candidate.get("id")) for candidate in matches if candidate.get("id")],
        "verifiedAt": _iso_now(),
    }


def force_release_stuck_dispatch(
    collection: Collection,
    intent_id: str,
    workspace_id: str,
    expected_owner: str,
    operator_note: str,
    verified_marker_state: Optional[Dict[str, Any]] = None,
) -> bool:
    """The deliberate, human-invoked recovery path for an intent whose
    `dispatchStartedAt` is set and will therefore never be reclaimed
    automatically by `claim_intent` (see its docstring) -- its owning
    worker crashed or hung somewhere between starting the remote dispatch
    and this consumer's next successful cycle. This function does not
    itself contact the Paperclip API or decide whether reclaiming is safe;
    the caller must have already confirmed real remote state out-of-band
    (typically: search Paperclip for the intent's idempotency marker and
    note whether an issue already exists) and record that confirmation in
    `operator_note`, which is required to be non-empty so a stuck claim can
    never be cleared silently. Scoped to `expected_owner` still holding the
    claim, matching the scoping discipline used everywhere else in this
    module, so a second concurrent force-release attempt is a safe no-op
    rather than a double-clear."""
    if not operator_note.strip():
        raise ValueError("operator_note is required to force-release a stuck dispatch claim")
    if verified_marker_state is None:
        raise ValueError("verified_marker_state is required to force-release a stuck dispatch claim")
    result = collection.update_one(
        {
            "id": intent_id,
            "workspaceId": workspace_id,
            "claimOwner": expected_owner,
            "dispatchStartedAt": {"$exists": True, "$ne": None},
        },
        {
            "$unset": {"claimOwner": "", "claimedAt": "", "claimLeaseExpiresAt": "", "dispatchStartedAt": ""},
            "$push": {
                "forceReleaseLog": {
                    "releasedOwner": expected_owner,
                    "note": sanitize_operator_note(operator_note),
                    "verifiedMarkerState": verified_marker_state,
                    "at": _iso_now(),
                }
            },
        },
    )
    return result.matched_count > 0


def mark_acknowledged(
    collection: Collection,
    intent_id: str,
    workspace_id: str,
    external_issue_id: str,
    external_status: str,
    owner: str,
) -> bool:
    """Scoped to `claimOwner: owner` for the same reason as release_claim:
    an expired worker's stale success must not overwrite state a newer
    worker's claim now governs."""
    if not external_issue_id:
        raise ValueError("external_issue_id must be non-empty to acknowledge an intent")
    result = collection.update_one(
        {
            "id": intent_id,
            "workspaceId": workspace_id,
            "deliveryState": {"$in": [DELIVERY_STATE_PENDING, DELIVERY_STATE_FAILED]},
            "claimOwner": owner,
        },
        {
            "$set": {
                "deliveryState": DELIVERY_STATE_ACKNOWLEDGED,
                "externalIssueId": external_issue_id,
                "externalIssueStatus": external_status,
                "lastError": None,
                "updatedAt": _iso_now(),
            },
            "$inc": {"deliveryAttempts": 1},
        },
    )
    return result.matched_count > 0


def mark_failed(collection: Collection, intent_id: str, workspace_id: str, error: Any, owner: str) -> bool:
    """Scoped to `claimOwner: owner` for the same reason as release_claim."""
    result = collection.update_one(
        {
            "id": intent_id,
            "workspaceId": workspace_id,
            "deliveryState": DELIVERY_STATE_PENDING,
            "claimOwner": owner,
        },
        {
            "$set": {
                "deliveryState": DELIVERY_STATE_FAILED,
                "lastError": safe_error_summary(error),
                "updatedAt": _iso_now(),
            },
            "$inc": {"deliveryAttempts": 1},
        },
    )
    return result.matched_count > 0


def requeue_failed_intent(collection: Collection, intent_id: str, workspace_id: str) -> bool:
    result = collection.update_one(
        {"id": intent_id, "workspaceId": workspace_id, "deliveryState": DELIVERY_STATE_FAILED},
        {
            "$set": {"deliveryState": DELIVERY_STATE_PENDING, "lastError": None, "updatedAt": _iso_now()},
            "$unset": {"claimOwner": "", "claimedAt": "", "claimLeaseExpiresAt": "", "dispatchStartedAt": ""},
        },
    )
    return result.matched_count > 0


def process_intent(
    client: PaperclipClient,
    config: ConsumerConfig,
    collection: Collection,
    intent: Dict[str, Any],
    owner: Optional[str] = None,
) -> str:
    intent_id = intent["id"]
    workspace_id = intent["workspaceId"]
    kind = intent.get("intentKind")
    owner = owner or f"pid:{os.getpid()}:{uuid.uuid4().hex[:8]}"

    claimed = claim_intent(collection, intent_id, workspace_id, owner)
    if claimed is None:
        logger.info(
            "intent id=%s kind=%s not claimed (already claimed by another worker or no longer pending); skipping",
            intent_id,
            kind,
        )
        return "skipped_claimed"

    try:
        if kind == INTENT_KIND_CREATE:
            external_id, external_status = dispatch_create(client, config, collection, intent, owner)
        elif kind == INTENT_KIND_UPDATE:
            external_id, external_status = dispatch_update(client, config, collection, intent, owner)
        elif kind == INTENT_KIND_SUPERSESSION:
            external_id, external_status = dispatch_supersession(client, config, collection, intent, owner)
        elif kind == INTENT_KIND_ESCALATION:
            external_id, external_status = dispatch_escalation(client, config, collection, intent, owner)
        else:
            raise DispositionError(f"unknown intentKind {kind!r}")
    except DeferIntent as exc:
        logger.info("deferring intent id=%s kind=%s: %s", intent_id, kind, exc)
        release_claim(collection, intent_id, workspace_id, owner)
        return "deferred"
    except LostClaimError as exc:
        # The claim was superseded by a newer worker before the remote
        # mutation was attempted, so no Paperclip API call was made and
        # nothing needs to be persisted. Do not release_claim here: it is
        # scoped to `claimOwner: owner`, and this worker no longer holds
        # that claim, so it would be a harmless no-op anyway.
        logger.info("intent id=%s kind=%s lost its claim before remote dispatch: %s", intent_id, kind, exc)
        return "lost_claim"
    except Exception as exc:  # noqa: BLE001 - every dispatch failure must be persisted, never silently dropped
        persisted = False
        try:
            persisted = mark_failed(collection, intent_id, workspace_id, exc, owner)
        except Exception:
            logger.exception("failed to persist failure state for intent id=%s", intent_id)
        release_claim(collection, intent_id, workspace_id, owner)
        logger.error(
            "intent id=%s kind=%s dispatch failed (persisted=%s): %s",
            intent_id,
            kind,
            persisted,
            safe_error_summary(exc),
        )
        return "failed"

    acked = mark_acknowledged(collection, intent_id, workspace_id, external_id, external_status, owner)
    release_claim(collection, intent_id, workspace_id, owner)
    if not acked:
        # The remote mutation succeeded, but by the time we tried to
        # persist that locally, a newer worker had already superseded this
        # worker's claim (REVA-27715 review round 4 finding #2). This is
        # NOT a successful acknowledgement from this worker's point of
        # view: the newer worker's claim/state governs, and run statistics
        # must not silently report success for a lost claim.
        logger.warning(
            "intent id=%s already resolved by a concurrent run; external_id=%s not re-applied locally",
            intent_id,
            external_id,
        )
        return "lost_claim"
    return "acknowledged"


def run_once(config: ConsumerConfig, run_id: Optional[str] = None) -> Dict[str, int]:
    collection = get_collection(config)
    try:
        client = PaperclipClient(config, run_id=run_id)
        owner = run_id or f"pid:{os.getpid()}:{uuid.uuid4().hex[:8]}"
        stats: Dict[str, int] = {
            "pending_seen": 0,
            "acknowledged": 0,
            "deferred": 0,
            "failed": 0,
            "skipped_claimed": 0,
            "lost_claim": 0,
        }
        for intent in fetch_pending_intents(collection, config.batch_limit):
            stats["pending_seen"] += 1
            outcome = process_intent(client, config, collection, intent, owner=owner)
            stats[outcome] = stats.get(outcome, 0) + 1
        return stats
    finally:
        close_collection(collection)


def _cmd_run(args: argparse.Namespace, config: ConsumerConfig) -> int:
    """Run a single one-shot consumer cycle (the default subcommand).

    A single cycle processes up to `FEED_BACKLOG_CONSUMER_BATCH_LIMIT`
    pending intents and exits -- this is intentionally not a long-running
    daemon. It is meant to be invoked on a schedule (cron / Paperclip
    routine) by whichever team owns the credential binding; no
    Paperclip/Hermes runtime restart or new service process is
    authorized by board approval `e95d6c05` for this change.
    """
    stats = run_once(config, run_id=os.environ.get("PAPERCLIP_RUN_ID"))
    logger.info("consumer cycle complete: %s", json.dumps(stats))
    # Always print the stats as the last JSON line on stdout so an
    # operator (or scheduler) can scrape the cycle outcome without
    # having to grep the log stream.
    print(json.dumps(stats))
    return 0


def _cmd_recover_stuck(args: argparse.Namespace, config: ConsumerConfig) -> int:
    """Deliberately clear a stuck dispatch claim.

    An intent whose `dispatchStartedAt` is set will never be reclaimed
    automatically (see `claim_intent`'s docstring and REVA-27715 round 6).
    The only sanctioned recovery is this operator action. The operator
    MUST supply `--operator-note` (non-empty) recording the out-of-band
    confirmation that real remote state has been checked (typically:
    search Paperclip for the intent's idempotency marker and note whether
    an issue already exists) -- a stuck claim can never be cleared
    silently. `--expected-owner` MUST match the worker that currently
    holds the claim; the Mongo update is scoped to that owner so a
    second concurrent force-release attempt is a safe no-op rather than
    a double-clear.

    Exit codes:
        0 -- matched and cleared (the Mongo update modified one document)
        2 -- no match (the intent is no longer held by `--expected-owner`,
             or its `dispatchStartedAt` is no longer set -- this is a
             safe no-op; the operator should re-check why they believed
             the dispatch was stuck)
        3 -- invalid invocation (empty operator note, missing required
             flag, etc.)
    """
    operator_note = (args.operator_note or "").strip()
    if not operator_note:
        logger.error("refusing to force-release: --operator-note is required and must be non-empty")
        return 3
    if not args.intent_id or not args.workspace_id or not args.expected_owner:
        logger.error(
            "refusing to force-release: --intent-id, --workspace-id, and --expected-owner are all required"
        )
        return 3

    # Honor a dry-run request without touching Mongo. Useful for an
    # operator who wants to confirm the discovery query before committing.
    if args.dry_run:
        collection = get_collection(config)
        try:
            existing = collection.find_one(
                {
                    "id": args.intent_id,
                    "workspaceId": args.workspace_id,
                    "claimOwner": args.expected_owner,
                    "dispatchStartedAt": {"$exists": True, "$ne": None},
                },
                projection={"_id": 1, "id": 1, "workspaceId": 1, "intentKind": 1, "claimOwner": 1, "dispatchStartedAt": 1, "claimedAt": 1, "deliveryState": 1},
            )
        finally:
            close_collection(collection)
        if existing is None:
            print(
                json.dumps(
                    {
                        "outcome": "no_match",
                        "intent_id": args.intent_id,
                        "workspace_id": args.workspace_id,
                        "expected_owner": args.expected_owner,
                        "message": "no intent matches the requested stuck-dispatch filter; nothing to release",
                    }
                )
            )
            return 2
        print(
            json.dumps(
                {
                    "outcome": "would_release",
                    "intent_id": existing.get("id"),
                    "workspace_id": existing.get("workspaceId"),
                    "intent_kind": existing.get("intentKind"),
                    "claim_owner": existing.get("claimOwner"),
                    "dispatch_started_at": existing.get("dispatchStartedAt"),
                    "claimed_at": existing.get("claimedAt"),
                    "delivery_state": existing.get("deliveryState"),
                    "operator_note_was": sanitize_operator_note(operator_note),
                },
                default=str,
            )
        )
        return 0

    collection = get_collection(config)
    try:
        existing = collection.find_one(
            {
                "id": args.intent_id,
                "workspaceId": args.workspace_id,
                "claimOwner": args.expected_owner,
                "dispatchStartedAt": {"$exists": True, "$ne": None},
            }
        )
        if existing is None:
            released = False
        else:
            idempotency_key = existing.get("idempotencyKey")
            if not idempotency_key:
                logger.error("refusing to force-release: persisted intent has no idempotencyKey")
                return 3
            verified_marker_state = verify_remote_marker_state(
                PaperclipClient(config, run_id=os.environ.get("PAPERCLIP_RUN_ID")), idempotency_key
            )
            released = force_release_stuck_dispatch(
                collection=collection,
                intent_id=args.intent_id,
                workspace_id=args.workspace_id,
                expected_owner=args.expected_owner,
                operator_note=operator_note,
                verified_marker_state=verified_marker_state,
            )
    finally:
        close_collection(collection)
    if not released:
        print(
            json.dumps(
                {
                    "outcome": "no_match",
                    "intent_id": args.intent_id,
                    "workspace_id": args.workspace_id,
                    "expected_owner": args.expected_owner,
                    "message": "no intent matches the requested stuck-dispatch filter; nothing was released",
                }
            )
        )
        logger.warning("force-release was a no-op (no matching stuck intent)")
        return 2
    print(
        json.dumps(
            {
                "outcome": "released",
                "intent_id": args.intent_id,
                "workspace_id": args.workspace_id,
                "expected_owner": args.expected_owner,
            }
        )
    )
    logger.info("force-released stuck dispatch: intent_id=%s owner=%s", args.intent_id, args.expected_owner)
    return 0


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="consumer.py",
        description=(
            "Feed-backlog outbox consumer (REVA-27715 / REVA-27685). "
            "Reads pending intents from the durable `gtm_backlog_outbox` "
            "collection in product Mongo and renders them to real "
            "Paperclip issues, OR clears a stuck dispatch claim with the "
            "sanctioned operator recovery action."
        ),
    )
    subparsers = parser.add_subparsers(dest="command", required=False)

    run = subparsers.add_parser(
        "run",
        help="Process up to FEED_BACKLOG_CONSUMER_BATCH_LIMIT pending intents and exit (default).",
        description=(
            "One-shot batch consumer cycle. Reads pending intents from "
            "Mongo, atomically claims each, dispatches via the Paperclip "
            "API, and writes acknowledgement/failure back. Exits when the "
            "batch is drained or the batch limit is reached."
        ),
    )
    run.set_defaults(func=_cmd_run)

    recover = subparsers.add_parser(
        "recover-stuck",
        help="Operator recovery: clear a stuck dispatch claim (REVA-27715 round 6).",
        description=(
            "Clear a dispatch claim whose `dispatchStartedAt` is set and "
            "which would otherwise never be reclaimed automatically. "
            "Requires --operator-note (non-empty) recording out-of-band "
            "confirmation that remote state has been checked."
        ),
    )
    recover.add_argument(
        "--intent-id",
        required=True,
        help="The `id` of the outbox intent whose stuck dispatch is to be cleared.",
    )
    recover.add_argument(
        "--workspace-id",
        required=True,
        help="The `workspaceId` of the same intent (the Mongo scope guard).",
    )
    recover.add_argument(
        "--expected-owner",
        required=True,
        help=(
            "The exact `claimOwner` value currently holding the claim. "
            "The Mongo update is scoped to this owner; a wrong value is a "
            "safe no-op rather than a wrong-target release."
        ),
    )
    recover.add_argument(
        "--operator-note",
        required=True,
        help=(
            "Non-empty operator note recording out-of-band confirmation "
            "that real remote state has been checked (typically: Paperclip "
            "search for the intent's idempotency marker). Required: a "
            "stuck claim can never be cleared silently."
        ),
    )
    recover.add_argument(
        "--dry-run",
        action="store_true",
        help="Discover the intent without modifying Mongo. Returns 0 if a stuck intent was found, 2 if not.",
    )
    recover.set_defaults(func=_cmd_recover_stuck)
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    parser = _build_parser()
    # Default to `run` when no subcommand is given so that
    # `python3 consumer.py` keeps behaving like the original one-shot
    # entrypoint (backward compatibility for any existing cron / Paperclip
    # routine that invokes the script without a subcommand).
    args = parser.parse_args(argv if argv is not None else sys.argv[1:])
    if args.command is None:
        args = parser.parse_args(["run"])

    try:
        config = ConsumerConfig.from_env()
    except RuntimeError as exc:
        logger.error(str(exc))
        return 2

    return args.func(args, config)


# Guard: prevents argparse from executing at import time during test discovery.
# Without this, `python3 -m unittest discover` runs consumer.py as __main__
# and exits with status 2 (usage error) before unittest can discover any tests,
# because the `run` subcommand is not given and `--help` exits 0 but the
# default-args path still tries to ConsumerConfig.from_env() which exits.
if __name__ == "__main__":
    sys.exit(main())
