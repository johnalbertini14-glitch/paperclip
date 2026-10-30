// @vitest-environment jsdom
import { act } from "react";
import { createRoot } from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { afterEach, describe, expect, it, vi } from "vitest";

const api = vi.hoisted(() => ({ attention: vi.fn(), issues: vi.fn(), issueCount: vi.fn(), issue: vi.fn(), agents: vi.fn(), activity: vi.fn(), projects: vi.fn(), directory: vi.fn(), liveRuns: vi.fn(), routines: vi.fn(), routineCount: vi.fn(), approvals: vi.fn(), approvalCount: vi.fn() }));
vi.mock("../context/CompanyContext", () => ({ useCompany: () => ({ selectedCompanyId: "company-1", companies: [{ id: "company-1" }] }) }));
vi.mock("../context/DialogContext", () => ({ useDialogActions: () => ({ openNewIssue: vi.fn(), openOnboarding: vi.fn() }) }));
vi.mock("../context/BreadcrumbContext", () => ({ useBreadcrumbs: () => ({ setBreadcrumbs: vi.fn() }) }));
vi.mock("../context/ToastContext", () => ({ useToastActions: () => ({ pushToast: vi.fn() }) }));
vi.mock("../api/dashboard", () => ({ dashboardApi: { summary: () => Promise.resolve({ agents: { running: 0 }, tasks: { blocked: 0 }, budgets: { activeIncidents: 0 } }) } }));
vi.mock("../api/agents", () => ({ agentsApi: { list: api.agents } }));
vi.mock("../api/issues", () => ({ issuesApi: { list: api.issues, count: api.issueCount, get: api.issue } }));
vi.mock("../api/attention", () => ({ attentionApi: { list: api.attention } }));
vi.mock("../api/approvals", () => ({ approvalsApi: { list: api.approvals, count: api.approvalCount } }));
vi.mock("../api/routines", () => ({ routinesApi: { list: api.routines, count: api.routineCount } }));
vi.mock("../api/heartbeats", () => ({ heartbeatsApi: { liveRunsForCompany: api.liveRuns } }));
vi.mock("../api/activity", () => ({ activityApi: { list: api.activity } }));
vi.mock("../api/projects", () => ({ projectsApi: { list: api.projects } }));
vi.mock("../api/access", () => ({ accessApi: { listUserDirectory: api.directory } }));
vi.mock("@/plugins/slots", () => ({ PluginSlotOutlet: () => null }));
vi.mock("../components/dashboard/BoardAttentionSheet", () => ({ BoardAttentionSheet: () => null }));
vi.mock("@/lib/router", () => ({ Link: ({ children, to, ...props }: { children: React.ReactNode; to: string }) => <a href={to} {...props}>{children}</a> }));

import { Dashboard } from "./Dashboard";

let root: ReturnType<typeof createRoot> | null = null;
let host: HTMLDivElement | null = null;
async function flush() {
  await act(async () => { await new Promise((resolve) => setTimeout(resolve, 0)); });
}
async function clickMore() {
  const button = [...(host?.querySelectorAll("button") ?? [])].find((element) => element.textContent?.includes("Load more attention"));
  expect(button, host?.textContent ?? "").toBeDefined();
  await act(async () => { button!.click(); });
  await flush();
}
async function mount(activity: unknown[] = [], liveRuns: unknown[] = []) {
  if (!api.agents.getMockImplementation()) api.agents.mockResolvedValue([]);
  if (!api.activity.getMockImplementation()) api.activity.mockResolvedValue(activity);
  api.liveRuns.mockResolvedValue(liveRuns);
  api.projects.mockResolvedValue([]);
  api.directory.mockResolvedValue({ users: [] });
  if (!api.routines.getMockImplementation()) api.routines.mockResolvedValue([]);
  if (!api.routineCount.getMockImplementation()) api.routineCount.mockResolvedValue({ count: 0 });
  if (!api.approvals.getMockImplementation()) api.approvals.mockResolvedValue([]);
  if (!api.approvalCount.getMockImplementation()) api.approvalCount.mockResolvedValue({ count: 0 });
  if (!api.issueCount.getMockImplementation()) api.issueCount.mockResolvedValue({ count: 0 });
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
  const client = new QueryClient({ defaultOptions: { queries: { retry: false, refetchOnWindowFocus: false } } });
  await act(async () => { root!.render(<QueryClientProvider client={client}><Dashboard /></QueryClientProvider>); });
  await flush();
  return client;
}
afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  host?.remove();
  host = null;
  root = null;
  api.issues.mockReset();
  api.issueCount.mockReset();
  api.issue.mockReset();
  api.agents.mockReset();
  api.attention.mockReset();
  api.activity.mockReset();
  api.projects.mockReset();
  api.directory.mockReset();
  api.liveRuns.mockReset();
  api.routines.mockReset();
  api.routineCount.mockReset();
  api.approvals.mockReset();
  api.approvalCount.mockReset();
});

