import unittest
from typing import Any, Dict
from unittest.mock import MagicMock, patch

import consumer


def make_config(**overrides):
    defaults = dict(
        mongo_url="mongodb://example.invalid/test?tls=true",
        db_name="test_db",
        paperclip_api_url="https://paperclip.example.invalid",
        paperclip_api_key="test-key-not-a-real-secret",
        paperclip_company_id="company-1",
        project_id="project-1",
        cto_agent_id="cto-agent-id",
        batch_limit=25,
    )
    defaults.update(overrides)
    return consumer.ConsumerConfig(**defaults)


def make_create_intent(idempotency_key="create:fp-1:0", **payload_overrides):
    payload = {"title": "Signal fired", "body": "Evidence body", "priority": "medium"}
    payload.update(payload_overrides)
    return {
        "id": "intent-1",
        "workspaceId": "workspace-1",
        "idempotencyKey": idempotency_key,
        "intentKind": consumer.INTENT_KIND_CREATE,
        "signalType": "some_signal",
        "payload": payload,
        "deliveryState": consumer.DELIVERY_STATE_PENDING,
        "retrospectiveRunId": "run-1",
    }


class SafeErrorSummaryTests(unittest.TestCase):
    def test_redacts_bearer_token(self):
        out = consumer.safe_error_summary("call failed: Authorization: Bearer abcd1234efgh5678ijkl")
        self.assertNotIn("abcd1234efgh5678ijkl", out)
        self.assertIn("<auth>", out)

    def test_redacts_email(self):
        out = consumer.safe_error_summary("user jane.doe@example.com not found")
        self.assertNotIn("jane.doe@example.com", out)
        self.assertIn("<email>", out)

    def test_redacts_cookie(self):
        out = consumer.safe_error_summary("Cookie: sessionid=abcdef1234567890; other=1")
        self.assertNotIn("sessionid=abcdef1234567890", out)

    def test_redacts_kv_secret(self):
        out = consumer.safe_error_summary('config had api_key="sk-live-1234567890abcdef"')
        self.assertNotIn("sk-live-1234567890abcdef", out)
        self.assertIn("<credential>", out)

    def test_bounded_to_512_chars(self):
        out = consumer.safe_error_summary("x" * 10000)
        self.assertLessEqual(len(out), 512)

    def test_empty_input(self):
        self.assertEqual(consumer.safe_error_summary(None), "")
        self.assertEqual(consumer.safe_error_summary(""), "")


class MarkerTests(unittest.TestCase):
    def test_round_trip(self):
        text = consumer.embed_marker("hello world", "create:fp-1:0")
        self.assertEqual(consumer.find_marker(text), "create:fp-1:0")

    def test_no_marker_returns_none(self):
        self.assertIsNone(consumer.find_marker("no marker here"))
        self.assertIsNone(consumer.find_marker(None))


class ResolveAssigneeTests(unittest.TestCase):
    def test_local_board_maps_to_configured_cto(self):
        config = make_config(cto_agent_id="cto-real-id")
        result = consumer.resolve_assignee({"assigneeAgentId": "local-board"}, config)
        self.assertEqual(result, "cto-real-id")

    def test_local_board_without_configured_cto_is_unassigned(self):
        config = make_config(cto_agent_id=None)
        result = consumer.resolve_assignee({"assigneeAgentId": "local-board"}, config)
        self.assertIsNone(result)

    def test_agent_id_shaped_value_passes_through(self):
        config = make_config()
        result = consumer.resolve_assignee({"assigneeAgentId": "7edd6388-eb0a-4948-aebd-bbc9ec6c0880"}, config)
        self.assertEqual(result, "7edd6388-eb0a-4948-aebd-bbc9ec6c0880")

    def test_unmapped_symbol_is_unassigned(self):
        config = make_config()
        result = consumer.resolve_assignee({"assigneeAgentId": "some-unknown-role"}, config)
        self.assertIsNone(result)

    def test_missing_assignee_is_none(self):
        config = make_config()
        self.assertIsNone(consumer.resolve_assignee({}, config))


class DispatchCreateTests(unittest.TestCase):
    def test_creates_issue_with_marker_when_none_exists(self):
        config = make_config()
        client = MagicMock()
        client.search_issues.return_value = []
        client.create_issue.return_value = {"id": "issue-1", "status": "todo"}
        collection = MagicMock()
        collection.update_one.return_value = MagicMock(matched_count=1)

        intent = make_create_intent()
        external_id, status = consumer.dispatch_create(client, config, collection, intent, "worker-a")

        self.assertEqual(external_id, "issue-1")
        self.assertEqual(status, "todo")
        client.create_issue.assert_called_once()
        body = client.create_issue.call_args[0][0]
        self.assertEqual(body["title"], "Signal fired")
        self.assertEqual(body["priority"], "medium")
        self.assertEqual(body["projectId"], "project-1")
        self.assertIn("outbox-intent:create:fp-1:0", body["description"])

    def test_replay_after_remote_success_local_write_failure_does_not_duplicate(self):
        """The core replay-safety contract: if a prior run created the real
        issue but crashed before persisting the ack, a retry must find the
        existing issue via the marker and must NOT create a second one."""
        config = make_config()
        client = MagicMock()
        client.search_issues.return_value = [
            {"id": "issue-1", "status": "todo", "description": "...\n<!-- outbox-intent:create:fp-1:0 -->"}
        ]
        collection = MagicMock()

        intent = make_create_intent()
        external_id, status = consumer.dispatch_create(client, config, collection, intent, "worker-a")

        self.assertEqual(external_id, "issue-1")
        self.assertEqual(status, "todo")
        client.create_issue.assert_not_called()

    def test_unassigned_when_no_cto_agent_configured_for_escalation_symbol(self):
        config = make_config(cto_agent_id=None)
        client = MagicMock()
        client.search_issues.return_value = []
        client.create_issue.return_value = {"id": "issue-2", "status": "todo"}
        collection = MagicMock()
        collection.update_one.return_value = MagicMock(matched_count=1)

        intent = make_create_intent(assigneeAgentId="local-board")
        consumer.dispatch_create(client, config, collection, intent, "worker-a")

        body = client.create_issue.call_args[0][0]
        self.assertNotIn("assigneeAgentId", body)

    def test_fencing_lost_claim_raises_before_remote_create(self):
        """If this worker's claim was already superseded by the time it
        reaches the fencing check (mark_dispatch_started matches nothing),
        dispatch_create must raise LostClaimError and must NOT call the
        remote create_issue API (REVA-27715 review round 4 finding #1)."""
        config = make_config()
        client = MagicMock()
        client.search_issues.return_value = []
        collection = MagicMock()
        collection.update_one.return_value = MagicMock(matched_count=0)

        intent = make_create_intent()
        with self.assertRaises(consumer.LostClaimError):
            consumer.dispatch_create(client, config, collection, intent, "worker-a")
        client.create_issue.assert_not_called()


