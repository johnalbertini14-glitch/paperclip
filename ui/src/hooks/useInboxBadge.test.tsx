// @vitest-environment jsdom
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { queryKeys } from "../lib/queryKeys";
import type { Issue } from "@paperclipai/shared";
import { beginLocalInboxArchive, clearLocalInboxArchive, removeIssueFromInboxCaches, restoreIssueToInboxCaches, snapshotInboxIssueCaches } from "../lib/inboxArchiveCache";
import { useInboxBadge } from "./useInboxBadge";

const mocks = vi.hoisted(() => ({ count: vi.fn(), list: vi.fn() }));
vi.mock("../api/issues", () => ({ issuesApi: mocks }));
vi.mock("../api/access", () => ({ accessApi: { listJoinRequests: async () => [] } }));
vi.mock("../api/approvals", () => ({ approvalsApi: { list: async () => [] } }));
vi.mock("../api/auth", () => ({ authApi: { getSession: async () => null } }));
vi.mock("../api/dashboard", () => ({ dashboardApi: { summary: async () => null } }));
vi.mock("../api/heartbeats", () => ({ heartbeatsApi: { list: async () => [] } }));
vi.mock("../api/inboxDismissals", () => ({ inboxDismissalsApi: { list: async () => [] } }));
vi.mock("./useSharedPolling", () => ({ useSharedPollingQuery: () => ({}), usePublishSharedQueryData: () => {} }));

(globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
let captured: ReturnType<typeof useInboxBadge>;
function Harness({ companyId }: { companyId: string | null }) { captured = useInboxBadge(companyId); return null; }

describe("Inbox badge uses native unread count instead of hidden issue preload", () => {
  let client: QueryClient, root: Root, container: HTMLDivElement;
  async function render(companyId: string | null) {
    await act(async () => { root.render(<QueryClientProvider client={client}><Harness companyId={companyId} /></QueryClientProvider>); });
  }
  async function expectCount(count: number) {
    for (let attempt = 0; attempt < 100 && captured.mineIssues !== count; attempt += 1) {
      await act(async () => { await new Promise((resolve) => setTimeout(resolve, 10)); });
    }
    expect(captured.mineIssues).toBe(count);
  }
  beforeEach(() => {
    mocks.count.mockReset().mockResolvedValue({ count: 137 });
    mocks.list.mockReset().mockResolvedValue([]);
    localStorage.clear();
    client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    container = document.createElement("div"); document.body.appendChild(container); root = createRoot(container);
  });
  afterEach(async () => { await act(async () => root.unmount()); client.clear(); container.remove(); });

  it("counts globally eligible unread issues without hydrating or truncating rows", async () => {
    await render("company-a");
    await expectCount(137);
    expect(captured.inbox).toBe(137);
    expect(mocks.count).toHaveBeenCalledTimes(1);
    expect(mocks.count).toHaveBeenCalledWith("company-a", {
      touchedByUserId: "me", inboxArchivedByUserId: "me", unreadForUserId: "me",
      status: "backlog,todo,in_progress,in_review,blocked,done",
    });
    expect(mocks.list).not.toHaveBeenCalled();
    expect(client.getQueryData(queryKeys.issues.listMineByMe("company-a"))).toBeUndefined();
  });

  it("refreshes on existing archive/sidebar invalidation without corrupting list cache", async () => {
    const rows = [{ id: "cached-row" }];
    client.setQueryData(queryKeys.issues.listMineByMe("company-a"), rows);
    await render("company-a");
    await expectCount(137);
    mocks.count.mockResolvedValue({ count: 136 });
    await act(async () => { await client.invalidateQueries({ queryKey: queryKeys.sidebarBadges("company-a") }); });
    await expectCount(136);
    expect(captured.inbox).toBe(136);
    expect(client.getQueryData(queryKeys.issues.listMineByMe("company-a"))).toEqual(rows);
    expect(mocks.list).not.toHaveBeenCalled();
  });

  it("decrements once for an unread personal archive and rolls back only the failed archive", async () => {
    client.setQueryData(queryKeys.issues.listMineByMe("company-a"), [
      { id: "a", isUnreadForMe: true }, { id: "b", isUnreadForMe: true },
    ]);
    await render("company-a"); await expectCount(137);
    const first = snapshotInboxIssueCaches(client, "company-a");
    await act(async () => { removeIssueFromInboxCaches(client, "company-a", "a"); });
    await expectCount(136);
    const second = snapshotInboxIssueCaches(client, "company-a");
    await act(async () => {
      removeIssueFromInboxCaches(client, "company-a", "a");
      removeIssueFromInboxCaches(client, "company-a", "b");
    });
    await expectCount(135);
    await act(async () => { restoreIssueToInboxCaches(client, first, "a"); });
    await expectCount(136);
    await act(async () => { restoreIssueToInboxCaches(client, first, "a"); });
    await expectCount(136);
    await act(async () => { restoreIssueToInboxCaches(client, second, "b"); });
    await expectCount(137);
    expect(mocks.list).not.toHaveBeenCalled();
  });

  it("does not subtract an archive twice after authoritative count refresh or local guard removal", async () => {
    client.setQueryData(queryKeys.issues.listMineByMe("company-a"), [{ id: "a", isUnreadForMe: true }]);
    await render("company-a"); await expectCount(137);
    const snapshot = snapshotInboxIssueCaches(client, "company-a");
    await act(async () => { removeIssueFromInboxCaches(client, "company-a", "a"); });
    await expectCount(136);
    mocks.count.mockResolvedValue({ count: 136 });
    await act(async () => { await client.invalidateQueries({ queryKey: queryKeys.sidebarBadges("company-a") }); });
    await expectCount(136);
    await act(async () => { beginLocalInboxArchive("company-a", "a"); clearLocalInboxArchive("company-a", "a"); });
    await expectCount(136);
    // A fresh server result supersedes local deltas. Restoring row data must not
    // increment an already-authoritative count; onSettled revalidates it again.
    await act(async () => { restoreIssueToInboxCaches(client, snapshot, "a"); });
    await expectCount(136);
  });

  it("ignores read, unknown and other-company archive rows", async () => {
    client.setQueryData(queryKeys.issues.listMineByMe("company-a"), [{ id: "read", isUnreadForMe: false }, { id: "cancelled", status: "cancelled", isUnreadForMe: true }, { id: "routine", originKind: "routine_execution", isUnreadForMe: true }]);
    client.setQueryData(queryKeys.issues.listMineByMe("company-b"), [{ id: "other", isUnreadForMe: true }]);
    await render("company-a"); await expectCount(137);
    await act(async () => {
      removeIssueFromInboxCaches(client, "company-a", "read");
      removeIssueFromInboxCaches(client, "company-a", "unknown");
      removeIssueFromInboxCaches(client, "company-a", "cancelled");
      removeIssueFromInboxCaches(client, "company-a", "routine");
      removeIssueFromInboxCaches(client, "company-b", "other");
    });
    await expectCount(137);
    expect(mocks.list).not.toHaveBeenCalled();
  });

  it("read and unread confirmations refresh the count without changing cached list types", async () => {
    client.setQueryData<Issue[]>(queryKeys.issues.listMineByMe("company-a"), [{ id: "a", isUnreadForMe: true } as Issue]);
    await render("company-a"); await expectCount(137);
    mocks.count.mockResolvedValue({ count: 136 });
    await act(async () => { await client.invalidateQueries({ queryKey: queryKeys.sidebarBadges("company-a") }); });
    await expectCount(136);
    mocks.count.mockResolvedValue({ count: 137 });
    await act(async () => { await client.invalidateQueries({ queryKey: queryKeys.sidebarBadges("company-a") }); });
    await expectCount(137);
    expect(Array.isArray(client.getQueryData(queryKeys.issues.listMineByMe("company-a")))).toBe(true);
    expect(mocks.list).not.toHaveBeenCalled();
  });

  it("does not reuse another company's count", async () => {
    mocks.count.mockImplementation(async (company: string) => ({ count: company === "company-a" ? 137 : 2 }));
    await render("company-a");
    await expectCount(137);
    await render("company-b");
    await expectCount(2);
    expect(captured.inbox).toBe(2);
  });

  it("makes no issue request without a selected company", async () => {
    await render(null);
    expect(captured.mineIssues).toBe(0);
    expect(mocks.count).not.toHaveBeenCalled();
    expect(mocks.list).not.toHaveBeenCalled();
  });
});