describe("Board dashboard rendered attention continuation", () => {
  it("uses pre-page mixed-source counts instead of the loaded rows for All, Decisions, and Recovery", async () => {
    api.attention.mockResolvedValue({ items: [], nextCursor: null, dashboardCounts: { decision: 2, recovery: 1, blocked: 4 } });
    api.issues.mockResolvedValue([]);
    api.approvalCount.mockResolvedValue({ count: 2 });
    api.routineCount.mockResolvedValue({ count: 3 });
    await mount();
    const button = (name: string) => [...(host?.querySelectorAll<HTMLButtonElement>('[aria-label="Attention queue filters"] button') ?? [])]
      .find((item) => item.textContent?.includes(name))!;
    expect(button("All").querySelector("span")?.getAttribute("aria-label")).toBe("12 total");
    await act(async () => { button("Decisions").click(); });
    await flush();
    expect(button("Decisions").querySelector("span")?.getAttribute("aria-label")).toBe("4 total");
    await act(async () => { button("recovery").click(); });
    await flush();
    expect(button("recovery").querySelector("span")?.getAttribute("aria-label")).toBe("1 total");
    expect(host?.textContent).toContain("1 recovery item exists outside the loaded page.");
  });
  it("shows selected Blocked total from the pre-page issue predicate, not the loaded page", async () => {
    api.attention.mockResolvedValue({ items: [], nextCursor: null });
    api.issues.mockImplementation(async (_company: string, params: { dashboardKind?: string }) => params.dashboardKind === "blocked"
      ? Array.from({ length: 50 }, (_, index) => ({
        id: `blocked-${index}`, title: `Blocked row ${index}`, status: "blocked", priority: "high", updatedAt: new Date(),
        blockedInboxAttention: { reason: "blocked_chain_stalled", severity: "high", state: "needs_attention", owner: { type: "board", label: "Board" }, action: { label: "Unblock" } },
      })) : []);
    api.issueCount.mockResolvedValue({ count: 51 });
    await mount();
    const tab = [...(host?.querySelectorAll<HTMLButtonElement>('[aria-label="Attention queue filters"] button') ?? [])]
      .find((button) => button.textContent?.includes("blocked"));
    await act(async () => { tab!.click(); });
    await flush();
    expect(api.issueCount).toHaveBeenCalledWith("company-1", { attention: "blocked", dashboardKind: "blocked" }, expect.objectContaining({ signal: expect.any(AbortSignal) }));
    expect(tab?.getAttribute("aria-label")).toBeNull();
    expect(tab?.textContent).toContain("51");
    expect(tab?.querySelector("span")?.getAttribute("aria-label")).toBe("51 total");
    expect(api.issues.mock.calls.filter(([, params]) => params.dashboardKind === "blocked")).toHaveLength(1);
    expect(host?.textContent).toContain("Load more attention");
  });
  it("shows selected Recovery and Blocked no-match after enabled feeds settle", async () => {
    api.attention.mockResolvedValue({ items: [], nextCursor: null });
    api.issues.mockResolvedValue([]);
    await mount();
    for (const label of ["recovery", "blocked"]) {
      const tab = [...(host?.querySelectorAll<HTMLButtonElement>('[aria-label="Attention queue filters"] button') ?? [])]
        .find((button) => button.textContent?.includes(label));
      await act(async () => { tab!.click(); });
      await flush();
      expect(host?.textContent).toContain(`No ${label.toLowerCase()} items in the loaded queue.`);
      expect(host?.textContent).not.toContain("Loading Board attention…");
    }
  });
  it("does not inherit failed disabled sources as Recovery or Blocked errors", async () => {
    api.attention.mockResolvedValue({ items: [], nextCursor: null });
    api.issues.mockResolvedValue([]);
    api.approvals.mockRejectedValue(new Error("approval feed unavailable"));
    api.routines.mockRejectedValue(new Error("routine feed unavailable"));
    await mount();
    for (const label of ["recovery", "blocked"]) {
      const tab = [...(host?.querySelectorAll<HTMLButtonElement>('[aria-label="Attention queue filters"] button') ?? [])]
        .find((button) => button.textContent?.includes(label));
      await act(async () => { tab!.click(); });
      await flush();
      expect(host?.textContent).toContain(`No ${label} items in the loaded queue.`);
      expect(host?.textContent).not.toContain("Could not load the complete attention queue.");
    }
  });
  it("aborts a pending activity request on unmount", async () => {
    let activitySignal: AbortSignal | undefined;
    api.activity.mockImplementation((_company: string, _filters: unknown, options?: { signal?: AbortSignal }) => {
      activitySignal = options?.signal;
      return new Promise(() => {});
    });
    api.attention.mockResolvedValue({ items: [], nextCursor: null });
    api.issues.mockResolvedValue([]);
    await mount();
    expect(activitySignal).toBeDefined();
    await act(async () => { root!.unmount(); });
    root = null;
    expect(activitySignal?.aborted).toBe(true);
  });
  it("cancels hidden routine fetch on Decisions and reloads for Automation", async () => {
    let oldSignal: AbortSignal | undefined;
    api.routines.mockImplementation((_company: string, _filters: unknown, options?: { signal?: AbortSignal }) => {
      oldSignal = options?.signal;
      return new Promise(() => {});
    });
    api.attention.mockResolvedValue({ items: [], nextCursor: null });
    api.issues.mockResolvedValue([]);
    await mount();
    expect(api.routines).toHaveBeenCalledTimes(1);
    const buttons = () => [...(host?.querySelectorAll<HTMLButtonElement>('[aria-label="Attention queue filters"] button') ?? [])];
    await act(async () => { buttons().find((button) => button.textContent?.includes("Decisions"))!.click(); });
    await flush();
    expect(oldSignal?.aborted).toBe(true);
    expect(api.routines).toHaveBeenCalledTimes(1);
    await act(async () => { buttons().find((button) => button.textContent?.includes("Automation"))!.click(); });
    await flush();
    expect(api.routines).toHaveBeenCalledTimes(2);
  });
  it("requests recovery issues before pagination when the Recovery tab is selected", async () => {
    const recovery = {
      id: "older-recovery", companyId: "company-1", title: "Off-page recovery", status: "blocked", priority: "medium",
      updatedAt: new Date().toISOString(), activeRecoveryAction: { status: "active", nextAction: "Resolve" },
    };
    api.attention.mockResolvedValue({ items: [], nextCursor: null });
    api.issues.mockImplementation(async (_company: string, params: { dashboardKind?: string }) => params.dashboardKind === "recovery" ? [recovery] : []);
    await mount();
    const recoveryButton = [...(host?.querySelectorAll<HTMLButtonElement>('[aria-label="Attention queue filters"] button') ?? [])].find((button) => button.textContent?.includes("recovery"));
    expect(recoveryButton).toBeDefined();
    await act(async () => { recoveryButton!.click(); });
    await flush();
    expect(api.issues).toHaveBeenCalledWith("company-1", expect.objectContaining({ attention: "blocked", dashboardKind: "recovery", limit: 50, offset: 0 }), expect.objectContaining({ signal: expect.any(AbortSignal) }));
    expect(host?.textContent).toContain("Off-page recovery");
  });

  it("aborts the stale All blocked request when selecting Recovery", async () => {
    let allSignal: AbortSignal | undefined;
    api.attention.mockResolvedValue({ items: [], nextCursor: null });
    api.issues.mockImplementation((_company: string, params: { dashboardKind?: string }, options?: { signal?: AbortSignal }) => {
      if (!params.dashboardKind) {
        allSignal = options?.signal;
        return new Promise(() => {});
      }
      return Promise.resolve([]);
    });
    await mount();
    expect(allSignal).toBeDefined();
    const recoveryButton = [...(host?.querySelectorAll<HTMLButtonElement>('[aria-label="Attention queue filters"] button') ?? [])].find((button) => button.textContent?.includes("recovery"));
    await act(async () => { recoveryButton!.click(); });
    await flush();
    expect(allSignal?.aborted).toBe(true);
  });

  it("requests blocked issues before pagination when the Blocked tab is selected", async () => {
    const blocked = {
      id: "older-blocked", companyId: "company-1", title: "Off-page blocker", status: "blocked", priority: "medium",
      updatedAt: new Date().toISOString(), blockedInboxAttention: {
        state: "waiting", reason: "blocked_chain_stalled", owner: { type: "board" },
        action: { label: "Inspect" }, severity: "high",
      },
    };
    api.attention.mockResolvedValue({ items: [], nextCursor: null });
    api.issues.mockImplementation(async (_company: string, params: { dashboardKind?: string }) => params.dashboardKind === "blocked" ? [blocked] : []);
    await mount();
    const blockedButton = [...(host?.querySelectorAll<HTMLButtonElement>('[aria-label="Attention queue filters"] button') ?? [])].find((button) => button.textContent?.includes("blocked"));
    await act(async () => { blockedButton!.click(); });
    await flush();
    expect(api.issues).toHaveBeenCalledWith("company-1", expect.objectContaining({ attention: "blocked", dashboardKind: "blocked", limit: 50, offset: 0 }), expect.objectContaining({ signal: expect.any(AbortSignal) }));
    expect(host?.textContent).toContain("Off-page blocker");
  });

  it("requests decision issues before pagination when the Decisions tab is selected", async () => {
    const decision = {
      id: "older-decision", companyId: "company-1", title: "Off-page issue decision", status: "blocked", priority: "medium",
      updatedAt: new Date().toISOString(), blockedInboxAttention: {
        state: "awaiting_decision", reason: "pending_board_decision", owner: { type: "board" },
        action: { label: "Decide" }, severity: "medium",
      },
    };
    api.attention.mockResolvedValue({ items: [], nextCursor: null });
    api.issues.mockImplementation(async (_company: string, params: { dashboardKind?: string }) => params.dashboardKind === "decision" ? [decision] : []);
    await mount();
    const decisionButton = [...(host?.querySelectorAll<HTMLButtonElement>('[aria-label="Attention queue filters"] button') ?? [])].find((button) => button.textContent?.includes("Decisions"));
    await act(async () => { decisionButton!.click(); });
    await flush();
    expect(api.issues).toHaveBeenCalledWith("company-1", expect.objectContaining({ attention: "blocked", dashboardKind: "decision", limit: 50, offset: 0 }), expect.objectContaining({ signal: expect.any(AbortSignal) }));
    expect(host?.textContent).toContain("Off-page issue decision");
  });

  it("aborts the pending blocked issue page when selecting Automation", async () => {
    let blockedSignal: AbortSignal | undefined;
    api.issues.mockImplementation((_company: string, params: { attention?: string }, options?: { signal?: AbortSignal }) => {
      if (params.attention === "blocked") {
        blockedSignal = options?.signal;
        return new Promise(() => {});
      }
      return Promise.resolve([]);
    });
    api.attention.mockResolvedValue({ items: [], nextCursor: null });
    await mount();
    expect(api.issues).toHaveBeenCalledWith("company-1", expect.objectContaining({ attention: "blocked", limit: 50, offset: 0 }), expect.objectContaining({ signal: expect.any(AbortSignal) }));
    expect(blockedSignal).toBeDefined();
    const automation = [...(host?.querySelectorAll<HTMLButtonElement>('[aria-label="Attention queue filters"] button') ?? [])].find((button) => button.textContent?.includes("Automation"));
    await act(async () => { automation!.click(); });
    await flush();
    expect(blockedSignal?.aborted).toBe(true);
  });
  it("aborts the stale All native request when selecting Decisions", async () => {
    let oldSignal: AbortSignal | undefined;
    api.attention.mockImplementation((_company: string, params: { sourceKinds?: string[] }, options?: { signal?: AbortSignal }) => {
      if (params.sourceKinds?.includes("recovery_action")) {
        oldSignal = options?.signal;
        return new Promise(() => {});
      }
      return Promise.resolve({ items: [], nextCursor: null });
    });
    api.issues.mockResolvedValue([]);
    await mount();
    expect(oldSignal).toBeDefined();
    const decisions = [...(host?.querySelectorAll<HTMLButtonElement>('[aria-label="Attention queue filters"] button') ?? [])].find((button) => button.textContent?.includes("Decisions"));
    await act(async () => { decisions!.click(); });
    await flush();
    expect(oldSignal?.aborted).toBe(true);
    expect(api.attention).toHaveBeenCalledWith("company-1", expect.objectContaining({ sourceKinds: expect.arrayContaining(["review", "decision"]) }), expect.objectContaining({ signal: expect.any(AbortSignal) }));
  });
  it("aborts the pending native feed when selecting Blocked", async () => {
    let nativeSignal: AbortSignal | undefined;
    api.attention.mockImplementation((_company: string, _params: unknown, options?: { signal?: AbortSignal }) => {
      nativeSignal = options?.signal;
      return new Promise(() => {});
    });
    api.issues.mockResolvedValue([]);
    await mount();
    expect(nativeSignal).toBeDefined();
    const blocked = [...(host?.querySelectorAll<HTMLButtonElement>('[aria-label="Attention queue filters"] button') ?? [])].find((button) => button.textContent?.includes("blocked"));
    await act(async () => { blocked!.click(); });
    await flush();
    expect(nativeSignal?.aborted).toBe(true);
    expect(api.attention).toHaveBeenCalledTimes(1);
  });
  it("filters the All feed to rendered native kinds before paging and preserves an off-page decision", async () => {
    const decision = { id: "all-later", sourceKind: "review", severity: "high", createdAt: new Date().toISOString(), activityAt: new Date().toISOString(), whyNow: "Review pending", subject: { kind: "decision", id: "all-later", title: "All off-page decision", href: "/decisions" } };
    api.attention.mockImplementation(async (_company: string, params: { sourceKinds?: string[]; cursor?: string }) => ({
      items: params.cursor === "all-next" ? [decision] : [],
      nextCursor: params.cursor ? null : "all-next",
    }));
    api.issues.mockResolvedValue([]);
    await mount();
    const initial = api.attention.mock.calls[0]?.[1] as { sourceKinds?: string[]; cursor?: string };
    expect(initial.sourceKinds).toEqual(["issue_thread_interaction", "decision", "review", "join_request", "agent_error_alert", "budget_alert", "recovery_action", "failed_run"]);
    expect(initial.sourceKinds).not.toContain("blocker_attention");
    await clickMore();
    expect(api.attention).toHaveBeenCalledWith("company-1", expect.objectContaining({ cursor: "all-next", sourceKinds: initial.sourceKinds }), expect.objectContaining({ signal: expect.any(AbortSignal) }));
    expect(host?.textContent).toContain("All off-page decision");
  });
  it("restarts the native cursor with selected decision kinds and continues that filtered feed", async () => {
    const decision = { id: "later-decision", sourceKind: "review", severity: "high", createdAt: new Date().toISOString(), activityAt: new Date().toISOString(), whyNow: "Review pending", subject: { kind: "decision", id: "later-decision", title: "Later filtered decision", href: "/decisions" } };
    api.attention.mockImplementation(async (_company: string, params: { sourceKinds?: string[]; cursor?: string }) => ({
      items: params.cursor === "decision-next" ? [decision] : [],
      nextCursor: params.sourceKinds && !params.cursor ? "decision-next" : null,
    }));
    api.issues.mockResolvedValue([]);
    await mount();
    const decisions = [...(host?.querySelectorAll<HTMLButtonElement>('[aria-label="Attention queue filters"] button') ?? [])].find((button) => button.textContent?.includes("Decisions"));
    await act(async () => { decisions!.click(); });
    await flush();
    expect(api.attention).toHaveBeenCalledWith("company-1", expect.objectContaining({ limit: 50, sourceKinds: expect.arrayContaining(["review", "decision"]) }), expect.objectContaining({ signal: expect.any(AbortSignal) }));
    await clickMore();
    expect(api.attention).toHaveBeenCalledWith("company-1", expect.objectContaining({ cursor: "decision-next", sourceKinds: expect.arrayContaining(["review"]) }), expect.objectContaining({ signal: expect.any(AbortSignal) }));
    expect(host?.textContent).toContain("Later filtered decision");
  });
  it("does not claim an empty filtered queue before a native continuation is exhausted", async () => {
    const decision = { id: "late-decision", sourceKind: "decision", severity: "high", createdAt: new Date().toISOString(), activityAt: new Date().toISOString(), whyNow: "Decision pending", subject: { kind: "decision", id: "late-decision", title: "Off-page native decision", href: "/decisions" } };
    api.attention.mockImplementation(async (_company: string, params: { cursor?: string }) => ({
      items: params.cursor ? [decision] : [], nextCursor: params.cursor ? null : "next-page-token",
    }));
    api.issues.mockResolvedValue([]);
    await mount();
    const decisions = [...(host?.querySelectorAll<HTMLButtonElement>('[aria-label="Attention queue filters"] button') ?? [])].find((button) => button.textContent?.includes("Decisions"));
    expect(decisions).toBeDefined();
    await act(async () => { decisions!.click(); });
    await flush();
    expect(host?.textContent).toContain("More decisions may be on the next page.");
    expect(host?.textContent).not.toContain("No decision items in the loaded queue.");
    expect(host?.textContent).toContain("No Board attention items in the loaded queue.");
    await clickMore();
    expect(host?.textContent).toContain("Off-page native decision");
    expect(host?.textContent).toContain("1 loaded item needs Board attention.");
  });
  it("does not enrich the general issue sample while retaining blocked-attention enrichment", async () => {
    api.attention.mockResolvedValue({ items: [], nextCursor: null });
    api.issues.mockResolvedValue([]);
    await mount();
    expect(api.issues).toHaveBeenCalledWith("company-1", expect.objectContaining({ attention: "blocked", includeBlockedBy: true, includeBlockedInboxAttention: true, limit: 50, offset: 0 }), expect.objectContaining({ signal: expect.any(AbortSignal) }));
    expect(api.issues.mock.calls.some(([, params]) => params?.status === "backlog,todo,in_progress,in_review,blocked")).toBe(false);
  });
  it("resolves visible off-page issue activity by ID without a general 50-row page", async () => {
    api.attention.mockResolvedValue({ items: [], nextCursor: null });
    api.issues.mockResolvedValue([]);
    api.issue.mockResolvedValue({ id: "issue-activity", identifier: "PC-99", title: "Off-page activity issue" });
    await mount([{ id: "event-activity", action: "issue.updated", entityType: "issue", entityId: "issue-activity", actorType: "system", actorId: "system", createdAt: new Date().toISOString(), details: {} }]);
    expect(api.issues.mock.calls.some(([, params]) => params?.status === "backlog,todo,in_progress,in_review,blocked")).toBe(false);
    expect(api.issue).toHaveBeenCalledWith("issue-activity", expect.objectContaining({ signal: expect.any(AbortSignal) }));
    await flush();
    expect(host?.textContent).toContain("Off-page activity issue");
  });
  it("loads issue context only for visible issue activity", async () => {
    api.attention.mockResolvedValue({ items: [], nextCursor: null });
    api.issues.mockResolvedValue([]);
    api.issue.mockImplementation(async (id: string) => ({ id, title: `Title for ${id}` }));
    const client = await mount();
    expect(api.issue).not.toHaveBeenCalled();
    api.activity.mockResolvedValue([{ id: "event-2", action: "issue.updated", entityType: "issue", entityId: "issue-1", actorType: "system", actorId: "system", createdAt: new Date().toISOString(), details: {} }]);
    await act(async () => { await client.invalidateQueries({ queryKey: ["activity"] }); });
    await flush();
    expect(api.issue).toHaveBeenCalledWith("issue-1", expect.objectContaining({ signal: expect.any(AbortSignal) }));
    expect(api.issues.mock.calls.some(([, params]) => params?.status === "backlog,todo,in_progress,in_review,blocked")).toBe(false);
  });
  it("does not request general issues for project-only activity without live runs", async () => {
    api.attention.mockResolvedValue({ items: [], nextCursor: null });
    api.issues.mockResolvedValue([]);
    await mount([{ id: "event-project", action: "project.updated", entityType: "project", entityId: "project-1", actorType: "system", actorId: "system", createdAt: new Date().toISOString(), details: {} }]);
    expect(api.issues.mock.calls.some(([, params]) => params?.attention === "blocked")).toBe(true);
    expect(api.issues.mock.calls.some(([, params]) => params?.status === "backlog,todo,in_progress,in_review,blocked")).toBe(false);
    expect(api.projects).toHaveBeenCalledWith("company-1");
  });
  it("resolves a visible live run's off-page issue by ID without a broad issue page", async () => {
    api.attention.mockResolvedValue({ items: [], nextCursor: null });
    api.issues.mockResolvedValue([]);
    api.issue.mockResolvedValue({ id: "issue-1", title: "Off-page running issue" });
    api.agents.mockResolvedValue([{ id: "agent-1", name: "Worker A", status: "running" }]);
    await mount([], [{ id: "run-1", agentId: "agent-1", issueId: "issue-1", status: "running" }]);
    // The visible agent is supplied by the agent roster, not the issue page.
    expect(api.issues.mock.calls.some(([, params]) => params?.status === "backlog,todo,in_progress,in_review,blocked")).toBe(false);
    expect(api.issue).toHaveBeenCalledWith("issue-1", expect.objectContaining({ signal: expect.any(AbortSignal) }));
    await flush();
    expect(host?.textContent).toContain("Off-page running issue");
  });
  it("bounds live-run issue lookups to the four agents visible in the pulse", async () => {
    api.attention.mockResolvedValue({ items: [], nextCursor: null });
    api.issues.mockResolvedValue([]);
    api.issue.mockImplementation(async (id: string) => ({ id, title: id }));
    api.agents.mockResolvedValue(Array.from({ length: 6 }, (_, index) => ({ id: `agent-${index}`, name: `Worker ${index}`, status: "running" })));
    await mount([], Array.from({ length: 6 }, (_, index) => ({ id: `run-${index}`, agentId: `agent-${index}`, issueId: `issue-${index}`, status: "running" })));
    expect(api.issue).toHaveBeenCalledTimes(4);
    expect(api.issue.mock.calls.map(([id]) => id)).toEqual(["issue-0", "issue-1", "issue-2", "issue-3"]);
    expect(api.issues.mock.calls.some(([, params]) => params?.status === "backlog,todo,in_progress,in_review,blocked")).toBe(false);
  });
  it("aborts the bounded issue-ID request when the dashboard unmounts", async () => {
    let issueSignal: AbortSignal | undefined;
    api.attention.mockResolvedValue({ items: [], nextCursor: null });
    api.issues.mockResolvedValue([]);
    api.agents.mockResolvedValue([{ id: "agent-1", name: "Worker A", status: "running" }]);
    api.issue.mockImplementation((_id: string, options?: { signal?: AbortSignal }) => {
      issueSignal = options?.signal;
      return new Promise(() => {});
    });
    await mount([], [{ id: "run-1", agentId: "agent-1", issueId: "issue-1", status: "running" }]);
    expect(issueSignal).toBeDefined();
    await act(async () => { root!.unmount(); });
    root = null;
    expect(issueSignal?.aborted).toBe(true);
  });
  it("bounds activity context to four displayed events and deduplicates a pulse issue", async () => {
    api.attention.mockResolvedValue({ items: [], nextCursor: null });
    api.issues.mockResolvedValue([]);
    api.issue.mockImplementation(async (id: string) => ({ id, title: id }));
    api.agents.mockResolvedValue([{ id: "agent-1", name: "Worker A", status: "running" }]);
    const activity = Array.from({ length: 6 }, (_, index) => ({ id: `event-${index}`, action: "issue.updated", entityType: "issue", entityId: `issue-${index}`, actorType: "system", actorId: "system", createdAt: new Date().toISOString(), details: {} }));
    await mount(activity, [{ id: "run-1", agentId: "agent-1", issueId: "issue-0", status: "running" }]);
    expect(api.issue.mock.calls.map(([id]) => id)).toEqual(["issue-0", "issue-1", "issue-2", "issue-3"]);
    expect(api.issues.mock.calls.some(([, params]) => params?.status === "backlog,todo,in_progress,in_review,blocked")).toBe(false);
  });
  it("aborts an in-flight activity issue context request on unmount", async () => {
    let issueSignal: AbortSignal | undefined;
    api.attention.mockResolvedValue({ items: [], nextCursor: null });
    api.issues.mockResolvedValue([]);
    api.issue.mockImplementation((_id: string, options?: { signal?: AbortSignal }) => {
      issueSignal = options?.signal;
      return new Promise(() => {});
    });
    await mount([{ id: "event-issue", action: "issue.updated", entityType: "issue", entityId: "issue-1", actorType: "system", actorId: "system", createdAt: new Date().toISOString(), details: {} }]);
    expect(issueSignal).toBeDefined();
    await act(async () => { root!.unmount(); });
    root = null;
    expect(issueSignal?.aborted).toBe(true);
  });
  it("does not fetch project or user enrichment for an empty activity feed", async () => {
    api.attention.mockResolvedValue({ items: [], nextCursor: null });
    api.issues.mockResolvedValue([]);
    await mount();
    expect(api.activity).toHaveBeenCalledTimes(1);
    expect(api.projects).not.toHaveBeenCalled();
    expect(api.directory).not.toHaveBeenCalled();
  });
  it("fetches project and user enrichment when activity has a row", async () => {
    api.attention.mockResolvedValue({ items: [], nextCursor: null });
    api.issues.mockResolvedValue([]);
    await mount([{ id: "event-1", action: "project.updated", entityType: "project", entityId: "project-1", actorType: "system", actorId: "system", createdAt: new Date().toISOString(), details: {} }]);
    expect(api.projects).toHaveBeenCalledWith("company-1");
    expect(api.directory).toHaveBeenCalledWith("company-1");
  });
  it("shows a real empty state when the selected Automation feed is disabled", async () => {
    api.attention.mockResolvedValue({ items: [], nextCursor: null });
    api.issues.mockResolvedValue([]);
    await mount();
    const automation = [...(host?.querySelectorAll<HTMLButtonElement>('[aria-label="Attention queue filters"] button') ?? [])].find((button) => button.textContent?.includes("Automation"));
    await act(async () => { automation!.click(); });
    await flush();
    expect(host?.textContent).toContain("No routine items in the loaded queue.");
    expect(host?.textContent).not.toContain("Loading Board attention…");
  });

  it("requests only the first routine page for Automation", async () => {
    api.attention.mockResolvedValue({ items: [], nextCursor: null });
    api.issues.mockResolvedValue([]);
    await mount();
    expect(api.routines).toHaveBeenCalledWith("company-1", { limit: 50, offset: 0 }, expect.objectContaining({ signal: expect.any(AbortSignal) }));
  });

  it("requests only the first pending approval page for Decisions", async () => {
    api.attention.mockResolvedValue({ items: [], nextCursor: null });
    api.issues.mockResolvedValue([]);
    await mount();
    expect(api.approvals).toHaveBeenCalledWith("company-1", "pending", { limit: 50, offset: 0 }, expect.objectContaining({ signal: expect.any(AbortSignal) }));
  });

  it("shows exact off-page pending approvals without double-counting native Decisions", async () => {
    api.attention.mockResolvedValue({ items: [], nextCursor: null });
    api.issues.mockResolvedValue([]);
    api.approvalCount.mockResolvedValue({ count: 51 });
    api.approvals.mockResolvedValue([]);
    await mount();
    await flush();
    expect(api.approvalCount).toHaveBeenCalledWith("company-1", "pending", expect.objectContaining({ signal: expect.any(AbortSignal) }));
    expect(host?.textContent).toContain("51 pending approvals total");
    const decisions = [...(host?.querySelectorAll<HTMLButtonElement>('[aria-label="Attention queue filters"] button') ?? [])].find((button) => button.textContent?.includes("Decisions"))!;
    expect(decisions.querySelector('[aria-label="0 loaded"]')).not.toBeNull();
    expect(api.approvals.mock.calls.some(([, , page]) => page?.offset === 50)).toBe(false);
  });

  it("continues pending approvals beyond the first 50", async () => {
    api.attention.mockResolvedValue({ items: [], nextCursor: null });
    api.issues.mockResolvedValue([]);
    const approval = (index: number) => ({ id: `approval-${index}`, companyId: "company-1", type: "request_board_approval", status: "pending", payload: { title: `Approval ${index}` }, createdAt: new Date().toISOString() });
    api.approvals.mockImplementation(async (_company: string, _status: string, page: { offset: number }) => page.offset === 0
      ? Array.from({ length: 50 }, (_, index) => approval(index))
      : [approval(50)]);
    await mount();
    const decisions = [...(host?.querySelectorAll<HTMLButtonElement>('[aria-label="Attention queue filters"] button') ?? [])].find((button) => button.textContent?.includes("Decisions"));
    await act(async () => { decisions!.click(); });
    await flush();
    for (let attempts = 0; attempts < 10 && !api.approvals.mock.calls.some(([, , page]) => page?.offset === 50); attempts++) {
      await clickMore();
    }
    expect(api.approvals).toHaveBeenCalledWith("company-1", "pending", { limit: 50, offset: 50 }, expect.objectContaining({ signal: expect.any(AbortSignal) }));
    for (let attempts = 0; attempts < 10 && !host?.textContent?.includes("Approval 50"); attempts++) await clickMore();
    expect(host?.textContent).toContain("Approval 50");
  });

  it("requests the pre-page failed-routine facet on Automation and shows an off-page match", async () => {
    api.attention.mockResolvedValue({ items: [], nextCursor: null });
    api.issues.mockResolvedValue([]);
    const failed = { id: "routine-50", title: "Routine 50", status: "active", updatedAt: new Date().toISOString(), lastRun: { status: "failed" } };
    api.routines.mockImplementation(async (_company: string, filters: { failedLatest?: boolean }) => filters.failedLatest ? [failed] : []);
    await mount();
    const automation = [...(host?.querySelectorAll<HTMLButtonElement>('[aria-label="Attention queue filters"] button') ?? [])].find((button) => button.textContent?.includes("Automation"));
    await act(async () => { automation!.click(); });
    await flush();
    expect(api.routines).toHaveBeenCalledWith("company-1", { limit: 50, offset: 0, failedLatest: true }, expect.objectContaining({ signal: expect.any(AbortSignal) }));
    expect(host?.textContent).toContain("Routine 50");
  });

  it("shows exact off-page Automation count without fetching another routine page", async () => {
    api.attention.mockResolvedValue({ items: [], nextCursor: null });
    api.issues.mockResolvedValue([]);
    api.routineCount.mockResolvedValue({ count: 1 });
    api.routines.mockResolvedValue([]);
    await mount();
    const automation = [...(host?.querySelectorAll<HTMLButtonElement>('[aria-label="Attention queue filters"] button') ?? [])].find((button) => button.textContent?.includes("Automation"))!;
    await act(async () => { automation.click(); });
    await flush();
    expect(api.routineCount).toHaveBeenCalledWith("company-1", { failedLatest: true }, expect.objectContaining({ signal: expect.any(AbortSignal) }));
    expect(automation.querySelector('[aria-label="1 total"]')).not.toBeNull();
    expect(api.routines.mock.calls.some(([, page]) => page?.offset === 50)).toBe(false);
    expect(host?.textContent).not.toContain("No routine items in the loaded queue.");
  });

  it("does not offer unrelated native continuation on Routines", async () => {
    api.attention.mockResolvedValue({ items: [], nextCursor: "more-native-decisions" });
    api.issues.mockResolvedValue([]);
    await mount();
    const routines = [...(host?.querySelectorAll("button") ?? [])].find((button) => button.textContent?.includes("Automation"));
    expect(routines).toBeDefined();
    await act(async () => { routines!.click(); });
    await flush();
    expect([...host!.querySelectorAll("button")].some((button) => button.textContent?.includes("Load more attention"))).toBe(false);
    expect(api.attention).toHaveBeenCalledTimes(1);
  });

  it("does not refetch blocked issue pages while Automation is selected", async () => {
    api.attention.mockResolvedValue({ items: [], nextCursor: null });
    api.issues.mockResolvedValue([]);
    const client = await mount();
    const routines = [...(host?.querySelectorAll<HTMLButtonElement>('[aria-label="Attention queue filters"] button') ?? [])].find((button) => button.textContent?.includes("Automation"));
    expect(routines).toBeDefined();
    await act(async () => { routines!.click(); });
    await flush();
    api.issues.mockClear();
    await act(async () => { await client.invalidateQueries({ queryKey: ["issues"] }); });
    await flush();
    expect(api.issues.mock.calls.some(([, params]) => params.attention === "blocked")).toBe(false);
  });

  it("uses only blocked issue pages on Blocked even when native decisions have another cursor", async () => {
    api.attention.mockResolvedValue({ items: [], nextCursor: "unrelated-native-decisions" });
    const blocked = (index: number) => ({
      id: `blocked-${index}`, title: `Blocked row ${index}`, identifier: `PC-${index}`,
      status: "blocked", priority: "high", updatedAt: new Date(), assigneeAgentId: null,
      blockedInboxAttention: { reason: "blocked_chain_stalled", severity: "high", state: "needs_attention", owner: { type: "board", label: "Board" }, action: { label: "Unblock" } },
    });
    api.issues.mockImplementation(async (_company: string, params: { attention?: string; offset?: number }) =>
      params.attention === "blocked"
        ? (params.offset === 50 ? [blocked(50)] : Array.from({ length: 50 }, (_, index) => blocked(index)))
        : []);
    await mount();
    const blockedTab = [...(host?.querySelectorAll<HTMLButtonElement>('[aria-label="Attention queue filters"] button') ?? [])].find((button) => /blocked/i.test(button.textContent ?? ""));
    expect(blockedTab).toBeDefined();
    await act(async () => { blockedTab!.click(); });
    await flush();
    for (let attempts = 0; attempts < 10 && !api.issues.mock.calls.some(([, params]) => params.attention === "blocked" && params.offset === 50); attempts++) {
      await clickMore();
    }
    expect(api.issues).toHaveBeenCalledWith("company-1", expect.objectContaining({ attention: "blocked", offset: 50 }), expect.objectContaining({ signal: expect.any(AbortSignal) }));
    expect(api.attention).toHaveBeenCalledTimes(1);
    expect(host?.textContent).toContain("Blocked row 50");
  });

  it("continues the blocked issue source for an off-page Board decision", async () => {
    api.attention.mockResolvedValue({ items: [], nextCursor: null });
    const blocked = (index: number) => ({
      id: `blocked-${index}`, title: `Blocked row ${index}`, identifier: `PC-${index}`,
      status: "blocked", priority: "high", updatedAt: new Date(), assigneeAgentId: null,
      blockedInboxAttention: { reason: "blocked_chain_stalled", severity: "high", state: "needs_attention", owner: { type: "board", label: "Board" }, action: { label: "Unblock" } },
    });
    api.issues.mockImplementation(async (_company: string, params: { attention?: string; offset?: number }) =>
      params.attention === "blocked"
        ? (params.offset === 50 ? [{ ...blocked(50), title: "Off-page decision", blockedInboxAttention: { ...blocked(50).blockedInboxAttention, state: "awaiting_decision" } }] : Array.from({ length: 50 }, (_, index) => blocked(index)))
        : []);
    await mount();
    const decisions = [...(host?.querySelectorAll("button") ?? [])].find((button) => button.textContent?.includes("Decisions"));
    expect(decisions).toBeDefined();
    await act(async () => { decisions!.click(); });
    await flush();
    await clickMore();
    expect(api.issues).toHaveBeenCalledWith("company-1", expect.objectContaining({ attention: "blocked", limit: 50, offset: 50 }), expect.objectContaining({ signal: expect.any(AbortSignal) }));
    expect(host?.textContent).toContain("Off-page decision");
  });

  it("clicks the native cursor before continuing the independent blocked-issue source", async () => {
    const native = (id: string) => ({ id, sourceKind: "decision", severity: "high", createdAt: new Date().toISOString(), activityAt: new Date().toISOString(), whyNow: "Decision pending", subject: { kind: "decision", id, title: id, href: "/decisions" } });
    api.attention.mockImplementation(async (_company: string, params: { cursor?: string }) => ({
      items: [native(params.cursor ? "Second cursor decision" : "First cursor decision")],
      nextCursor: params.cursor ? null : "next-page-token",
    }));
    const blocked = (index: number) => ({
      id: `blocked-${index}`, title: `Blocked row ${index}`, identifier: `PC-${index}`,
      status: "blocked", priority: "high", updatedAt: new Date(), assigneeAgentId: null,
      blockedInboxAttention: { reason: "blocked_chain_stalled", severity: "high", state: "needs_attention", owner: { type: "board", label: "Board" }, action: { label: "Unblock" } },
    });
    api.issues.mockImplementation(async (_company: string, params: { attention?: string; offset?: number }) =>
      params.attention === "blocked" ? (params.offset === 50 ? [blocked(50)] : Array.from({ length: 50 }, (_, index) => blocked(index))) : []);
    await mount();
    expect(api.attention).toHaveBeenCalledWith("company-1", expect.objectContaining({ limit: 50, sourceKinds: expect.arrayContaining(["decision", "recovery_action"]) }), expect.objectContaining({ signal: expect.any(AbortSignal) }));
    expect(api.issues).toHaveBeenCalledWith("company-1", expect.objectContaining({ attention: "blocked", limit: 50, offset: 0 }), expect.objectContaining({ signal: expect.any(AbortSignal) }));
    // Reveal loaded rows without new requests; the native cursor must advance before blocked offset 50.
    let attempts = 0;
    while (!api.attention.mock.calls.some(([, params]) => params.cursor === "next-page-token") && attempts++ < 10) await clickMore();
    expect(api.attention).toHaveBeenCalledWith("company-1", expect.objectContaining({ limit: 50, cursor: "next-page-token", sourceKinds: expect.arrayContaining(["decision", "recovery_action"]) }), expect.objectContaining({ signal: expect.any(AbortSignal) }));
    expect(api.issues.mock.calls.some(([, params]) => params.attention === "blocked" && params.offset === 50)).toBe(false);
    // Native feed is now exhausted, so the same control continues blocked issues at offset 50.
    while (!api.issues.mock.calls.some(([, params]) => params.attention === "blocked" && params.offset === 50) && attempts++ < 15) await clickMore();
    expect(api.issues).toHaveBeenCalledWith("company-1", expect.objectContaining({ attention: "blocked", limit: 50, offset: 50 }), expect.objectContaining({ signal: expect.any(AbortSignal) }));
    expect(host?.textContent).toContain("Blocked row 50");
  });
});