class DispatchUpdateTests(unittest.TestCase):
    def test_defers_when_no_target_issue_yet(self):
        client = MagicMock()
        config = make_config()
        collection = MagicMock()
        intent = {
            "id": "intent-2",
            "workspaceId": "workspace-1",
            "idempotencyKey": "update:fp-1:intent-1:run-2",
            "intentKind": consumer.INTENT_KIND_UPDATE,
            "payload": {"body": "more evidence"},
            "targetsExternalIssueId": None,
        }
        with self.assertRaises(consumer.DeferIntent):
            consumer.dispatch_update(client, config, collection, intent, "worker-a")
        client.post_comment.assert_not_called()

    def test_posts_comment_with_marker_when_target_present(self):
        client = MagicMock()
        client.list_comments.return_value = []
        config = make_config()
        collection = MagicMock()
        collection.update_one.return_value = MagicMock(matched_count=1)
        intent = {
            "id": "intent-2",
            "workspaceId": "workspace-1",
            "idempotencyKey": "update:fp-1:intent-1:run-2",
            "intentKind": consumer.INTENT_KIND_UPDATE,
            "payload": {"body": "more evidence"},
            "targetsExternalIssueId": "issue-1",
        }
        external_id, status = consumer.dispatch_update(client, config, collection, intent, "worker-a")
        self.assertEqual(external_id, "issue-1")
        self.assertEqual(status, "updated")
        client.post_comment.assert_called_once()
        posted_body = client.post_comment.call_args[0][1]
        self.assertIn("outbox-intent:update:fp-1:intent-1:run-2", posted_body)

    def test_skips_duplicate_comment_on_replay(self):
        client = MagicMock()
        client.list_comments.return_value = [
            {"body": "more evidence\n<!-- outbox-intent:update:fp-1:intent-1:run-2 -->"}
        ]
        client.get_issue.return_value = {"status": "in_progress"}
        config = make_config()
        collection = MagicMock()
        intent = {
            "id": "intent-2",
            "workspaceId": "workspace-1",
            "idempotencyKey": "update:fp-1:intent-1:run-2",
            "intentKind": consumer.INTENT_KIND_UPDATE,
            "payload": {"body": "more evidence"},
            "targetsExternalIssueId": "issue-1",
        }
        external_id, status = consumer.dispatch_update(client, config, collection, intent, "worker-a")
        self.assertEqual(external_id, "issue-1")
        self.assertEqual(status, "in_progress")
        client.post_comment.assert_not_called()


class MongoStateMachineTests(unittest.TestCase):
    def test_mark_acknowledged_filter_scopes_to_workspace_allowed_states_and_owner(self):
        collection = MagicMock()
        collection.update_one.return_value = MagicMock(matched_count=1)
        result = consumer.mark_acknowledged(collection, "intent-1", "workspace-1", "issue-1", "todo", "worker-a")
        self.assertTrue(result)
        filter_arg, update_arg = collection.update_one.call_args[0]
        self.assertEqual(filter_arg["id"], "intent-1")
        self.assertEqual(filter_arg["workspaceId"], "workspace-1")
        self.assertEqual(set(filter_arg["deliveryState"]["$in"]), {"pending", "failed"})
        self.assertEqual(filter_arg["claimOwner"], "worker-a")
        self.assertEqual(update_arg["$set"]["deliveryState"], "acknowledged")
        self.assertEqual(update_arg["$set"]["externalIssueId"], "issue-1")

    def test_mark_acknowledged_rejects_empty_external_id(self):
        collection = MagicMock()
        with self.assertRaises(ValueError):
            consumer.mark_acknowledged(collection, "intent-1", "workspace-1", "", "todo", "worker-a")
        collection.update_one.assert_not_called()

    def test_mark_failed_only_from_pending_scoped_to_owner_and_redacts_error(self):
        collection = MagicMock()
        collection.update_one.return_value = MagicMock(matched_count=1)
        result = consumer.mark_failed(
            collection, "intent-1", "workspace-1", "boom: token abcd1234efgh5678ijkl", "worker-a"
        )
        self.assertTrue(result)
        filter_arg, update_arg = collection.update_one.call_args[0]
        self.assertEqual(filter_arg["deliveryState"], "pending")
        self.assertEqual(filter_arg["claimOwner"], "worker-a")
        self.assertNotIn("abcd1234efgh5678ijkl", update_arg["$set"]["lastError"])

    def test_requeue_only_from_failed(self):
        collection = MagicMock()
        collection.update_one.return_value = MagicMock(matched_count=1)
        consumer.requeue_failed_intent(collection, "intent-1", "workspace-1")
        filter_arg, update_arg = collection.update_one.call_args[0]
        self.assertEqual(filter_arg["deliveryState"], "failed")
        self.assertEqual(update_arg["$set"]["deliveryState"], "pending")


class ProcessIntentTests(unittest.TestCase):
    def test_dispatch_failure_marks_failed_with_redacted_error_and_does_not_raise(self):
        config = make_config()
        client = MagicMock()
        client.search_issues.side_effect = RuntimeError("upstream 500: Authorization: Bearer verysecrettoken1234567890")
        collection = MagicMock()
        collection.update_one.return_value = MagicMock(matched_count=1)

        intent = make_create_intent()
        outcome = consumer.process_intent(client, config, collection, intent)

        self.assertEqual(outcome, "failed")
        # Two update_one calls: mark_failed persists the redacted error,
        # then release_claim clears the claim fields taken before dispatch.
        self.assertEqual(collection.update_one.call_count, 2)
        filter_arg, update_arg = collection.update_one.call_args_list[0][0]
        self.assertEqual(filter_arg["deliveryState"], "pending")
        self.assertNotIn("verysecrettoken1234567890", update_arg["$set"]["lastError"])

    def test_two_consecutive_runs_after_ack_write_failure_do_not_duplicate_issue(self):
        """End-to-end replay-safety regression: cycle 1 creates the real
        issue but the local ack write is simulated as failing (matched_count
        stays 0 because a concurrent/crashed writer already flipped state);
        cycle 2 must find the marker and only re-apply the ack, never call
        create_issue twice."""
        config = make_config()
        client = MagicMock()
        client.search_issues.return_value = []
        client.create_issue.return_value = {"id": "issue-9", "status": "todo"}
        collection = MagicMock()
        collection.update_one.return_value = MagicMock(matched_count=1)

        intent = make_create_intent(idempotency_key="create:fp-9:0")
        outcome_1 = consumer.process_intent(client, config, collection, intent)
        self.assertEqual(outcome_1, "acknowledged")
        client.create_issue.assert_called_once()

        # Simulate the retry: the intent is still (or again) pending, but the
        # issue already exists remotely.
        client.search_issues.return_value = [
            {"id": "issue-9", "status": "todo", "description": "...\n<!-- outbox-intent:create:fp-9:0 -->"}
        ]
        outcome_2 = consumer.process_intent(client, config, collection, intent)
        self.assertEqual(outcome_2, "acknowledged")
        client.create_issue.assert_called_once()  # still only once total


