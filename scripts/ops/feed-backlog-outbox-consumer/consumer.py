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
def dispatch_create(client: PaperclipClient, config: ConsumerConfig, intent: Dict[str, Any]) -> Tuple[str, str]:
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

    created = client.create_issue(body)
    return created["id"], created.get("status", "todo")


def dispatch_update(client: PaperclipClient, config: ConsumerConfig, intent: Dict[str, Any]) -> Tuple[str, str]:
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
    client.post_comment(target_id, comment_body)
    return target_id, "updated"


def dispatch_supersession(
    client: PaperclipClient, config: ConsumerConfig, collection: Collection, intent: Dict[str, Any]
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
    client.patch_issue(superseded_external_id, {"status": "done", "comment": comment})
    return superseded_external_id, "done"


def dispatch_escalation(client: PaperclipClient, config: ConsumerConfig, intent: Dict[str, Any]) -> Tuple[str, str]:
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

    created = client.create_issue(body)
    return created["id"], created.get("status", "todo")


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
    finding #2). Matches only if the intent is still pending AND either
    unclaimed or its previous claim's lease has already expired (covers a
    worker that crashed mid-dispatch without releasing). The atomicity
    comes from Mongo's single-document find_one_and_update, not from any
    read-then-write in this process."""
    now_iso = _iso_now()
    lease_expires_at = (datetime.now(timezone.utc) + timedelta(seconds=lease_seconds)).isoformat()
    return collection.find_one_and_update(
        {
            "id": intent_id,
            "workspaceId": workspace_id,
            "deliveryState": DELIVERY_STATE_PENDING,
            "$or": [
                {"claimOwner": {"$exists": False}},
                {"claimOwner": None},
                {"claimLeaseExpiresAt": {"$lt": now_iso}},
            ],
        },
        {"$set": {"claimOwner": owner, "claimedAt": now_iso, "claimLeaseExpiresAt": lease_expires_at}},
        return_document=ReturnDocument.AFTER,
    )


def release_claim(collection: Collection, intent_id: str, workspace_id: str) -> None:
    collection.update_one(
        {"id": intent_id, "workspaceId": workspace_id},
        {"$unset": {"claimOwner": "", "claimedAt": "", "claimLeaseExpiresAt": ""}},
    )


def mark_acknowledged(
    collection: Collection, intent_id: str, workspace_id: str, external_issue_id: str, external_status: str
) -> bool:
    if not external_issue_id:
        raise ValueError("external_issue_id must be non-empty to acknowledge an intent")
    result = collection.update_one(
        {
            "id": intent_id,
            "workspaceId": workspace_id,
            "deliveryState": {"$in": [DELIVERY_STATE_PENDING, DELIVERY_STATE_FAILED]},
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


def mark_failed(collection: Collection, intent_id: str, workspace_id: str, error: Any) -> bool:
    result = collection.update_one(
        {"id": intent_id, "workspaceId": workspace_id, "deliveryState": DELIVERY_STATE_PENDING},
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
            "$unset": {"claimOwner": "", "claimedAt": "", "claimLeaseExpiresAt": ""},
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
            external_id, external_status = dispatch_create(client, config, intent)
        elif kind == INTENT_KIND_UPDATE:
            external_id, external_status = dispatch_update(client, config, intent)
        elif kind == INTENT_KIND_SUPERSESSION:
            external_id, external_status = dispatch_supersession(client, config, collection, intent)
        elif kind == INTENT_KIND_ESCALATION:
            external_id, external_status = dispatch_escalation(client, config, intent)
        else:
            raise DispositionError(f"unknown intentKind {kind!r}")
    except DeferIntent as exc:
        logger.info("deferring intent id=%s kind=%s: %s", intent_id, kind, exc)
        release_claim(collection, intent_id, workspace_id)
        return "deferred"
    except Exception as exc:  # noqa: BLE001 - every dispatch failure must be persisted, never silently dropped
        persisted = False
        try:
            persisted = mark_failed(collection, intent_id, workspace_id, exc)
        except Exception:
            logger.exception("failed to persist failure state for intent id=%s", intent_id)
        release_claim(collection, intent_id, workspace_id)
        logger.error(
            "intent id=%s kind=%s dispatch failed (persisted=%s): %s",
            intent_id,
            kind,
            persisted,
            safe_error_summary(exc),
        )
        return "failed"

    acked = mark_acknowledged(collection, intent_id, workspace_id, external_id, external_status)
    release_claim(collection, intent_id, workspace_id)
    if not acked:
        logger.warning(
            "intent id=%s already resolved by a concurrent run; external_id=%s not re-applied locally",
            intent_id,
            external_id,
        )
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
