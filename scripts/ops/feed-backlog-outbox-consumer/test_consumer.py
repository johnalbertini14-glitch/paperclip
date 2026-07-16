import unittest
from unittest.mock import MagicMock

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

        intent = make_create_intent()
        external_id, status = consumer.dispatch_create(client, config, intent)

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

        intent = make_create_intent()
        external_id, status = consumer.dispatch_create(client, config, intent)

        self.assertEqual(external_id, "issue-1")
        self.assertEqual(status, "todo")
        client.create_issue.assert_not_called()

    def test_unassigned_when_no_cto_agent_configured_for_escalation_symbol(self):
        config = make_config(cto_agent_id=None)
        client = MagicMock()
        client.search_issues.return_value = []
        client.create_issue.return_value = {"id": "issue-2", "status": "todo"}

        intent = make_create_intent(assigneeAgentId="local-board")
        consumer.dispatch_create(client, config, intent)

        body = client.create_issue.call_args[0][0]
        self.assertNotIn("assigneeAgentId", body)


class DispatchUpdateTests(unittest.TestCase):
    def test_defers_when_no_target_issue_yet(self):
        client = MagicMock()
        config = make_config()
        intent = {
            "id": "intent-2",
            "workspaceId": "workspace-1",
            "idempotencyKey": "update:fp-1:intent-1:run-2",
            "intentKind": consumer.INTENT_KIND_UPDATE,
            "payload": {"body": "more evidence"},
            "targetsExternalIssueId": None,
        }
        with self.assertRaises(consumer.DeferIntent):
            consumer.dispatch_update(client, config, intent)
        client.post_comment.assert_not_called()

    def test_posts_comment_with_marker_when_target_present(self):
        client = MagicMock()
        client.list_comments.return_value = []
        config = make_config()
        intent = {
            "id": "intent-2",
            "workspaceId": "workspace-1",
            "idempotencyKey": "update:fp-1:intent-1:run-2",
            "intentKind": consumer.INTENT_KIND_UPDATE,
            "payload": {"body": "more evidence"},
            "targetsExternalIssueId": "issue-1",
        }
        external_id, status = consumer.dispatch_update(client, config, intent)
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
        intent = {
            "id": "intent-2",
            "workspaceId": "workspace-1",
            "idempotencyKey": "update:fp-1:intent-1:run-2",
            "intentKind": consumer.INTENT_KIND_UPDATE,
            "payload": {"body": "more evidence"},
            "targetsExternalIssueId": "issue-1",
        }
        external_id, status = consumer.dispatch_update(client, config, intent)
        self.assertEqual(external_id, "issue-1")
        self.assertEqual(status, "in_progress")
        client.post_comment.assert_not_called()


class MongoStateMachineTests(unittest.TestCase):
    def test_mark_acknowledged_filter_scopes_to_workspace_and_allowed_states(self):
        collection = MagicMock()
        collection.update_one.return_value = MagicMock(matched_count=1)
        result = consumer.mark_acknowledged(collection, "intent-1", "workspace-1", "issue-1", "todo")
        self.assertTrue(result)
        filter_arg, update_arg = collection.update_one.call_args[0]
        self.assertEqual(filter_arg["id"], "intent-1")
        self.assertEqual(filter_arg["workspaceId"], "workspace-1")
        self.assertEqual(set(filter_arg["deliveryState"]["$in"]), {"pending", "failed"})
        self.assertEqual(update_arg["$set"]["deliveryState"], "acknowledged")
        self.assertEqual(update_arg["$set"]["externalIssueId"], "issue-1")

    def test_mark_acknowledged_rejects_empty_external_id(self):
        collection = MagicMock()
        with self.assertRaises(ValueError):
            consumer.mark_acknowledged(collection, "intent-1", "workspace-1", "", "todo")
        collection.update_one.assert_not_called()

    def test_mark_failed_only_from_pending_and_redacts_error(self):
        collection = MagicMock()
        collection.update_one.return_value = MagicMock(matched_count=1)
        result = consumer.mark_failed(collection, "intent-1", "workspace-1", "boom: token abcd1234efgh5678ijkl")
        self.assertTrue(result)
        filter_arg, update_arg = collection.update_one.call_args[0]
        self.assertEqual(filter_arg["deliveryState"], "pending")
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

        intent = make_create_intent(idempotency_key="create:fp-huge:0", body="x" * 50000)
        consumer.dispatch_create(client, config, intent)

        body = client.create_issue.call_args[0][0]
        self.assertLessEqual(len(body["description"]), consumer.MAX_DESCRIPTION_CHARS)
        self.assertEqual(consumer.find_marker(body["description"]), "create:fp-huge:0")

    def test_dispatch_update_preserves_marker_with_max_length_body(self):
        client = MagicMock()
        client.list_comments.return_value = []
        config = make_config()
        intent = {
            "id": "intent-2",
            "workspaceId": "workspace-1",
            "idempotencyKey": "update:fp-huge:intent-1:run-2",
            "intentKind": consumer.INTENT_KIND_UPDATE,
            "payload": {"body": "x" * 50000},
            "targetsExternalIssueId": "issue-1",
        }
        consumer.dispatch_update(client, config, intent)

        posted_body = client.post_comment.call_args[0][1]
        self.assertLessEqual(len(posted_body), consumer.MAX_DESCRIPTION_CHARS)
        self.assertEqual(consumer.find_marker(posted_body), "update:fp-huge:intent-1:run-2")

    def test_dispatch_supersession_preserves_marker_with_max_length_body(self):
        client = MagicMock()
        client.list_comments.return_value = []
        config = make_config()
        collection = MagicMock()
        collection.find_one.return_value = {"id": "intent-1", "externalIssueId": "issue-1"}
        intent = {
            "id": "intent-3",
            "workspaceId": "workspace-1",
            "idempotencyKey": "supersession:fp-huge:intent-1:run-2",
            "intentKind": consumer.INTENT_KIND_SUPERSESSION,
            "supersedesIntentId": "intent-1",
            "payload": {"resolutionNote": "x" * 50000},
        }
        consumer.dispatch_supersession(client, config, collection, intent)

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

    def test_release_claim_unsets_claim_fields_scoped_to_intent(self):
        collection = MagicMock()
        consumer.release_claim(collection, "intent-1", "workspace-1")
        filter_arg, update_arg = collection.update_one.call_args[0]
        self.assertEqual(filter_arg["id"], "intent-1")
        self.assertEqual(filter_arg["workspaceId"], "workspace-1")
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
        client.search_issues.assert_called_once()  # worker B never re-dispatched


if __name__ == "__main__":
    unittest.main()