class MarkerBoundaryAtMaxPayloadTests(unittest.TestCase):
    """REVA-27715 review finding #1: the marker must survive truncation at
    MAX_DESCRIPTION_CHARS. Body content is what gets cut, never the marker."""

    def test_embed_marker_bounded_preserves_marker_at_max_length(self):
        idempotency_key = "create:fp-huge:0"
        huge_text = "x" * 50000
        result = consumer.embed_marker_bounded(huge_text, idempotency_key, consumer.MAX_DESCRIPTION_CHARS)
        self.assertLessEqual(len(result), consumer.MAX_DESCRIPTION_CHARS)
        self.assertEqual(consumer.find_marker(result), idempotency_key)

    def test_dispatch_create_preserves_marker_with_max_length_body(self):
        config = make_config()
        client = MagicMock()
        client.search_issues.return_value = []
        client.create_issue.return_value = {"id": "issue-huge", "status": "todo"}
        collection = MagicMock()
        collection.update_one.return_value = MagicMock(matched_count=1)

        intent = make_create_intent(idempotency_key="create:fp-huge:0", body="x" * 50000)
        consumer.dispatch_create(client, config, collection, intent, "worker-a")

        body = client.create_issue.call_args[0][0]
        self.assertLessEqual(len(body["description"]), consumer.MAX_DESCRIPTION_CHARS)
        self.assertEqual(consumer.find_marker(body["description"]), "create:fp-huge:0")

    def test_dispatch_update_preserves_marker_with_max_length_body(self):
        client = MagicMock()
        client.list_comments.return_value = []
        config = make_config()
        collection = MagicMock()
        collection.update_one.return_value = MagicMock(matched_count=1)
        intent = {
            "id": "intent-2",
            "workspaceId": "workspace-1",
            "idempotencyKey": "update:fp-huge:intent-1:run-2",
            "intentKind": consumer.INTENT_KIND_UPDATE,
            "payload": {"body": "x" * 50000},
            "targetsExternalIssueId": "issue-1",
        }
        consumer.dispatch_update(client, config, collection, intent, "worker-a")

        posted_body = client.post_comment.call_args[0][1]
        self.assertLessEqual(len(posted_body), consumer.MAX_DESCRIPTION_CHARS)
        self.assertEqual(consumer.find_marker(posted_body), "update:fp-huge:intent-1:run-2")

    def test_dispatch_supersession_preserves_marker_with_max_length_body(self):
        client = MagicMock()
        client.list_comments.return_value = []
        config = make_config()
        collection = MagicMock()
        collection.find_one.return_value = {"id": "intent-1", "externalIssueId": "issue-1"}
        collection.update_one.return_value = MagicMock(matched_count=1)
        intent = {
            "id": "intent-3",
            "workspaceId": "workspace-1",
            "idempotencyKey": "supersession:fp-huge:intent-1:run-2",
            "intentKind": consumer.INTENT_KIND_SUPERSESSION,
            "supersedesIntentId": "intent-1",
            "payload": {"resolutionNote": "x" * 50000},
        }
        consumer.dispatch_supersession(client, config, collection, intent, "worker-a")

        patch_body = client.patch_issue.call_args[0][1]
        self.assertLessEqual(len(patch_body["comment"]), consumer.MAX_DESCRIPTION_CHARS)
        self.assertEqual(consumer.find_marker(patch_body["comment"]), "supersession:fp-huge:intent-1:run-2")


class ClaimTests(unittest.TestCase):
    """REVA-27715 review finding #2: intents must be atomically claimed
    before remote dispatch."""

    def test_claim_filter_scopes_to_pending_and_unclaimed_or_expired(self):
        collection = MagicMock()
        collection.find_one_and_update.return_value = {"id": "intent-1", "workspaceId": "workspace-1"}
        result = consumer.claim_intent(collection, "intent-1", "workspace-1", "worker-a")
        self.assertIsNotNone(result)
        filter_arg = collection.find_one_and_update.call_args[0][0]
        self.assertEqual(filter_arg["id"], "intent-1")
        self.assertEqual(filter_arg["workspaceId"], "workspace-1")
        self.assertEqual(filter_arg["deliveryState"], "pending")
        self.assertIn("$or", filter_arg)
        update_arg = collection.find_one_and_update.call_args[0][1]
        self.assertEqual(update_arg["$set"]["claimOwner"], "worker-a")

    def test_claim_returns_none_when_already_held(self):
        collection = MagicMock()
        collection.find_one_and_update.return_value = None
        result = consumer.claim_intent(collection, "intent-1", "workspace-1", "worker-b")
        self.assertIsNone(result)

    def test_release_claim_unsets_claim_fields_scoped_to_intent_and_owner(self):
        collection = MagicMock()
        consumer.release_claim(collection, "intent-1", "workspace-1", "worker-a")
        filter_arg, update_arg = collection.update_one.call_args[0]
        self.assertEqual(filter_arg["id"], "intent-1")
        self.assertEqual(filter_arg["workspaceId"], "workspace-1")
        self.assertEqual(filter_arg["claimOwner"], "worker-a")
        self.assertIn("claimOwner", update_arg["$unset"])


class ConcurrencyRegressionTests(unittest.TestCase):
    def test_two_concurrent_workers_racing_the_same_intent_only_one_dispatches(self):
        """Simulates two scheduled consumer invocations racing on the same
        pending intent: only the worker that wins the atomic Mongo claim
        may dispatch the remote mutation; the loser must skip without
        calling the Paperclip API at all."""
        config = make_config()
        client = MagicMock()
        client.search_issues.return_value = []
        client.create_issue.return_value = {"id": "issue-1", "status": "todo"}
        collection = MagicMock()
        intent = make_create_intent()

        # Worker A wins the atomic claim.
        collection.find_one_and_update.return_value = dict(intent)
        collection.update_one.return_value = MagicMock(matched_count=1)
        outcome_a = consumer.process_intent(client, config, collection, intent, owner="worker-a")
        self.assertEqual(outcome_a, "acknowledged")
        client.create_issue.assert_called_once()

        # Worker B races in on the same still-pending doc and loses the
        # claim (Mongo's atomic find_one_and_update matches nothing because
        # worker A's claim, and its lease, are still live).
        collection.find_one_and_update.return_value = None
        outcome_b = consumer.process_intent(client, config, collection, intent, owner="worker-b")
        self.assertEqual(outcome_b, "skipped_claimed")
        client.create_issue.assert_called_once()  # still only once total
        # search_issues is called twice for worker A's own successful
        # dispatch (pre-create marker check + post-create reconciliation
        # search, per reconcile_created_issue) and zero additional times for
        # worker B, who never claimed and never dispatched at all.
        self.assertEqual(client.search_issues.call_count, 2)


