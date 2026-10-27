import { describe, expect, it } from "vitest";
import { isPreDispatchReviewWait } from "./pre-dispatch-review-wait.js";

const base = {
  runtimeMode: "legacy", status: "cancelled", errorCode: "issue_reassigned",
  resultJson: { stopReason: "issue_reassigned", timeoutSource: "stale_queued_run_gate" },
  startedAt: null, runtimeModeResolvedAt: null, processPid: null,
  processGroupId: null, processStartedAt: null, nativeIssueId: null,
  nativeSessionId: null, sessionIdAfter: null, controllerBootId: null,
  controllerLeaseExpiresAt: null, executionStage: null,
} as const;

describe("pre-dispatch ownership handoff on v1023", () => {
  it("accepts a matching pre-dispatch reassignment receipt", () => {
    expect(isPreDispatchReviewWait(base as any)).toBe(true);
    expect(isPreDispatchReviewWait({ ...base, errorCode: "issue_assignee_changed", resultJson: { ...base.resultJson, stopReason: "issue_assignee_changed" } } as any)).toBe(true);
  });
  it("rejects mismatched or conflicting provider evidence", () => {
    expect(isPreDispatchReviewWait({ ...base, resultJson: { ...base.resultJson, stopReason: "different" } } as any)).toBe(false);
    expect(isPreDispatchReviewWait({ ...base, processPid: 123 } as any)).toBe(false);
    expect(isPreDispatchReviewWait({ ...base, startedAt: new Date() } as any)).toBe(false);
  });
});
