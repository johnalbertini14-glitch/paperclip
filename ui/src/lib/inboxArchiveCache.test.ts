import { QueryClient, QueryObserver } from "@tanstack/react-query";
import type { Issue } from "@paperclipai/shared";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  beginLocalInboxArchive,
  boundLocalInboxArchive,
  cancelInboxIssueQueries,
  clearLocalInboxArchive,
  confirmLocalInboxArchive,
  filterLocalInboxArchivedIssues,
  getIssuePresenceInActiveInboxCaches,
  getLocalInboxArchiveIssueIds,
  removeIssueFromInboxCaches,
  restoreIssueToInboxCaches,
  snapshotInboxIssueCaches,
} from "./inboxArchiveCache";
import { queryKeys } from "./queryKeys";

function issue(id: string): Issue {
  return { id } as Issue;
}

describe("inboxArchiveCache", () => {
  afterEach(() => {
    vi.useRealTimers();
    for (const issueId of getLocalInboxArchiveIssueIds("company-1")) {
      clearLocalInboxArchive("company-1", issueId);
    }
  });

  it("restores only the failed archive during overlapping optimistic removals", () => {
    const companyId = "company-1";
    const queryClient = new QueryClient();
    const queryKey = [...queryKeys.issues.listMineByMe(companyId), "with-routine-executions"] as const;

    queryClient.setQueryData<Issue[]>(queryKey, [
      issue("issue-a"),
      issue("issue-b"),
      issue("issue-c"),
    ]);

    const archiveASnapshot = snapshotInboxIssueCaches(queryClient, companyId);
    removeIssueFromInboxCaches(queryClient, companyId, "issue-a");

    const archiveBSnapshot = snapshotInboxIssueCaches(queryClient, companyId);
    removeIssueFromInboxCaches(queryClient, companyId, "issue-b");

    restoreIssueToInboxCaches(queryClient, archiveASnapshot, "issue-a");

    expect(queryClient.getQueryData<Issue[]>(queryKey)?.map((cachedIssue) => cachedIssue.id)).toEqual([
      "issue-a",
      "issue-c",
    ]);

    restoreIssueToInboxCaches(queryClient, archiveBSnapshot, "issue-b");

    expect(queryClient.getQueryData<Issue[]>(queryKey)?.map((cachedIssue) => cachedIssue.id)).toEqual([
      "issue-a",
      "issue-b",
      "issue-c",
    ]);
  });

  it("cancels the in-flight unread count before applying an archive delta", async () => {
    const client = new QueryClient();
    const countKey = [...queryKeys.sidebarBadges("company-1"), "unread-issues"];
    let resolve!: (value: { count: number }) => void;
    const request = client.fetchQuery({ queryKey: countKey, queryFn: () => new Promise<{ count: number }>((done) => { resolve = done; }) }).catch(() => undefined);
    await cancelInboxIssueQueries(client, "company-1");
    client.setQueryData(countKey, { count: 5 });
    resolve({ count: 99 });
    await request;
    expect(client.getQueryData(countKey)).toEqual({ count: 5 });
    client.clear();
  });

  it("does not invent an unloaded badge or decrement below zero", () => {
    const client = new QueryClient();
    const key = queryKeys.issues.listMineByMe("company-1");
    const countKey = [...queryKeys.sidebarBadges("company-1"), "unread-issues"];
    const row = { id: "a", isUnreadForMe: true } as Issue;
    client.setQueryData(key, [row]);
    removeIssueFromInboxCaches(client, "company-1", "a");
    expect(client.getQueryData(countKey)).toBeUndefined();
    client.setQueryData(key, [row]);
    client.setQueryData(countKey, { count: 0 });
    const snapshot = snapshotInboxIssueCaches(client, "company-1");
    removeIssueFromInboxCaches(client, "company-1", "a");
    restoreIssueToInboxCaches(client, snapshot, "a");
    expect(client.getQueryData(countKey)).toEqual({ count: 0 });
    client.clear();
  });

  it("filters locally archived issues until confirmed grace expires", () => {
    vi.useFakeTimers();
    const issues = [issue("issue-a"), issue("issue-b")];

    beginLocalInboxArchive("company-1", "issue-a");
    expect(filterLocalInboxArchivedIssues("company-1", issues)).toEqual([issue("issue-b")]);

    confirmLocalInboxArchive("company-1", "issue-a");
    vi.advanceTimersByTime(4_999);
    expect(filterLocalInboxArchivedIssues("company-1", issues)).toEqual([issue("issue-b")]);

    vi.advanceTimersByTime(1);
    expect(filterLocalInboxArchivedIssues("company-1", issues)).toEqual(issues);
  });

  it("does not expire an in-flight archive before post-settle bounding starts", () => {
    vi.useFakeTimers();
    beginLocalInboxArchive("company-1", "issue-a");

    vi.advanceTimersByTime(30_000);
    expect(getLocalInboxArchiveIssueIds("company-1").has("issue-a")).toBe(true);

    boundLocalInboxArchive("company-1", "issue-a");
    vi.advanceTimersByTime(29_999);
    expect(getLocalInboxArchiveIssueIds("company-1").has("issue-a")).toBe(true);

    vi.advanceTimersByTime(1);
    expect(getLocalInboxArchiveIssueIds("company-1").has("issue-a")).toBe(false);
  });

  it("distinguishes present, absent, and unavailable active inbox data", () => {
    const companyId = "company-1";
    const queryClient = new QueryClient();
    const queryKey = [...queryKeys.issues.listMineByMe(companyId), "with-routine-executions"] as const;

    expect(getIssuePresenceInActiveInboxCaches(queryClient, companyId, "issue-a")).toBe("unknown");

    queryClient.setQueryData<Issue[]>(queryKey, [issue("issue-a")]);
    const observer = new QueryObserver<Issue[]>(queryClient, {
      queryKey,
      queryFn: async () => [],
    });
    const unsubscribe = observer.subscribe(() => undefined);

    expect(getIssuePresenceInActiveInboxCaches(queryClient, companyId, "issue-a")).toBe("present");
    queryClient.setQueryData<Issue[]>(queryKey, [issue("issue-b")]);
    expect(getIssuePresenceInActiveInboxCaches(queryClient, companyId, "issue-a")).toBe("absent");

    unsubscribe();
  });
});