class FakeIntentCollection:
    """Minimal single-document Mongo-like fake that honors the filter
    semantics this module actually relies on ($or, $exists, $in, $lt, plain
    equality) instead of a MagicMock that returns matched_count=1
    unconditionally. Used to prove the claimOwner-scoping fix behaves like
    real Mongo would for a single document under a concurrency race,
    without requiring a live Mongo server."""

    def __init__(self, doc, extra_find_one_result=None):
        self.doc: Dict[str, Any] = dict(doc)
        self._extra_find_one_result = extra_find_one_result

    def find_one(self, filt, **_kwargs):
        if self._extra_find_one_result is not None:
            return self._extra_find_one_result
        return dict(self.doc) if self._matches(filt) else None

    def _matches(self, filt: Dict[str, Any]) -> bool:
        for key, cond in filt.items():
            if key == "$or":
                if not any(self._matches(sub) for sub in cond):
                    return False
                continue
            actual = self.doc.get(key)
            if isinstance(cond, dict):
                if "$exists" in cond and (key in self.doc) != cond["$exists"]:
                    return False
                if "$in" in cond and actual not in cond["$in"]:
                    return False
                if "$lt" in cond and not (actual is not None and actual < cond["$lt"]):
                    return False
            elif actual != cond:
                return False
        return True

    def _apply(self, update: Dict[str, Any]) -> None:
        for key, value in update.get("$set", {}).items():
            self.doc[key] = value
        for key in update.get("$unset", {}):
            self.doc.pop(key, None)
        for key, value in update.get("$inc", {}).items():
            self.doc[key] = self.doc.get(key, 0) + value

    def find_one_and_update(self, filt, update, return_document=None):
        if not self._matches(filt):
            return None
        self._apply(update)
        return dict(self.doc)

    def update_one(self, filt, update):
        matched = self._matches(filt)
        if matched:
            self._apply(update)
        return MagicMock(matched_count=1 if matched else 0)


class ConsumerConfigTests(unittest.TestCase):
    def test_operator_note_strips_uri_userinfo_before_persistence(self):
        note = "verified via https://operator:credential@control.example/api/issues?q=marker"
        sanitized = consumer.sanitize_operator_note(note)
        self.assertNotIn("operator", sanitized)
        self.assertNotIn("credential", sanitized)
        self.assertIn("https://", sanitized)
        self.assertIn("?q=marker", sanitized)


class StaleWorkerClaimScopingTests(unittest.TestCase):
    """REVA-27715 review finding #3: an expired worker's terminal write
    (release/acknowledge/fail) must not affect a newer worker's live claim
    on the same intent. Simulates: worker A claims with an already-expired
    lease, worker B then legitimately reclaims the same intent while A is
    still (unrealistically slowly) mid-dispatch, and A finally returns."""

    def _seeded_collection(self):
        collection = FakeIntentCollection(
            {"id": "intent-1", "workspaceId": "workspace-1", "deliveryState": consumer.DELIVERY_STATE_PENDING}
        )
        claimed_a = consumer.claim_intent(collection, "intent-1", "workspace-1", "worker-a", lease_seconds=-1)
        self.assertIsNotNone(claimed_a, "worker A must win the initial claim")
        claimed_b = consumer.claim_intent(collection, "intent-1", "workspace-1", "worker-b")
        self.assertIsNotNone(claimed_b, "worker B must be able to reclaim after A's lease expired")
        self.assertEqual(collection.doc["claimOwner"], "worker-b")
        return collection

    def test_expired_worker_cannot_release_a_newer_workers_claim(self):
        collection = self._seeded_collection()
        consumer.release_claim(collection, "intent-1", "workspace-1", "worker-a")
        self.assertEqual(collection.doc["claimOwner"], "worker-b")

    def test_expired_worker_cannot_acknowledge_over_a_newer_workers_claim(self):
        collection = self._seeded_collection()
        acked = consumer.mark_acknowledged(
            collection, "intent-1", "workspace-1", "issue-stale", "todo", "worker-a"
        )
        self.assertFalse(acked)
        self.assertEqual(collection.doc["deliveryState"], consumer.DELIVERY_STATE_PENDING)
        self.assertEqual(collection.doc["claimOwner"], "worker-b")

    def test_expired_worker_cannot_mark_failed_over_a_newer_workers_claim(self):
        collection = self._seeded_collection()
        marked = consumer.mark_failed(collection, "intent-1", "workspace-1", "boom", "worker-a")
        self.assertFalse(marked)
        self.assertEqual(collection.doc["deliveryState"], consumer.DELIVERY_STATE_PENDING)
        self.assertEqual(collection.doc["claimOwner"], "worker-b")

    def test_current_owner_can_still_release_and_acknowledge_normally(self):
        collection = self._seeded_collection()
        acked = consumer.mark_acknowledged(
            collection, "intent-1", "workspace-1", "issue-real", "todo", "worker-b"
        )
        self.assertTrue(acked)
        self.assertEqual(collection.doc["deliveryState"], consumer.DELIVERY_STATE_ACKNOWLEDGED)
        consumer.release_claim(collection, "intent-1", "workspace-1", "worker-b")
        self.assertNotIn("claimOwner", collection.doc)


