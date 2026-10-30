import type { Agent } from "@paperclipai/shared";
import { describe, expect, it } from "vitest";
import { dashboardAttentionPage, dashboardBlockedPage, dashboardNextAttentionPage, derivePausedAgentBanner } from "./Dashboard";

function agent(overrides: Partial<Agent>): Agent {
  return {
    id: "agent-1",
    name: "Agent",
    status: "idle",
    pauseReason: null,
    ...overrides,
  } as unknown as Agent;
}

describe("derivePausedAgentBanner", () => {
  it("returns null with no agents loaded or an empty company", () => {
    expect(derivePausedAgentBanner(undefined)).toBeNull();
    expect(derivePausedAgentBanner([])).toBeNull();
  });

  it("prefers the imported banner and lists only import-paused agents", () => {
    const banner = derivePausedAgentBanner([
      agent({ id: "a", status: "paused", pauseReason: "import" }),
      agent({ id: "b", status: "paused", pauseReason: "manual" }),
      agent({ id: "c", status: "idle" }),
    ]);
    expect(banner).toEqual({ kind: "imported", pausedImportedAgentIds: ["a"] });
  });

  it("falls back to the all-paused banner when no import pauses exist", () => {
    const banner = derivePausedAgentBanner([
      agent({ id: "a", status: "paused", pauseReason: "manual" }),
      agent({ id: "b", status: "paused", pauseReason: "system" }),
    ]);
    expect(banner).toEqual({ kind: "all-paused" });
  });

  it("shows nothing while at least one agent can run and none are import-paused", () => {
    expect(derivePausedAgentBanner([
      agent({ id: "a", status: "paused", pauseReason: "manual" }),
      agent({ id: "b", status: "idle" }),
    ])).toBeNull();
  });
});

describe("Board dashboard attention cursor", () => {
  it("starts at 50 rows and sends only the server-issued continuation cursor on later pages", () => {
    const renderedKinds = ["issue_thread_interaction", "decision", "review", "join_request", "agent_error_alert", "budget_alert", "recovery_action", "failed_run"];
    expect(dashboardAttentionPage(null)).toEqual({ limit: 50, sourceKinds: renderedKinds });
    expect(dashboardAttentionPage("opaque-next-page")).toEqual({ limit: 50, cursor: "opaque-next-page", sourceKinds: renderedKinds });
    expect(dashboardAttentionPage(null, "decision")).toEqual({ limit: 50, sourceKinds: ["issue_thread_interaction", "decision", "review", "join_request", "agent_error_alert", "budget_alert"] });
    expect(dashboardAttentionPage("next", "recovery")).toEqual({ limit: 50, cursor: "next", sourceKinds: ["recovery_action", "failed_run"] });
  });
  it("continues Blocked directly from its independent 50-row issue source, not the native decision cursor", () => {
    expect(dashboardBlockedPage(0)).toMatchObject({ attention: "blocked", limit: 50, offset: 0 });
    expect(dashboardBlockedPage(50)).toMatchObject({ attention: "blocked", limit: 50, offset: 50 });
    expect(dashboardNextAttentionPage(10, 5, true, true, "blocked")).toBe("reveal");
    expect(dashboardNextAttentionPage(0, 5, true, true, "blocked")).toBe("blocked");
    expect(dashboardNextAttentionPage(0, 5, true, false, "blocked")).toBeNull();
    expect(dashboardNextAttentionPage(0, 5, true, true, "decision")).toBe("attention");
    expect(dashboardNextAttentionPage(0, 5, true, true, "routine")).toBeNull();
    expect(dashboardNextAttentionPage(6, 5, true, true, "routine")).toBe("reveal");
    expect(dashboardNextAttentionPage(0, 5, false, true, "blocked")).toBe("blocked");
    expect(dashboardNextAttentionPage(0, 5, false, true, "decision")).toBe("blocked");
    expect(dashboardNextAttentionPage(0, 5, false, true, "routine")).toBeNull();
    expect(dashboardNextAttentionPage(0, 5, false, false, "blocked")).toBeNull();
  });
});
