// @vitest-environment jsdom
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { queryKeys } from "../lib/queryKeys";
import { useInboxBadge } from "./useInboxBadge";

const mocks = vi.hoisted(() => ({ list: vi.fn(), dismissals: vi.fn() }));
vi.mock("../api/approvals", () => ({ approvalsApi: { list: mocks.list } }));
vi.mock("../api/issues", () => ({ issuesApi: { count: async () => ({ count: 0 }), list: async () => [] } }));
vi.mock("../api/access", () => ({ accessApi: { listJoinRequests: async () => [] } }));
vi.mock("../api/auth", () => ({ authApi: { getSession: async () => null } }));
vi.mock("../api/dashboard", () => ({ dashboardApi: { summary: async () => null } }));
vi.mock("../api/heartbeats", () => ({ heartbeatsApi: { list: async () => [] } }));
vi.mock("../api/inboxDismissals", () => ({ inboxDismissalsApi: { list: mocks.dismissals } }));
vi.mock("./useSharedPolling", () => ({ useSharedPollingQuery: () => ({}), usePublishSharedQueryData: () => {} }));

(globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
let captured: ReturnType<typeof useInboxBadge>;
function Harness({ companyId }: { companyId: string | null }) { captured = useInboxBadge(companyId); return null; }

const approval = (id: string, status: string) => ({ id, status, updatedAt: "2026-10-01T00:00:00.000Z", createdAt: "2026-10-01T00:00:00.000Z" });
const pending = Array.from({ length: 61 }, (_, index) => approval(`p${index}`, "pending"));
const revision = [approval("r0", "revision_requested"), approval("r1", "revision_requested")];

describe("Inbox badge approvals stay bounded on every page", () => {
  let client: QueryClient, root: Root, container: HTMLDivElement;
  async function settle(expected: number) {
    for (let attempt = 0; attempt < 100 && captured?.approvals !== expected; attempt += 1) {
      await act(async () => { await new Promise((resolve) => setTimeout(resolve, 10)); });
    }
    expect(captured.approvals).toBe(expected);
  }
  beforeEach(() => {
    mocks.list.mockReset().mockImplementation(async (_company: string, status?: string, page?: { limit?: number; offset?: number }) => {
      const rows = status === "pending" ? pending : status === "revision_requested" ? revision : [...pending, ...revision, approval("old", "approved")];
      if (page?.limit === undefined) return rows;
      return rows.slice(page.offset ?? 0, (page.offset ?? 0) + page.limit);
    });
    mocks.dismissals.mockReset().mockResolvedValue([]);
    localStorage.clear();
    client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    container = document.createElement("div"); document.body.appendChild(container); root = createRoot(container);
  });
  afterEach(async () => { await act(async () => root.unmount()); client.clear(); container.remove(); });

  it("requests only actionable approvals in limit-50 pages and still counts every page", async () => {
    await act(async () => { root.render(<QueryClientProvider client={client}><Harness companyId="company-a" /></QueryClientProvider>); });
    await settle(63);
    expect(mocks.list.mock.calls.length).toBeGreaterThan(0);
    for (const [, status, page] of mocks.list.mock.calls) {
      expect(["pending", "revision_requested"]).toContain(status);
      expect(page?.limit).toBe(50);
    }
    expect(mocks.list.mock.calls.map(([, status, page]) => `${status}:${page?.offset}`)).toEqual([
      "pending:0", "pending:50", "revision_requested:0",
    ]);
  });

  it("does not seed the unbounded Inbox approvals cache and refreshes on approval-list invalidation", async () => {
    await act(async () => { root.render(<QueryClientProvider client={client}><Harness companyId="company-a" /></QueryClientProvider>); });
    await settle(63);
    expect(client.getQueryData(queryKeys.approvals.list("company-a"))).toBeUndefined();
    pending.splice(60);
    await act(async () => { await client.invalidateQueries({ queryKey: queryKeys.approvals.list("company-a") }); });
    await settle(62);
    pending.push(approval("p60", "pending"));
  });
});