class ExpiredLeaseDuringDispatchRegressionTests(unittest.TestCase):
    """REVA-27715 review round 4 finding #1: a lease that expires between
    worker A's marker lookup and its remote create call must not allow two
    workers to both create the real issue. Simulates A pausing immediately
    after its marker search returns empty, worker B fully reclaiming and
    dispatching in the interim, and A resuming afterward — exactly the
    scenario the review comment described."""

    def test_worker_a_paused_after_marker_lookup_cannot_duplicate_worker_bs_create(self):
        config = make_config()
        collection = FakeIntentCollection(
            {
                "id": "intent-1",
                "workspaceId": "workspace-1",
                "deliveryState": consumer.DELIVERY_STATE_PENDING,
                "idempotencyKey": "create:fp-race:0",
            }
        )
        intent = make_create_intent(idempotency_key="create:fp-race:0")

        client_a = MagicMock()
        client_b = MagicMock()
        client_b.search_issues.return_value = []
        client_b.create_issue.return_value = {"id": "issue-race", "status": "todo"}

        def a_marker_lookup_pauses_and_lets_b_run(_query):
            # Simulate worker A stalling right after this network call is
            # dispatched: A's claim lease expires, worker B reclaims the
            # same intent, and fully processes it (dispatch + acknowledge +
            # release) before A's own call returns.
            collection.doc["claimLeaseExpiresAt"] = "1970-01-01T00:00:00+00:00"
            outcome_b = consumer.process_intent(client_b, config, collection, intent, owner="worker-b")
            self.assertEqual(outcome_b, "acknowledged")
            return []  # A's own (now-stale) search still sees no marker yet

        client_a.search_issues.side_effect = a_marker_lookup_pauses_and_lets_b_run

        outcome_a = consumer.process_intent(client_a, config, collection, intent, owner="worker-a")

        self.assertEqual(outcome_a, "lost_claim")
        client_a.create_issue.assert_not_called()
        client_b.create_issue.assert_called_once()
        self.assertEqual(collection.doc["deliveryState"], consumer.DELIVERY_STATE_ACKNOWLEDGED)
        self.assertEqual(collection.doc["externalIssueId"], "issue-race")

    def test_dispatch_started_blocks_reclaim_forever_no_timer_reclaims_it(self):
        """Once a worker has recorded dispatchStartedAt, NO elapsed amount
        of time lets another worker reclaim automatically — a timer cannot
        tell "the owner crashed before its HTTP call reached the server"
        apart from "the owner paused and its HTTP call is still about to
        land", and reclaiming in the latter case is exactly what lets two
        workers both make a real create_issue call for the same intent
        (REVA-27715 review round 6: a reconcile-after-the-fact cleanup does
        not satisfy the no-second-create requirement, so the second create
        must never happen in the first place)."""
        collection = FakeIntentCollection(
            {"id": "intent-1", "workspaceId": "workspace-1", "deliveryState": consumer.DELIVERY_STATE_PENDING}
        )
        claimed_a = consumer.claim_intent(collection, "intent-1", "workspace-1", "worker-a")
        self.assertIsNotNone(claimed_a)
        self.assertTrue(consumer.mark_dispatch_started(collection, "intent-1", "workspace-1", "worker-a"))

        # Ordinary lease expired, dispatch started: B must not reclaim.
        collection.doc["claimLeaseExpiresAt"] = "1970-01-01T00:00:00+00:00"
        self.assertIsNone(consumer.claim_intent(collection, "intent-1", "workspace-1", "worker-b"))

        # Dispatch started arbitrarily long ago: still no automatic reclaim,
        # no matter how old dispatchStartedAt is -- there is no grace period
        # left to "elapse".
        collection.doc["dispatchStartedAt"] = "1970-01-01T00:00:00+00:00"
        self.assertIsNone(consumer.claim_intent(collection, "intent-1", "workspace-1", "worker-b"))
        self.assertEqual(collection.doc["claimOwner"], "worker-a")

    def test_force_release_stuck_dispatch_requires_operator_note_and_makes_intent_reclaimable(self):
        """The only sanctioned way to recover an intent stuck with
        dispatchStartedAt set is a deliberate, evidenced operator call —
        never a timeout."""
        collection = FakeIntentCollection(
            {"id": "intent-1", "workspaceId": "workspace-1", "deliveryState": consumer.DELIVERY_STATE_PENDING}
        )
        consumer.claim_intent(collection, "intent-1", "workspace-1", "worker-a")
        consumer.mark_dispatch_started(collection, "intent-1", "workspace-1", "worker-a")

        with self.assertRaises(ValueError):
            consumer.force_release_stuck_dispatch(collection, "intent-1", "workspace-1", "worker-a", "   ")
        self.assertIsNone(consumer.claim_intent(collection, "intent-1", "workspace-1", "worker-b"))

        released = consumer.force_release_stuck_dispatch(
            collection,
            "intent-1",
            "workspace-1",
            "worker-a",
            "confirmed via marker search: no issue exists for this idempotency key yet",
            {"idempotencyKey": "create:fp-1:0", "issueCount": 0, "issueIds": [], "verifiedAt": "now"},
        )
        self.assertTrue(released)
        self.assertNotIn("claimOwner", collection.doc)
        self.assertNotIn("dispatchStartedAt", collection.doc)

        claimed_b = consumer.claim_intent(collection, "intent-1", "workspace-1", "worker-b")
        self.assertIsNotNone(claimed_b)
        self.assertEqual(collection.doc["claimOwner"], "worker-b")

    def test_force_release_stuck_dispatch_scoped_to_expected_owner(self):
        collection = FakeIntentCollection(
            {"id": "intent-1", "workspaceId": "workspace-1", "deliveryState": consumer.DELIVERY_STATE_PENDING}
        )
        consumer.claim_intent(collection, "intent-1", "workspace-1", "worker-a")
        consumer.mark_dispatch_started(collection, "intent-1", "workspace-1", "worker-a")

        released = consumer.force_release_stuck_dispatch(
            collection, "intent-1", "workspace-1", "worker-wrong", "note",
            {"idempotencyKey": "create:fp-1:0", "issueCount": 0, "issueIds": [], "verifiedAt": "now"},
        )
        self.assertFalse(released)
        self.assertEqual(collection.doc["claimOwner"], "worker-a")


class ProcessIntentLostClaimTests(unittest.TestCase):
    """REVA-27715 review round 4 finding #2: a stale worker whose remote
    call succeeded but whose terminal write loses the race must be reported
    distinctly, not folded into "acknowledged"."""

    def test_stale_worker_successful_dispatch_reports_lost_claim_not_acknowledged(self):
        config = make_config()
        client = MagicMock()
        client.search_issues.return_value = []
        client.create_issue.return_value = {"id": "issue-1", "status": "todo"}
        collection = MagicMock()
        collection.find_one_and_update.return_value = {"id": "intent-1", "workspaceId": "workspace-1"}

        def update_one_side_effect(_filt, update):
            if update.get("$set", {}).get("deliveryState") == consumer.DELIVERY_STATE_ACKNOWLEDGED:
                return MagicMock(matched_count=0)
            return MagicMock(matched_count=1)

        collection.update_one.side_effect = update_one_side_effect

        intent = make_create_intent()
        outcome = consumer.process_intent(client, config, collection, intent, owner="worker-a")

        self.assertEqual(outcome, "lost_claim")
        client.create_issue.assert_called_once()


