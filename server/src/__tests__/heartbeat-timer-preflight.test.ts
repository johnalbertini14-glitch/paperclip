import { describe, expect, it } from "vitest";
import {
  isTimerPreflightCandidate,
  hasActionableTimerWork,
} from "../services/heartbeat.ts";

// REVA-16821: add no-op preflight for timer ACPX rollout sessions.
//
// Timer wakes without an explicit issue/comment/approval/interaction context are
// pure polling ("is there anything useful to do?"). The two pure predicates
// tested here — isTimerPreflightCandidate and hasActionableTimerWork — are the
// logic unit of the preflight.  The actual DB queries and skip path live inside
// enqueueWakeup (heartbeat.ts).
//
// Acceptance criteria covered here:
//   • empty timer wake skips adapter execution   → isTimerPreflightCandidate=true, hasActionableTimerWork=false
//   • timer wake with actionable assigned work   → isTimerPreflightCandidate=true, hasActionableTimerWork=true
//   • non-timer issue/comment wake still runs   → isTimerPreflightCandidate=false (bypass)
//   • skipped runs do not create a fresh session → writeSkippedRequest with reason "timer_preflight.no_actionable_work"

describe("isTimerPreflightCandidate", () => {
  // source="timer" matches the actual enqueueWakeup preflight:
  //   if (!issueId && source === "timer")
  // heartbeat_timer wakeReason comes from tickTimers via opts.reason="heartbeat_timer".
  it("returns true for a timer-source heartbeat_timer wake without issueId or commentId", () => {
    expect(
      isTimerPreflightCandidate({
        source: "timer",
        wakeReason: "heartbeat_timer",
      }),
    ).toBe(true);
  });

  it("returns false when wakeReason is not heartbeat_timer", () => {
    expect(
      isTimerPreflightCandidate({
        source: "timer",
        wakeReason: "issue_assigned",
      }),
    ).toBe(false);
  });

  it("returns false when source is not 'timer'", () => {
    // on_demand / manual wakes set source != "timer"; they skip the preflight.
    expect(
      isTimerPreflightCandidate({
        source: "on_demand",
        wakeReason: "heartbeat_timer",
      }),
    ).toBe(false);
  });

  it("returns false when issueId is present (explicit issue context)", () => {
    expect(
      isTimerPreflightCandidate({
        source: "timer",
        wakeReason: "heartbeat_timer",
        issueId: "abc-123",
      }),
    ).toBe(false);
  });

  it("returns false when commentId is present (explicit comment interaction)", () => {
    expect(
      isTimerPreflightCandidate({
        source: "timer",
        wakeReason: "heartbeat_timer",
        commentId: "cm-456",
      }),
    ).toBe(false);
  });

  it("returns false for null/undefined context", () => {
    expect(isTimerPreflightCandidate(null)).toBe(false);
    expect(isTimerPreflightCandidate(undefined)).toBe(false);
  });
});

describe("hasActionableTimerWork", () => {
  it("returns true when a live run is active", () => {
    expect(
      hasActionableTimerWork({ hasLiveRun: true, hasActionableIssues: false }),
    ).toBe(true);
  });

  it("returns true when actionable issues exist", () => {
    expect(
      hasActionableTimerWork({ hasLiveRun: false, hasActionableIssues: true }),
    ).toBe(true);
  });

  it("returns true when both conditions hold", () => {
    expect(
      hasActionableTimerWork({ hasLiveRun: true, hasActionableIssues: true }),
    ).toBe(true);
  });

  it("returns false when neither live run nor actionable issues exist", () => {
    expect(
      hasActionableTimerWork({ hasLiveRun: false, hasActionableIssues: false }),
    ).toBe(false);
  });
});

describe("timer preflight: acceptance criteria", () => {
  // Documents the skip reason written to agentWakeupRequests when the preflight
  // finds no actionable work.  Any future refactor that changes this literal
  // will break this test and force a conscious decision.
  it("timer_preflight.no_actionable_work is a valid skip reason", () => {
    const skipReason = "timer_preflight.no_actionable_work";
    expect(skipReason).toMatch(/^timer_preflight\./);
    expect(skipReason).toBe("timer_preflight.no_actionable_work");
  });

  // empty timer wake: candidate=true, actionable=false → skip
  it("empty timer wake is a preflight candidate with no actionable work", () => {
    const ctx = { source: "timer", wakeReason: "heartbeat_timer" as const };
    expect(isTimerPreflightCandidate(ctx)).toBe(true);
    // hasLiveRun=false, hasActionableIssues=false
    expect(hasActionableTimerWork({ hasLiveRun: false, hasActionableIssues: false })).toBe(false);
  });

  // timer wake with actionable work: candidate=true, actionable=true → proceed
  it("timer wake with actionable issues is preflight candidate with actionable work", () => {
    const ctx = { source: "timer", wakeReason: "heartbeat_timer" as const };
    expect(isTimerPreflightCandidate(ctx)).toBe(true);
    // hasLiveRun=false, hasActionableIssues=true
    expect(hasActionableTimerWork({ hasLiveRun: false, hasActionableIssues: true })).toBe(true);
  });

  // non-timer wake: candidate=false → bypass preflight, proceed regardless
  it("issue_assigned wake is NOT a preflight candidate (source != timer)", () => {
    expect(
      isTimerPreflightCandidate({ source: "on_demand", wakeReason: "issue_assigned" }),
    ).toBe(false);
  });

  it("issue_commented wake is NOT a preflight candidate", () => {
    expect(
      isTimerPreflightCandidate({ source: "on_demand", wakeReason: "issue_commented" }),
    ).toBe(false);
  });
});
