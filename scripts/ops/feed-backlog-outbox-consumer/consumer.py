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

import json
import logging
import os
import re
import sys
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional, Tuple

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
# (`dispatchStartedAt`), no other worker may reclaim the intent until this
# much longer grace period has elapsed, even if the ordinary claim lease
# has expired. This is deliberately far larger than any single HTTP call
# (the Paperclip client uses a 20s timeout) so a live in-flight dispatch is
# never preempted; a worker that is truly dead still frees the intent for
# reclaim eventually.
DISPATCH_RECLAIM_GRACE_SECONDS = 1800

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
    """Redact credential/PII-shaped substrings, then bound to 512 chars."""
    text = str(error or "")
    text = _COOKIE_PATTERN.sub("<cookie>", text)
    text = _AUTH_SCHEME_PATTERN.sub("<auth>", text)
    text = _AUTH_BARE_PATTERN.sub("<auth>", text)
    text = _KV_SECRET_PATTERN.sub("<credential>", text)
    text = _EMAIL_PATTERN.sub("<email>", text)
    text = _LONG_OPAQUE_PATTERN.sub("<long_id>", text)
    text = _SHORT_OPAQUE_PATTERN.sub("<short_token>", text)
    text = _DIGIT_RUN_PATTERN.sub("<long_id>", text)
    return text[:MAX_LAST_ERROR_CHARS]


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
            timeout=20,
        )
        resp.raise_for_status()
        data = resp.json()
        return data if isinstance(data, list) else data.get("items", [])

    def get_issue(self, issue_id: str) -> Dict[str, Any]:
        resp = self._session.get(f"{self._base}/api/issues/{issue_id}", timeout=20)
        resp.raise_for_status()
        return resp.json()

    def create_issue(self, body: Dict[str, Any]) -> Dict[str, Any]:
        resp = self._session.post(
            f"{self._base}/api/companies/{self._company_id}/issues",
            json=body,
            timeout=20,
        )
        resp.raise_for_status()
        return resp.json()

    def patch_issue(self, issue_id: str, body: Dict[str, Any]) -> Dict[str, Any]:
        resp = self._session.patch(f"{self._base}/api/issues/{issue_id}", json=body, timeout=20)
        resp.raise_for_status()
        return resp.json()

    def list_comments(self, issue_id: str) -> List[Dict[str, Any]]:
        resp = self._session.get(f"{self._base}/api/issues/{issue_id}/comments", timeout=20)
        resp.raise_for_status()
        data = resp.json()
        return data if isinstance(data, list) else data.get("items", [])

    def post_comment(self, issue_id: str, body: str) -> Dict[str, Any]:
        resp = self._session.post(f"{self._base}/api/issues/{issue_id}/comments", json={"body": body}, timeout=20)
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
    dispatch_create/dispatch_escalation. This is the correctness backstop
    for REVA-27715 review round 5's finding: no purely time-based fence
    (mark_dispatch_started's pre-call recheck, DISPATCH_RECLAIM_GRACE_SECONDS)
    can close the check-then-act gap to zero probability in a single
    process without cooperation from the remote side, because the gap
    between "the fence check passed" and "the HTTP call actually executes"
    can itself be stalled arbitrarily long by process/scheduler pauses --
    any fixed grace period only shrinks that window, it cannot prove it
    away. The Paperclip issues API was verified (via this module's own
    PaperclipClient, docs, and prior review evidence) to expose no
    client-supplied idempotency/dedupe key on create; adding one would be a
    platform-code change outside this ticket's Ops-only scope
    (feed-backlog-outbox-consumer script), so provider-enforced fencing is
    not an available option here.

    Instead this makes the OUTCOME deterministic rather than the timing:
    re-query the real remote state for every issue carrying this exact
    idempotency marker right after our own create call. If a race actually
    produced more than one, the earliest-created issue is the canonical
    winner and every other one is immediately closed with a comment
    pointing at the canonical id. This guarantees at most one *live* issue
    for a given idempotency key survives a dispatch cycle regardless of how
    many workers' HTTP calls actually landed, which is the practically
    achievable form of "a reclaimed worker cannot leave a lasting
    duplicate" when true prevention isn't available."""
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
        return existing["id"], existing.get("status", "unknown")

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

    superseded_intent = collection.find_one({"id": superseded_intent_id})
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
        return existing["id"], existing.get("status", "unknown")

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
    client: MongoClient = MongoClient(config.mongo_url, serverSelectionTimeoutMS=10000)
    return client[config.db_name][OUTBOX_COLLECTION_NAME]


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
    (`dispatchStartedAt` unset); or a remote dispatch was started but
    DISPATCH_RECLAIM_GRACE_SECONDS have passed since (covers a worker that
    genuinely crashed mid-dispatch). This last condition is what stops a
    worker whose ordinary claim lease merely expired *during* an in-flight
    remote call from being preempted by a reclaim — see `_fence_dispatch`
    for the other half of this protection (REVA-27715 review round 4
    finding #1). The atomicity comes from Mongo's single-document
    find_one_and_update, not from any read-then-write in this process."""
    now = datetime.now(timezone.utc)
    now_iso = now.isoformat()
    dispatch_grace_cutoff_iso = (now - timedelta(seconds=DISPATCH_RECLAIM_GRACE_SECONDS)).isoformat()
    lease_expires_at = (now + timedelta(seconds=lease_seconds)).isoformat()
    unclaimed = {"$or": [{"claimOwner": {"$exists": False}}, {"claimOwner": None}]}
    dispatch_not_in_flight = {
        "$or": [
            {"dispatchStartedAt": {"$exists": False}},
            {"dispatchStartedAt": None},
            {"dispatchStartedAt": {"$lt": dispatch_grace_cutoff_iso}},
        ]
    }
    # Sibling top-level keys in a Mongo filter document are implicitly
    # ANDed, so merging the lease-expiry field predicate with the
    # dispatch_not_in_flight $or clause here has the same effect as an
    # explicit $and without needing one.
    lease_expired_and_reclaimable = {"claimLeaseExpiresAt": {"$lt": now_iso}, **dispatch_not_in_flight}
    return collection.find_one_and_update(
        {
            "id": intent_id,
            "workspaceId": workspace_id,
            "deliveryState": DELIVERY_STATE_PENDING,
            "$or": [unclaimed, lease_expired_and_reclaimable],
        },
        {
            "$set": {"claimOwner": owner, "claimedAt": now_iso, "claimLeaseExpiresAt": lease_expires_at},
            "$unset": {"dispatchStartedAt": ""},
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


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    try:
        config = ConsumerConfig.from_env()
    except RuntimeError as exc:
        logger.error(str(exc))
        return 2

    stats = run_once(config, run_id=os.environ.get("PAPERCLIP_RUN_ID"))
    logger.info("consumer cycle complete: %s", json.dumps(stats))
    return 0


if __name__ == "__main__":
    sys.exit(main())