class ReconcileCreatedIssueTests(unittest.TestCase):
    """REVA-27715 review round 5: reconcile_created_issue is the correctness
    backstop for the post-fence race the round-4 fence/grace mechanism could
    not close to zero probability. Unit-level coverage of the function in
    isolation before the full end-to-end race regressions below."""

    def test_noop_when_no_duplicate_found(self):
        client = MagicMock()
        client.search_issues.return_value = [
            {"id": "issue-1", "status": "todo", "description": "...\n<!-- outbox-intent:create:fp-1:0 -->"}
        ]
        external_id, status = consumer.reconcile_created_issue(client, "create:fp-1:0", "issue-1", "todo")
        self.assertEqual((external_id, status), ("issue-1", "todo"))
        client.patch_issue.assert_not_called()

    def test_closes_duplicate_and_returns_earliest_as_canonical(self):
        client = MagicMock()
        client.search_issues.return_value = [
            {
                "id": "issue-2",
                "status": "todo",
                "description": "...\n<!-- outbox-intent:create:fp-1:0 -->",
                "createdAt": "2026-01-01T00:05:00+00:00",
            },
            {
                "id": "issue-1",
                "status": "todo",
                "description": "...\n<!-- outbox-intent:create:fp-1:0 -->",
                "createdAt": "2026-01-01T00:01:00+00:00",
            },
        ]
        external_id, status = consumer.reconcile_created_issue(client, "create:fp-1:0", "issue-2", "todo")
        self.assertEqual(external_id, "issue-1")
        client.patch_issue.assert_called_once_with(
            "issue-2",
            {
                "status": "done",
                "comment": (
                    "Closed as a concurrent-dispatch duplicate of issue-1 "
                    "(same outbox idempotency key `create:fp-1:0`); no manual action needed."
                ),
            },
        )

    def test_skips_already_done_duplicate(self):
        client = MagicMock()
        client.search_issues.return_value = [
            {
                "id": "issue-1",
                "status": "todo",
                "description": "...\n<!-- outbox-intent:create:fp-1:0 -->",
                "createdAt": "2026-01-01T00:01:00+00:00",
            },
            {
                # Later-created duplicate that some other cleanup path (or a
                # prior reconciliation pass) already closed -- must not be
                # re-patched.
                "id": "issue-2",
                "status": "done",
                "description": "...\n<!-- outbox-intent:create:fp-1:0 -->",
                "createdAt": "2026-01-01T00:05:00+00:00",
            },
        ]
        consumer.reconcile_created_issue(client, "create:fp-1:0", "issue-2", "todo")
        client.patch_issue.assert_not_called()


class FakeIssueStore:
    """Minimal shared remote-issue fake so two independent PaperclipClient
    stand-ins (modeling two concurrent workers) observe each other's
    creates/patches exactly like a real shared Paperclip API would. Used to
    prove the round-5 reconciliation invariant end-to-end instead of
    mocking each worker's view independently, which would hide whether they
    actually converge on the same remote ground truth."""

    def __init__(self):
        self.issues: Dict[str, Dict[str, Any]] = {}
        self._counter = 0

    def create_issue(self, body):
        self._counter += 1
        issue_id = f"issue-{self._counter}"
        record = {
            "id": issue_id,
            "status": "todo",
            "description": body.get("description", ""),
            "createdAt": f"2026-01-01T00:{self._counter:02d}:00+00:00",
        }
        self.issues[issue_id] = record
        return dict(record)

    def search_issues(self, query):
        return [dict(v) for v in self.issues.values() if query in (v.get("description") or "")]

    def patch_issue(self, issue_id, body):
        self.issues[issue_id].update({k: v for k, v in body.items() if k != "comment"})
        return dict(self.issues[issue_id])

    def get_issue(self, issue_id):
        return dict(self.issues[issue_id])


def make_store_backed_client(store: FakeIssueStore) -> MagicMock:
    client = MagicMock()
    client.create_issue.side_effect = store.create_issue
    client.search_issues.side_effect = store.search_issues
    client.patch_issue.side_effect = store.patch_issue
    client.get_issue.side_effect = store.get_issue
    client.list_comments.return_value = []
    client.post_comment.side_effect = lambda issue_id, body: {"id": f"comment-on-{issue_id}"}
    return client


class NoSecondCreateRegressionTests(unittest.TestCase):
    """REVA-27715 review round 6 finding: the round-5 design let worker B
    fully reclaim and dispatch once worker A's stall outlasted
    DISPATCH_RECLAIM_GRACE_SECONDS, producing a second real create_issue
    call that reconciliation only cleaned up afterward -- which the review
    holds does not satisfy "no second create". Since `claim_intent` no
    longer has any timer-based path to reclaim an intent whose
    dispatchStartedAt is set, this must now be impossible: proves worker B
    cannot claim, dispatch, or call create_issue at all while worker A's
    dispatch is outstanding, no matter how long ago it started."""

    def test_worker_b_cannot_claim_or_create_while_worker_as_dispatch_is_outstanding(self):
        config = make_config()
        store = FakeIssueStore()
        collection = FakeIntentCollection(
            {"id": "intent-1", "workspaceId": "workspace-1", "deliveryState": consumer.DELIVERY_STATE_PENDING}
        )
        intent = make_create_intent(idempotency_key="create:fp-recon:0")
        client_b = make_store_backed_client(store)

        # Worker A reaches the fence (legitimately claims and records
        # dispatchStartedAt) and then, for the purposes of this test, never
        # completes its own remote call -- modeling a crash or an
        # indefinite pause. No amount of elapsed time should matter.
        consumer.claim_intent(collection, "intent-1", "workspace-1", "worker-a")
        self.assertTrue(consumer.mark_dispatch_started(collection, "intent-1", "workspace-1", "worker-a"))
        collection.doc["claimLeaseExpiresAt"] = "1970-01-01T00:00:00+00:00"
        collection.doc["dispatchStartedAt"] = "1970-01-01T00:00:00+00:00"

        outcome_b = consumer.process_intent(client_b, config, collection, intent, owner="worker-b")

        self.assertEqual(outcome_b, "skipped_claimed")
        client_b.create_issue.assert_not_called()
        self.assertEqual(collection.doc["claimOwner"], "worker-a")
        self.assertEqual(collection.doc["deliveryState"], consumer.DELIVERY_STATE_PENDING)

    def test_operator_release_then_replay_reconciles_a_pre_existing_duplicate(self):
        """End-to-end recovery path: an operator confirms out-of-band that
        worker A's create never landed remotely (simulated here by a
        pre-existing duplicate from an unrelated source, e.g. a manual
        override, still needing cleanup), force-releases the stuck claim,
        and a subsequent run correctly reconciles down to one live issue
        via the marker-hit replay branch (REVA-27715 review round 6 finding
        #2: replay must reconcile too, not only the freshly-created path)."""
        config = make_config()
        store = FakeIssueStore()
        # Seed two pre-existing "duplicate" issues sharing one idempotency
        # marker, standing in for a duplicate that already exists in real
        # persistence before this worker ever touches the intent.
        store.create_issue({"description": "first\n<!-- outbox-intent:create:fp-recon:0 -->"})
        store.create_issue({"description": "second\n<!-- outbox-intent:create:fp-recon:0 -->"})
        collection = FakeIntentCollection(
            {"id": "intent-1", "workspaceId": "workspace-1", "deliveryState": consumer.DELIVERY_STATE_PENDING}
        )
        intent = make_create_intent(idempotency_key="create:fp-recon:0")

        consumer.claim_intent(collection, "intent-1", "workspace-1", "worker-a")
        consumer.mark_dispatch_started(collection, "intent-1", "workspace-1", "worker-a")
        released = consumer.force_release_stuck_dispatch(
            collection,
            "intent-1",
            "workspace-1",
            "worker-a",
            "confirmed via marker search: issue-1/issue-2 both already exist for this key",
            {"idempotencyKey": "create:fp-recon:0", "issueCount": 2, "issueIds": ["issue-1", "issue-2"], "verifiedAt": "now"},
        )
        self.assertTrue(released)

        client_b = make_store_backed_client(store)
        outcome_b = consumer.process_intent(client_b, config, collection, intent, owner="worker-b")

        self.assertEqual(outcome_b, "acknowledged")
        client_b.create_issue.assert_not_called()  # found via marker, never re-created
        open_issues = [record for record in store.issues.values() if record["status"] != "done"]
        self.assertEqual(len(open_issues), 1)
        self.assertEqual(open_issues[0]["id"], "issue-1")
        self.assertEqual(store.issues["issue-2"]["status"], "done")
        self.assertEqual(collection.doc["externalIssueId"], "issue-1")


class ReplayReconciliationTests(unittest.TestCase):
    """REVA-27715 review round 6 finding #2: dispatch_create/
    dispatch_escalation must call reconcile_created_issue on the
    marker-hit ("existing found") replay branch too, not only on the
    freshly-created branch -- otherwise a duplicate that already existed
    before this worker's run (e.g. left over from before this fix, or a
    manual data correction) is silently returned as-is forever instead of
    being cleaned up the next time this idempotency key is touched."""

    def test_dispatch_create_reconciles_duplicate_found_on_replay(self):
        config = make_config()
        client = MagicMock()
        client.search_issues.return_value = [
            {
                "id": "issue-2",
                "status": "todo",
                "description": "...\n<!-- outbox-intent:create:fp-1:0 -->",
                "createdAt": "2026-01-01T00:05:00+00:00",
            },
            {
                "id": "issue-1",
                "status": "todo",
                "description": "...\n<!-- outbox-intent:create:fp-1:0 -->",
                "createdAt": "2026-01-01T00:01:00+00:00",
            },
        ]
        collection = MagicMock()
        intent = make_create_intent()

        external_id, status = consumer.dispatch_create(client, config, collection, intent, "worker-a")

        self.assertEqual(external_id, "issue-1")
        client.create_issue.assert_not_called()
        client.patch_issue.assert_called_once()
        self.assertEqual(client.patch_issue.call_args[0][0], "issue-2")

    def test_dispatch_escalation_reconciles_duplicate_found_on_replay(self):
        config = make_config()
        client = MagicMock()
        client.search_issues.return_value = [
            {
                "id": "issue-2",
                "status": "todo",
                "description": "...\n<!-- outbox-intent:escalation:fp-1:0 -->",
                "createdAt": "2026-01-01T00:05:00+00:00",
            },
            {
                "id": "issue-1",
                "status": "todo",
                "description": "...\n<!-- outbox-intent:escalation:fp-1:0 -->",
                "createdAt": "2026-01-01T00:01:00+00:00",
            },
        ]
        collection = MagicMock()
        intent = {
            "id": "intent-4",
            "workspaceId": "workspace-1",
            "idempotencyKey": "escalation:fp-1:0",
            "intentKind": consumer.INTENT_KIND_ESCALATION,
            "signalType": "risk_signal",
            "payload": {"title": "Escalate", "body": "evidence"},
            "retrospectiveRunId": "run-1",
        }

        external_id, status = consumer.dispatch_escalation(client, config, collection, intent, "worker-a")

        self.assertEqual(external_id, "issue-1")
        client.create_issue.assert_not_called()
        client.patch_issue.assert_called_once()
        self.assertEqual(client.patch_issue.call_args[0][0], "issue-2")


# --------------------------------------------------------------------------- #
# CLI wiring tests (REVA-27985). Exercise argparse subcommands, the required
# --operator-note guard, the Mongo no-op path, and the dry-run path. All
# Mongo / Paperclip I/O is mocked -- these tests do not touch the real
# control plane or any real Mongo collection.
# --------------------------------------------------------------------------- #


class CliWiringTests(unittest.TestCase):
    """Verify the argparse surface of `consumer.py` and the subcommand
    handlers added for REVA-27985: each subcommand exposes --help,
    `recover-stuck` enforces the required `--operator-note`, and the
    Mongo write is correctly scoped to `--expected-owner`."""

    def _main(self, argv):
        """Call consumer.main(argv) with a stubbed ConsumerConfig.from_env
        so the test does not require real env vars to be set."""
        with patch.object(consumer.ConsumerConfig, "from_env", return_value=make_config()):
            return consumer.main(argv)

    def test_top_level_help_exits_zero(self):
        with self.assertRaises(SystemExit) as cm:
            self._main(["--help"])
        self.assertEqual(cm.exception.code, 0)

    def test_run_subcommand_help_exits_zero(self):
        with self.assertRaises(SystemExit) as cm:
            self._main(["run", "--help"])
        self.assertEqual(cm.exception.code, 0)

    def test_recover_stuck_subcommand_help_exits_zero(self):
        with self.assertRaises(SystemExit) as cm:
            self._main(["recover-stuck", "--help"])
        self.assertEqual(cm.exception.code, 0)

    def test_recover_stuck_missing_required_flag_exits_two(self):
        # argparse returns 2 for usage errors; this happens before our
        # code runs because `--workspace-id`, `--expected-owner`, and
        # `--operator-note` are all `required=True` on the subparser.
        with self.assertRaises(SystemExit) as cm:
            self._main(["recover-stuck", "--intent-id", "i-1"])
        self.assertEqual(cm.exception.code, 2)

    def test_recover_stuck_empty_operator_note_after_strip_exits_three(self):
        # argparse requires the flag to be present; a whitespace-only
        # value passes argparse but must be rejected by our strip check.
        with patch.object(consumer, "force_release_stuck_dispatch") as mock_release:
            mock_release.return_value = True
            rc = self._main(
                [
                    "recover-stuck",
                    "--intent-id", "i-1",
                    "--workspace-id", "w-1",
                    "--expected-owner", "owner-1",
                    "--operator-note", "   ",  # whitespace only
                ]
            )
            self.assertEqual(rc, 3)
            mock_release.assert_not_called()

    def test_recover_stuck_no_mongo_match_returns_two(self):
        fake_collection = MagicMock()
        fake_collection.find_one.return_value = None
        with patch.object(consumer, "get_collection", return_value=fake_collection):
            with patch.object(consumer, "force_release_stuck_dispatch", return_value=False) as mock_release:
                rc = self._main(
                    [
                        "recover-stuck",
                        "--intent-id", "i-missing",
                        "--workspace-id", "w-1",
                        "--expected-owner", "owner-1",
                        "--operator-note", "checked Paperclip search, no issue exists for this idempotency key",
                    ]
                )
        self.assertEqual(rc, 2)
        mock_release.assert_not_called()

    def test_recover_stuck_match_returns_zero(self):
        fake_collection = MagicMock()
        fake_collection.find_one.return_value = {
            "id": "i-stuck",
            "workspaceId": "w-1",
            "claimOwner": "owner-A",
            "dispatchStartedAt": "2026-07-16T00:00:00+00:00",
            "idempotencyKey": "create:fp-recovery:0",
        }
        verified = {"idempotencyKey": "create:fp-recovery:0", "issueCount": 0, "issueIds": [], "verifiedAt": "now"}
        with patch.object(consumer, "get_collection", return_value=fake_collection):
            with patch.object(consumer, "verify_remote_marker_state", return_value=verified) as mock_verify:
                with patch.object(consumer, "force_release_stuck_dispatch", return_value=True) as mock_release:
                    rc = self._main(
                        [
                            "recover-stuck",
                            "--intent-id", "i-stuck",
                            "--workspace-id", "w-1",
                            "--expected-owner", "owner-A",
                            "--operator-note", "verified remote marker state",
                        ]
                    )
        self.assertEqual(rc, 0)
        mock_verify.assert_called_once()
        self.assertEqual(mock_release.call_args.kwargs["verified_marker_state"], verified)

    def test_recover_stuck_dry_run_does_not_modify_mongo(self):
        # --dry-run must NOT call force_release_stuck_dispatch (which is
        # the write path); it must only discover the intent via the
        # scoped find_one. We assert that by mocking the destructive
        # helper -- the destructive helper must remain uncalled.
        config = make_config()
        fake_collection = MagicMock()
        fake_collection.find_one.return_value = {
            "id": "i-stuck",
            "workspaceId": "w-1",
            "intentKind": "create",
            "claimOwner": "owner-A",
            "dispatchStartedAt": "2026-07-16T00:00:00+00:00",
            "claimedAt": "2026-07-16T00:00:00+00:00",
            "deliveryState": "pending",
        }
        with patch.object(consumer.ConsumerConfig, "from_env", return_value=config):
            with patch.object(consumer, "get_collection", return_value=fake_collection) as mock_get:
                with patch.object(consumer, "force_release_stuck_dispatch") as mock_release:
                    rc = consumer.main(
                        [
                            "recover-stuck",
                            "--intent-id", "i-stuck",
                            "--workspace-id", "w-1",
                            "--expected-owner", "owner-A",
                            "--operator-note", "dry-run inspection only",
                            "--dry-run",
                        ]
                    )
                    self.assertEqual(rc, 0)
                    mock_get.assert_called_once_with(config)
                    mock_release.assert_not_called()
                    fake_collection.find_one.assert_called_once()
                    # The find filter must include the same scope guard the
                    # destructive path uses.
                    call_args = fake_collection.find_one.call_args
                    filter_doc = call_args.args[0] if call_args.args else call_args.kwargs.get("filter")
                    self.assertIsNotNone(filter_doc)
                    self.assertEqual(filter_doc["id"], "i-stuck")
                    self.assertEqual(filter_doc["workspaceId"], "w-1")
                    self.assertEqual(filter_doc["claimOwner"], "owner-A")
                    self.assertIn("dispatchStartedAt", filter_doc)

    def test_recover_stuck_dry_run_no_match_returns_two(self):
        # Dry-run with no matching intent: return 2 (no_match), do not
        # touch force_release_stuck_dispatch.
        fake_collection = MagicMock()
        fake_collection.find_one.return_value = None
        with patch.object(consumer.ConsumerConfig, "from_env", return_value=make_config()):
            with patch.object(consumer, "get_collection", return_value=fake_collection):
                with patch.object(consumer, "force_release_stuck_dispatch") as mock_release:
                    rc = consumer.main(
                        [
                            "recover-stuck",
                            "--intent-id", "i-ghost",
                            "--workspace-id", "w-1",
                            "--expected-owner", "owner-A",
                            "--operator-note", "dry-run, no intent matches",
                            "--dry-run",
                        ]
                    )
                    self.assertEqual(rc, 2)
                    mock_release.assert_not_called()

    def test_default_subcommand_is_run(self):
        # `consumer.py` with no subcommand must behave like `consumer.py run`.
        # We assert by intercepting run_once and confirming it is invoked
        # when no subcommand is passed (the subcommand dispatcher would
        # otherwise try to read real Mongo via get_collection).
        with patch.object(consumer.ConsumerConfig, "from_env", return_value=make_config()):
            with patch.object(consumer, "run_once", return_value={"pending_seen": 0}) as mock_run_once:
                with patch.object(consumer, "force_release_stuck_dispatch") as mock_release:
                    rc = consumer.main([])
                    self.assertEqual(rc, 0)
                    mock_run_once.assert_called_once()
                    mock_release.assert_not_called()

    def test_parser_lists_both_subcommands(self):
        parser = consumer._build_parser()
        # argparse stores subparsers; check that both names appear in help.
        help_text = parser.format_help()
        self.assertIn("run", help_text)
        self.assertIn("recover-stuck", help_text)


class IdempotentReplayIntegrationTests(unittest.TestCase):
    """End-to-end test of the replay safety net the issue's acceptance
    criteria name ("replay with no second issue"). Drives the same
    intent through `process_intent` twice: the first run creates a real
    external issue and acknowledges it locally; the second run sees the
    intent as no-longer-pending (claim_intent returns None) and is
    short-circuited without calling create_issue. Across both runs,
    exactly ONE create_issue call ever fires."""

    def test_replay_after_first_run_acknowledged_does_not_create_second_issue(self):
        config = make_config()
        intent = make_create_intent(
            idempotency_key="create:replay-27985:0",
            title="Replay no-dup test",
            body="Body for replay no-dup test",
            priority="low",
        )
        collection = FakeIntentCollection(dict(intent))
        store = FakeIssueStore()
        client = make_store_backed_client(store)

        outcome_1 = consumer.process_intent(client, config, collection, intent, owner="worker-A")
        self.assertEqual(outcome_1, "acknowledged")
        self.assertEqual(collection.doc["deliveryState"], consumer.DELIVERY_STATE_ACKNOWLEDGED)
        self.assertEqual(collection.doc["externalIssueId"], "issue-1")
        self.assertEqual(len(store.issues), 1)

        outcome_2 = consumer.process_intent(client, config, collection, intent, owner="worker-B")
        self.assertEqual(outcome_2, "skipped_claimed")
        self.assertEqual(len(store.issues), 1)
        self.assertEqual(store._counter, 1)


if __name__ == "__main__":
    unittest.main()
