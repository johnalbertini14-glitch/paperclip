// @vitest-environment jsdom

import type { ComponentProps } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { Approval, HeartbeatRun, Issue } from "@paperclipai/shared";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { CompanyJoinRequest } from "../api/access";
import {
  clearLocalInboxArchive,
  getLocalInboxArchiveIssueIds,
} from "../lib/inboxArchiveCache";
import { taskCollectionPreferencesStorageKey } from "../lib/task-collection-preferences";

const routerMock = vi.hoisted(() => ({
  location: { pathname: "/", search: "", hash: "" },
  navigate: vi.fn(),
}));

const externalObjectMocks = vi.hoisted(() => ({
  summaries: new Map(),
}));

const apiMocks = vi.hoisted(() => ({
  approvalsList: vi.fn(),
  joinRequestsList: vi.fn(),
  userDirectoryList: vi.fn(),
  authSession: vi.fn(),
  dashboardSummary: vi.fn(),
  executionWorkspaceSummaries: vi.fn(),
  issuesList: vi.fn(),
  issueGet: vi.fn(),
  issuesCount: vi.fn(),
  issueLabels: vi.fn(),
  archiveFromInbox: vi.fn(),
  unarchiveFromInbox: vi.fn(),
  agentsList: vi.fn(),
  heartbeatRunsList: vi.fn(),
  liveRunsForCompany: vi.fn(),
  experimentalSettings: vi.fn(),
  projectsList: vi.fn(),
}));

vi.mock("../api/approvals", () => ({
  approvalsApi: { list: apiMocks.approvalsList },
}));

vi.mock("../api/access", async () => {
  const actual = await vi.importActual<typeof import("../api/access")>("../api/access");
  return {
    ...actual,
    accessApi: {
      listJoinRequests: apiMocks.joinRequestsList,
      listUserDirectory: apiMocks.userDirectoryList,
    },
  };
});

vi.mock("../api/auth", () => ({
  authApi: { getSession: apiMocks.authSession },
}));

vi.mock("../api/dashboard", () => ({
  dashboardApi: { summary: apiMocks.dashboardSummary },
}));

vi.mock("../api/execution-workspaces", () => ({
  executionWorkspacesApi: { listSummaries: apiMocks.executionWorkspaceSummaries },
}));

vi.mock("../api/issues", () => ({
  issuesApi: {
    list: apiMocks.issuesList,
    listCompact: apiMocks.issuesList,
    get: apiMocks.issueGet,
    count: apiMocks.issuesCount,
    listLabels: apiMocks.issueLabels,
    markRead: vi.fn(),
    markUnread: vi.fn(),
    archiveFromInbox: apiMocks.archiveFromInbox,
    unarchiveFromInbox: apiMocks.unarchiveFromInbox,
  },
}));

vi.mock("../api/agents", () => ({
  agentsApi: { list: apiMocks.agentsList },
}));

vi.mock("../api/heartbeats", () => ({
  heartbeatsApi: {
    list: apiMocks.heartbeatRunsList,
    liveRunsForCompany: apiMocks.liveRunsForCompany,
  },
}));

vi.mock("../api/instanceSettings", () => ({
  instanceSettingsApi: { getExperimental: apiMocks.experimentalSettings },
}));

vi.mock("../api/projects", () => ({
  projectsApi: { list: apiMocks.projectsList },
}));

vi.mock("../context/CompanyContext", () => ({
  useCompany: () => ({ selectedCompanyId: "company-1" }),
}));

vi.mock("../context/BreadcrumbContext", () => ({
  useBreadcrumbs: () => ({ setBreadcrumbs: vi.fn() }),
}));

vi.mock("../context/ToastContext", () => ({
  useToastActions: () => ({ pushToast: vi.fn() }),
}));

vi.mock("../context/DialogContext", () => ({
  useDialogActions: () => ({ openNewIssue: vi.fn() }),
}));

vi.mock("../context/SidebarContext", () => ({
  useSidebar: () => ({ isMobile: false }),
}));

vi.mock("../hooks/useInboxBadge", () => ({
  useDismissedInboxAlerts: () => ({ dismissed: new Set(), dismiss: vi.fn() }),
  useInboxDismissals: () => ({ dismissedAtByKey: new Map(), dismiss: vi.fn() }),
  useReadInboxItems: () => ({
    readItems: new Set(),
    markRead: vi.fn(),
    markUnread: vi.fn(),
  }),
}));

vi.mock("../hooks/useIssueExternalObjects", () => ({
  useIssueExternalObjectSummaries: () => ({
    summaries: externalObjectMocks.summaries,
    isLoading: false,
    isReady: true,
  }),
}));

import {
  FailedRunInboxRow,
  Inbox,
  InboxGroupHeader,
  InboxIssueMetaLeading,
  InboxIssueTrailingColumns,
  formatJoinRequestInboxLabel,
} from "./Inbox";

vi.mock("@/lib/router", () => ({
  Link: ({ children, className, ...props }: ComponentProps<"a">) => (
    <a className={className} {...props}>{children}</a>
  ),
  useLocation: () => routerMock.location,
  useNavigate: () => routerMock.navigate,
}));

// eslint-disable-next-line @typescript-eslint/no-explicit-any
(globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;

async function act(callback: () => void | Promise<void>) {
  let result: void | Promise<void> = undefined;
  flushSync(() => {
    result = callback();
  });
  await result;
}

// jsdom doesn't implement scrollIntoView; the inbox calls it from a passive effect.
if (typeof Element !== "undefined" && !Element.prototype.scrollIntoView) {
  Element.prototype.scrollIntoView = () => {};
}

function createIssue(overrides: Partial<Issue> = {}): Issue {
  return {
    id: "issue-1",
    identifier: "PAP-904",
    companyId: "company-1",
    projectId: null,
    projectWorkspaceId: null,
    goalId: null,
    parentId: null,
    title: "Inbox item",
    description: null,
    status: "todo",
    priority: "medium",
    reviewPolicy: null,
    assigneeAgentId: null,
    assigneeUserId: null,
    responsibleUserId: null,
    createdByAgentId: null,
    createdByUserId: null,
    issueNumber: 904,
    requestDepth: 0,
    billingCode: null,
    assigneeAdapterOverrides: null,
    executionWorkspaceId: null,
    executionWorkspacePreference: null,
    executionWorkspaceSettings: null,
    checkoutRunId: null,
    executionRunId: null,
    executionAgentNameKey: null,
    executionLockedAt: null,
    startedAt: null,
    completedAt: null,
    cancelledAt: null,
    hiddenAt: null,
    createdAt: new Date("2026-03-11T00:00:00.000Z"),
    updatedAt: new Date("2026-03-11T00:00:00.000Z"),
    labels: [],
    labelIds: [],
    myLastTouchAt: null,
    lastExternalCommentAt: null,
    lastActivityAt: new Date("2026-03-11T00:00:00.000Z"),
    isUnreadForMe: false,
    ...overrides,
    workMode: overrides.workMode ?? "standard",
  };
}

function createDeferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((innerResolve, innerReject) => {
    resolve = innerResolve;
    reject = innerReject;
  });
  return { promise, resolve, reject };
}

function createJoinRequest(
  overrides: Partial<CompanyJoinRequest> = {},
): CompanyJoinRequest {
  return {
    id: "join-1",
    inviteId: "invite-1",
    companyId: "company-1",
    requestType: "human",
    status: "pending_approval",
    requestIp: "127.0.0.1",
    requestingUserId: "user-1",
    requestEmailSnapshot: "joiner@example.com",
    agentName: null,
    adapterType: null,
    capabilities: null,
    agentDefaultsPayload: null,
    claimSecretExpiresAt: null,
    claimSecretConsumedAt: null,
    createdAgentId: null,
    approvedByUserId: null,
    approvedAt: null,
    rejectedByUserId: null,
    rejectedAt: null,
    createdAt: new Date("2026-03-11T00:00:00.000Z"),
    updatedAt: new Date("2026-03-11T00:00:00.000Z"),
    requesterUser: {
      id: "user-1",
      name: "Jordan Example",
      email: "joiner@example.com",
      image: null,
    },
    approvedByUser: null,
    rejectedByUser: null,
    invite: null,
    ...overrides,
  };
}

function createApproval(overrides: Partial<Approval> = {}): Approval {
  return {
    id: "approval-1",
    companyId: "company-1",
    type: "hire_agent",
    requestedByAgentId: null,
    requestedByUserId: "local-board",
    status: "pending",
    payload: { name: "New teammate" },
    decisionNote: null,
    decidedByUserId: null,
    decidedAt: null,
    createdAt: new Date("2026-03-11T00:00:00.000Z"),
    updatedAt: new Date("2026-03-11T00:00:00.000Z"),
    ...overrides,
  };
}

function createFailedRun(overrides: Partial<HeartbeatRun> = {}): HeartbeatRun {
  return {
    id: "run-1",
    companyId: "company-1",
    agentId: "agent-1",
    responsibleUserId: null,
    invocationSource: "assignment",
    triggerDetail: null,
    status: "failed",
    error: "boom",
    wakeupRequestId: null,
    exitCode: null,
    signal: null,
    usageJson: null,
    resultJson: null,
    sessionIdBefore: null,
    sessionIdAfter: null,
    logStore: null,
    logRef: null,
    logBytes: null,
    logSha256: null,
    logCompressed: false,
    stdoutExcerpt: null,
    stderrExcerpt: null,
    errorCode: null,
    externalRunId: null,
    processPid: null,
    processGroupId: null,
    processStartedAt: null,
    lastOutputAt: null,
    lastOutputSeq: 0,
    lastOutputStream: null,
    lastOutputBytes: null,
    retryOfRunId: null,
    processLossRetryCount: 0,
    livenessState: null,
    livenessReason: null,
    continuationAttempt: 0,
    lastUsefulActionAt: null,
    nextAction: null,
    contextSnapshot: null,
    startedAt: new Date("2026-03-11T00:00:00.000Z"),
    finishedAt: new Date("2026-03-11T00:01:00.000Z"),
    createdAt: new Date("2026-03-11T00:00:00.000Z"),
    updatedAt: new Date("2026-03-11T00:01:00.000Z"),
    ...overrides,
  };
}

function resetInboxApiMocks() {
  for (const mock of Object.values(apiMocks)) mock.mockReset();
  externalObjectMocks.summaries.clear();
  routerMock.location.pathname = "/";
  routerMock.location.search = "";
  routerMock.location.hash = "";
  routerMock.navigate.mockReset();
  apiMocks.approvalsList.mockResolvedValue([]);
  apiMocks.joinRequestsList.mockResolvedValue([]);
  apiMocks.userDirectoryList.mockResolvedValue({ users: [] });
  apiMocks.authSession.mockResolvedValue({
    user: { id: "local-board" },
    session: { userId: "local-board" },
  });
  apiMocks.dashboardSummary.mockResolvedValue({
    agents: { error: 0 },
    costs: { monthBudgetCents: 0, monthUtilizationPercent: 0 },
  });
  apiMocks.executionWorkspaceSummaries.mockResolvedValue([]);
  apiMocks.issuesList.mockResolvedValue([]);
  apiMocks.issueGet.mockResolvedValue(null);
  apiMocks.issuesCount.mockResolvedValue({ count: 0 });
  apiMocks.issueLabels.mockResolvedValue([]);
  apiMocks.archiveFromInbox.mockResolvedValue({ id: "issue-1", archivedAt: new Date() });
  apiMocks.unarchiveFromInbox.mockResolvedValue({ id: "issue-1", archivedAt: new Date() });
  apiMocks.agentsList.mockResolvedValue([]);
  apiMocks.heartbeatRunsList.mockResolvedValue([]);
  apiMocks.liveRunsForCompany.mockResolvedValue([]);
  apiMocks.experimentalSettings.mockResolvedValue({
    enableIsolatedWorkspaces: false,
    enableStreamlinedUi: true,
  });
  apiMocks.projectsList.mockResolvedValue([]);
}

describe("Inbox toolbar", () => {
  let container: HTMLDivElement;

  beforeEach(() => {
    localStorage.clear();
    resetInboxApiMocks();
    container = document.createElement("div");
    document.body.appendChild(container);
  });

  afterEach(() => {
    for (const issueId of getLocalInboxArchiveIssueIds("company-1")) {
      clearLocalInboxArchive("company-1", issueId);
    }
    container.remove();
  });

  it.each([
    { tab: "mine", userId: "user-1", visible: ["own-failure"], hidden: ["other-failure", "unowned-failure"] },
    { tab: "mine", userId: "user-2", visible: ["other-failure"], hidden: ["own-failure", "unowned-failure"] },
    { tab: "mine", userId: "local-board", visible: ["unowned-failure"], hidden: ["own-failure", "other-failure"] },
    { tab: "mine", userId: null, visible: [], hidden: ["own-failure", "other-failure", "unowned-failure"] },
    { tab: "all", userId: "user-1", visible: ["own-failure", "other-failure", "unowned-failure"], hidden: [] },
  ].flatMap((scenario) => [true, false].map((streamlined) => ({ ...scenario, streamlined }))))(
    "scopes failed runs on $tab for $userId (streamlined=$streamlined)",
    async ({ tab, userId, visible, hidden, streamlined }) => {
      apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false, enableStreamlinedUi: streamlined });
      routerMock.location.pathname = `/inbox/${tab}`;
      apiMocks.authSession.mockResolvedValue(userId ? { user: { id: userId }, session: { userId } } : null);
      apiMocks.heartbeatRunsList.mockResolvedValue([
        createFailedRun({ id: "own-failure", agentId: "agent-1", responsibleUserId: "user-1" }),
        createFailedRun({ id: "other-failure", agentId: "agent-2", responsibleUserId: "user-2", status: "timed_out" }),
        createFailedRun({ id: "unowned-failure", agentId: "agent-3" }),
      ]);
      const queryClient = new QueryClient({
        defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } },
      });
      const root = createRoot(container);
      try {
        await act(async () => {
          root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>);
        });
        await vi.waitFor(() => {
          expect(apiMocks.heartbeatRunsList).toHaveBeenCalled();
          expect(queryClient.isFetching()).toBe(0);
          for (const id of visible) expect(container.querySelector(`a[to$="/runs/${id}"]`)).not.toBeNull();
          for (const id of hidden) expect(container.querySelector(`a[to$="/runs/${id}"]`)).toBeNull();
        });
      } finally {
        act(() => root.unmount());
        queryClient.clear();
      }
    },
  );

  it("restores the legacy toolbar and issue-row presentation when Streamlined UI is off", async () => {
    routerMock.location.pathname = "/inbox/mine";
    apiMocks.experimentalSettings.mockResolvedValue({
      enableIsolatedWorkspaces: false,
      enableStreamlinedUi: false,
    });
    apiMocks.issuesList.mockResolvedValue([
      createIssue({ id: "legacy-row", identifier: "PAP-1904", title: "Legacy inbox task" }),
    ]);
    localStorage.setItem(
      taskCollectionPreferencesStorageKey({ companyId: "company-1", collectionKey: "inbox" }),
      JSON.stringify({
        version: 1,
        companyId: "company-1",
        collectionKey: "inbox",
        viewState: {},
        columns: [],
      }),
    );

    const queryClient = new QueryClient({
      defaultOptions: { queries: { retry: false, staleTime: 0, gcTime: 0 } },
    });
    const root = createRoot(container);

    await act(async () => {
      root.render(
        <QueryClientProvider client={queryClient}>
          <Inbox />
        </QueryClientProvider>,
      );
    });
    await vi.waitFor(() => expect(container.textContent).toContain("Legacy inbox task"));

    expect(container.querySelector('[data-slot="collection-toolbar"]')).toBeNull();
    expect(container.querySelector('[role="toolbar"][aria-label="Inbox controls"]')).toBeNull();
    expect(container.textContent).toContain("Mine");
    expect(container.querySelector('[data-slot="task-row"]')).toBeNull();
    const issueLink = container.querySelector('[data-inbox-issue-link]');
    // Production reads the legacy Inbox column key and must ignore the
    // Streamlined collection envelope above when the experiment is disabled.
    expect(issueLink?.parentElement?.textContent).toContain("PAP-1904");

    act(() => root.unmount());
  });

  it("does not render external-object summaries in inbox rows", async () => {
    routerMock.location.pathname = "/inbox/mine";
    const issue = createIssue({ title: "Inbox row without external object column" });
    apiMocks.issuesList.mockResolvedValue([issue]);
    externalObjectMocks.summaries.set(issue.id, {
      total: 1,
      highestSeverity: "failed",
      byStatusCategory: { failed: 1 },
      objects: [],
    });

    const queryClient = new QueryClient({
      defaultOptions: { queries: { retry: false, staleTime: 0, gcTime: 0 } },
    });
    const root = createRoot(container);

    await act(async () => {
      root.render(
        <QueryClientProvider client={queryClient}>
          <Inbox />
        </QueryClientProvider>,
      );
    });
    await vi.waitFor(() => {
      expect(container.textContent).toContain(issue.title);
    });

    expect(container.querySelector('[aria-label^="External objects:"]')).toBeNull();

    act(() => root.unmount());
  });

  it("keeps archive hover actions and swipe targets on every unread non-task Mine row", async () => {
    routerMock.location.pathname = "/inbox/mine";
    localStorage.setItem("paperclip:inbox:group-by", "none");
    apiMocks.approvalsList.mockResolvedValue([createApproval()]);
    apiMocks.heartbeatRunsList.mockResolvedValue([createFailedRun()]);
    apiMocks.joinRequestsList.mockResolvedValue([createJoinRequest()]);

    const queryClient = new QueryClient({
      defaultOptions: { queries: { retry: false, staleTime: 0, gcTime: 0 } },
    });
    const root = createRoot(container);

    await act(async () => {
      root.render(
        <QueryClientProvider client={queryClient}>
          <Inbox />
        </QueryClientProvider>,
      );
    });
    await vi.waitFor(() => {
      expect(container.textContent).toContain("Hire Agent: New teammate");
      expect(container.textContent).toContain("Failed run");
      expect(container.textContent).toContain("Jordan Example");
    });

    const rowFor = (text: string) =>
      [...container.querySelectorAll("[data-inbox-item]")]
        .find((row) => row.textContent?.includes(text));

    for (const text of ["Hire Agent: New teammate", "Failed run", "Jordan Example"]) {
      const row = rowFor(text);
      expect(row, `missing inbox row for ${text}`).toBeDefined();
      expect(row?.querySelector('button[aria-label="Mark as read"]')).not.toBeNull();
      const archiveButton = row?.querySelector<HTMLButtonElement>('button[aria-label="Archive"]');
      expect(archiveButton).not.toBeNull();
      expect(archiveButton?.className).toContain("opacity-0");
      expect(archiveButton?.className).toContain("group-hover:opacity-100");
      expect(row?.querySelector("[data-inbox-row-surface]")).not.toBeNull();
    }

    const approvalRow = rowFor("Hire Agent: New teammate");
    const approvalActions = [...(approvalRow?.querySelectorAll("button") ?? [])]
      .filter((button) => button.textContent === "Approve" || button.textContent === "Reject");
    expect(approvalActions.length).toBeGreaterThanOrEqual(2);
    approvalActions.forEach((button) => {
      expect(button.className).toContain("h-8");
      expect(button.className).toContain("min-w-(--sz-64px)");
      expect(button.className).toContain("justify-center");
    });

    act(() => root.unmount());
  });

  it("restores folded and unfolded sub-tasks across remounts", async () => {
    routerMock.location.pathname = "/inbox/mine";
    const storageKey = "paperclip:inbox:collapsed-parents:company-1";
    localStorage.removeItem(storageKey);

    const parent = createIssue({
      id: "parent-issue",
      identifier: "PAP-1001",
      title: "Parent inbox task",
    });
    const child = createIssue({
      id: "child-issue",
      identifier: "PAP-1002",
      parentId: parent.id,
      title: "Nested inbox task",
    });
    const grandchild = createIssue({
      id: "grandchild-issue",
      identifier: "PAP-1003",
      parentId: child.id,
      title: "Deeply nested inbox task",
    });
    apiMocks.issuesList.mockResolvedValue([parent, child, grandchild]);

    const mountInbox = async () => {
      const queryClient = new QueryClient({
        defaultOptions: { queries: { retry: false, staleTime: 0, gcTime: 0 } },
      });
      const root = createRoot(container);
      await act(async () => {
        root.render(
          <QueryClientProvider client={queryClient}>
            <Inbox />
          </QueryClientProvider>,
        );
      });
      await vi.waitFor(() => {
        expect(container.textContent).toContain(parent.title);
      });
      return root;
    };
    const parentToggle = () => {
      const parentRow = Array.from(container.querySelectorAll("[data-inbox-item]"))
        .find((row) => row.textContent?.includes(parent.title));
      return parentRow?.querySelector<HTMLButtonElement>('button[data-slot="icon-button"]') ?? null;
    };

    let root = await mountInbox();
    try {
      expect(container.textContent).toContain(child.title);
      expect(container.textContent).toContain(grandchild.title);
      const taskRowFor = (title: string) =>
        Array.from(container.querySelectorAll('[data-slot="task-row"]'))
          .find((row) => row.textContent?.includes(title));
      const childTaskRow = taskRowFor(child.title);
      const grandchildTaskRow = taskRowFor(grandchild.title);
      expect(childTaskRow?.querySelectorAll('[data-slot="task-row-tree-guide"]')).toHaveLength(1);
      expect(childTaskRow?.querySelector('button[aria-label="Collapse sub-tasks"]')).not.toBeNull();
      expect(grandchildTaskRow?.querySelectorAll('[data-slot="task-row-tree-guide"]')).toHaveLength(2);
      expect(grandchildTaskRow?.querySelector('[data-slot="task-row-disclosure-spacer"]')).not.toBeNull();

      await act(async () => {
        parentToggle()?.dispatchEvent(new MouseEvent("click", { bubbles: true }));
      });
      await vi.waitFor(() => {
        expect(container.textContent).not.toContain(child.title);
        expect(container.textContent).not.toContain(grandchild.title);
      });
      expect(JSON.parse(localStorage.getItem(storageKey) ?? "[]")).toEqual([parent.id]);

      act(() => root.unmount());
      root = await mountInbox();
      expect(container.textContent).not.toContain(child.title);

      await act(async () => {
        parentToggle()?.dispatchEvent(new MouseEvent("click", { bubbles: true }));
      });
      await vi.waitFor(() => {
        expect(container.textContent).toContain(child.title);
        expect(container.textContent).toContain(grandchild.title);
      });
      expect(JSON.parse(localStorage.getItem(storageKey) ?? "[]")).toEqual([]);

      act(() => root.unmount());
      root = await mountInbox();
      expect(container.textContent).toContain(child.title);
      expect(container.textContent).toContain(grandchild.title);
    } finally {
      localStorage.removeItem(storageKey);
      act(() => root.unmount());
    }
  });

  it("shows blocked toolbar controls on the Blocked tab", async () => {
    routerMock.location.pathname = "/inbox/blocked";
    const queryClient = new QueryClient({
      defaultOptions: { queries: { retry: false, staleTime: 0, gcTime: 0 } },
    });
    const root = createRoot(container);

    await act(async () => {
      root.render(
        <QueryClientProvider client={queryClient}>
          <Inbox />
        </QueryClientProvider>,
      );
    });

    expect(container.querySelector('input[placeholder="Search inbox…"]')).not.toBeNull();
    expect(container.querySelector('[data-testid="inbox-blocked-tab-badge"]')).toBeNull();
    expect(container.querySelector('button[title="Filter"]')).not.toBeNull();
    expect(container.querySelector('button[title="Group"]')).not.toBeNull();
    expect(container.querySelector('button[title="Columns"]')).not.toBeNull();
    expect(container.querySelector('button[title="Sort"]')).not.toBeNull();
    expect(container.querySelector('button[title="Enable parent-child nesting"]')).toBeNull();
    expect(container.textContent).not.toContain("Mark all as read");

    act(() => {
      root.unmount();
    });
  });

  it("keeps Mine, Recent, Unread, Blocked, and All in the shared toolbar geometry", async () => {
    for (const tab of ["mine", "recent", "unread", "blocked", "all"] as const) {
      routerMock.location.pathname = `/inbox/${tab}`;
      const queryClient = new QueryClient({
        defaultOptions: { queries: { retry: false, staleTime: 0, gcTime: 0 } },
      });
      const root = createRoot(container);

      await act(async () => {
        root.render(
          <QueryClientProvider client={queryClient}>
            <Inbox />
          </QueryClientProvider>,
        );
      });

      const toolbar = container.querySelector('[data-slot="collection-toolbar"]');
      expect(toolbar?.getAttribute("aria-label")).toBe("Inbox controls");
      expect(toolbar?.querySelector('[data-slot="collection-toolbar-context"]')).not.toBeNull();
      expect(toolbar?.querySelector('[data-slot="collection-toolbar-search"] input[placeholder="Search inbox…"]')).not.toBeNull();
      expect(toolbar?.querySelector('[data-slot="collection-toolbar-controls"]')).not.toBeNull();
      expect(container.querySelectorAll('input[placeholder="Search inbox…"]')).toHaveLength(1);

      act(() => root.unmount());
      container.replaceChildren();
    }
  });

  it("explains that live-run filtering is different from active task statuses", async () => {
    routerMock.location.pathname = "/inbox/mine";
    localStorage.setItem("paperclip:inbox:filters:company-1", JSON.stringify({
      allCategoryFilter: "everything",
      allApprovalFilter: "all",
      issueFilters: { liveOnly: true },
    }));
    const queryClient = new QueryClient({
      defaultOptions: { queries: { retry: false, staleTime: 0, gcTime: 0 } },
    });
    const root = createRoot(container);

    await act(async () => {
      root.render(
        <QueryClientProvider client={queryClient}>
          <Inbox />
        </QueryClientProvider>,
      );
    });

    expect(container.querySelector('[data-testid="inbox-filter-scope-feedback"]')?.textContent)
      .toBe("Live runs only — tasks currently connected to an agent run.");
    const migrated = JSON.parse(
      localStorage.getItem("paperclip:task-collection:v1:company-1:inbox") ?? "null",
    ) as { companyId?: string; collectionKey?: string } | null;
    expect(migrated).toMatchObject({ companyId: "company-1", collectionKey: "inbox" });

    act(() => root.unmount());
  });

  it("groups ungrouped attention items by Today, Yesterday, and Earlier", async () => {
    routerMock.location.pathname = "/inbox/mine";
    const now = new Date();
    const localNoon = (daysAgo: number) =>
      new Date(now.getFullYear(), now.getMonth(), now.getDate() - daysAgo, 12, 0, 0);
    apiMocks.issuesList.mockResolvedValue([
      createIssue({ id: "today", title: "Today task", lastActivityAt: localNoon(0) }),
      createIssue({ id: "yesterday", title: "Yesterday task", lastActivityAt: localNoon(1) }),
      createIssue({ id: "earlier", title: "Earlier task", lastActivityAt: localNoon(3) }),
    ]);
    const queryClient = new QueryClient({
      defaultOptions: { queries: { retry: false, staleTime: 0, gcTime: 0 } },
    });
    const root = createRoot(container);

    await act(async () => {
      root.render(
        <QueryClientProvider client={queryClient}>
          <Inbox />
        </QueryClientProvider>,
      );
    });
    await vi.waitFor(() => expect(container.textContent).toContain("Earlier task"));

    const separators = [...container.querySelectorAll('[data-testid="inbox-date-group"]')];
    expect(separators.map((node) => node.textContent?.trim()))
      .toEqual(["Today", "Yesterday", "Earlier"]);
    expect(separators.every((separator) => (
      separator.querySelectorAll("[data-date-group-rule]").length === 2
    ))).toBe(true);
    expect(separators.every((separator) => (
      separator.querySelector("[data-date-group-label]")?.classList.contains("text-muted-foreground/70")
    ))).toBe(true);

    act(() => root.unmount());
  });

  it("honors the saved Columns option for hiding date group separators", async () => {
    routerMock.location.pathname = "/inbox/mine";
    localStorage.setItem(
      taskCollectionPreferencesStorageKey({
        companyId: "company-1",
        collectionKey: "inbox",
      }),
      JSON.stringify({
        version: 1,
        companyId: "company-1",
        collectionKey: "inbox",
        viewState: { showDateGroupSeparators: false },
        columns: ["status", "id", "updated"],
      }),
    );
    const now = new Date();
    const localNoon = (daysAgo: number) =>
      new Date(now.getFullYear(), now.getMonth(), now.getDate() - daysAgo, 12, 0, 0);
    apiMocks.issuesList.mockResolvedValue([
      createIssue({ id: "today", title: "Today task", lastActivityAt: localNoon(0) }),
      createIssue({ id: "earlier", title: "Earlier task", lastActivityAt: localNoon(3) }),
    ]);
    const queryClient = new QueryClient({
      defaultOptions: { queries: { retry: false, staleTime: 0, gcTime: 0 } },
    });
    const root = createRoot(container);

    await act(async () => {
      root.render(
        <QueryClientProvider client={queryClient}>
          <Inbox />
        </QueryClientProvider>,
      );
    });
    await vi.waitFor(() => expect(container.textContent).toContain("Earlier task"));

    expect(container.querySelector('[data-testid="inbox-date-group"]')).toBeNull();

    act(() => root.unmount());
  });

  it("shows the resolved isolated workspace name in canonical task metadata", async () => {
    routerMock.location.pathname = "/inbox/mine";
    localStorage.setItem("paperclip:inbox:issue-columns", JSON.stringify(["status", "id", "workspace", "updated"]));
    apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: true });
    apiMocks.executionWorkspaceSummaries.mockResolvedValue([{
      id: "execution-workspace-1",
      name: "Workspace Aurora",
      mode: "isolated_workspace",
      projectWorkspaceId: "project-workspace-1",
    }]);
    apiMocks.projectsList.mockResolvedValue([{
      id: "project-1",
      name: "Launch",
      color: null,
      workspaces: [{ id: "project-workspace-1", name: "Main" }],
      executionWorkspacePolicy: { defaultProjectWorkspaceId: "project-workspace-1" },
      primaryWorkspace: null,
    }]);
    apiMocks.issuesList.mockResolvedValue([createIssue({
      projectId: "project-1",
      executionWorkspaceId: "execution-workspace-1",
      title: "Workspace-aware task",
    })]);
    const queryClient = new QueryClient({
      defaultOptions: { queries: { retry: false, staleTime: 0, gcTime: 0 } },
    });
    const root = createRoot(container);

    await act(async () => {
      root.render(
        <QueryClientProvider client={queryClient}>
          <Inbox />
        </QueryClientProvider>,
      );
    });
    // Workspace metadata resolves independently of the task list.
    await vi.waitFor(() => {
      expect(container.querySelector('[data-slot="task-row"]')?.textContent).toContain("Workspace Aurora");
    });

    const taskRow = container.querySelector('[data-slot="task-row"]');
    const identifier = taskRow?.querySelector('[data-slot="task-row-identifier"]');
    const timestamp = taskRow?.querySelector('[data-slot="task-row-timestamp"]');
    expect(taskRow?.textContent).toContain("Workspace Aurora");
    expect(identifier?.textContent).toBe("PAP-904");
    expect(timestamp).not.toBeNull();
    if (!identifier || !timestamp) throw new Error("Expected canonical identifier and timestamp columns");
    expect(identifier.compareDocumentPosition(timestamp) & Node.DOCUMENT_POSITION_FOLLOWING).not.toBe(0);

    act(() => root.unmount());
  });

  it("hides workspace grouping when isolated workspaces are disabled", async () => {
    routerMock.location.pathname = "/inbox/mine";
    apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false });

    const queryClient = new QueryClient({
      defaultOptions: { queries: { retry: false, staleTime: 0, gcTime: 0 } },
    });
    const root = createRoot(container);

    await act(async () => {
      root.render(
        <QueryClientProvider client={queryClient}>
          <Inbox />
        </QueryClientProvider>,
      );
    });

    const groupButton = container.querySelector<HTMLButtonElement>('button[title="Group"]');
    expect(groupButton).not.toBeNull();

    await act(async () => {
      groupButton?.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });

    const groupOptions = Array.from(document.body.querySelectorAll("button")).map((button) => button.textContent);
    expect(groupOptions).not.toContain("Workspace");

    act(() => {
      root.unmount();
    });
  });

  it("requests live descendant summaries for issue rows", async () => {
    routerMock.location.pathname = "/inbox/mine";

    const queryClient = new QueryClient({
      defaultOptions: { queries: { retry: false, staleTime: 0, gcTime: 0 } },
    });
    const root = createRoot(container);

    await act(async () => {
      root.render(
        <QueryClientProvider client={queryClient}>
          <Inbox />
        </QueryClientProvider>,
      );
    });

    await vi.waitFor(() => {
      expect(apiMocks.issuesList).toHaveBeenCalledTimes(1);
    });

    expect(apiMocks.issuesList).toHaveBeenCalledWith("company-1", expect.objectContaining({
      touchedByUserId: "me",
      inboxArchivedByUserId: "me",
      includeLiveDescendantSummary: true,
      limit: 50,
      offset: 0,
    }), expect.objectContaining({ signal: expect.any(AbortSignal) }));

    act(() => {
      root.unmount();
    });
  });

  it.each([true, false].flatMap((streamlined) => ["mine", "recent", "unread", "all"].map((tab) => ({ streamlined, tab }))))(
    "fetches only active issue-tab resources ($tab, streamlined=$streamlined)",
    async ({ streamlined, tab }) => {
      apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false, enableStreamlinedUi: streamlined });
      routerMock.location.pathname = `/inbox/${tab}`;
      localStorage.setItem("paperclip:inbox:filters:company-1", JSON.stringify({ allCategoryFilter: "everything" }));
      localStorage.setItem(taskCollectionPreferencesStorageKey({ companyId: "company-1", collectionKey: "inbox" }),
        JSON.stringify({ version: 1, companyId: "company-1", collectionKey: "inbox", viewState: { allCategoryFilter: "everything" }, columns: [] }));
      const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
      const root = createRoot(container);
      try {
        await act(async () => {
          root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>);
        });
        await vi.waitFor(() => expect(queryClient.isFetching()).toBe(0));
        const calls = apiMocks.issuesList.mock.calls.map((call) => call[1]);
        expect(calls).toHaveLength(1);
        expect(calls.map((filters) => [filters.touchedByUserId, filters.inboxArchivedByUserId])).toEqual(
          tab === "mine" ? [["me", "me"]] : [["me", undefined]],
        );
      } finally {
        act(() => root.unmount());
        queryClient.clear();
      }
    },
  );

  it.each([true, false])("renders server-filtered Unread rows without a second local unread gate (streamlined=%s)", async (streamlined) => {
    routerMock.location.pathname = "/inbox/unread";
    apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false, enableStreamlinedUi: streamlined });
    const first = Array.from({ length: 50 }, (_, index) => createIssue({
      id: `server-unread-${index}`, identifier: `PAP-${index + 1}`, title: `Server unread ${index}`, isUnreadForMe: false,
    }));
    const offPage = createIssue({ id: "server-unread-50", identifier: "PAP-51", title: "Off-page server unread", isUnreadForMe: false });
    apiMocks.issuesList.mockImplementation((_companyId: string, filters: { unreadForUserId?: string; offset?: number }) =>
      Promise.resolve(filters.unreadForUserId === "me" ? filters.offset === 50 ? [offPage] : first : []));
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
    const root = createRoot(container);
    try {
      await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
      await vi.waitFor(() => expect(apiMocks.issuesList).toHaveBeenCalledWith("company-1", expect.objectContaining({
        touchedByUserId: "me", unreadForUserId: "me", limit: 50, offset: 0,
      }), expect.anything()));
      await vi.waitFor(() => expect(container.textContent).toContain("Server unread 0"));
      await act(async () => Array.from(container.querySelectorAll("button"))
        .find((button) => button.textContent === "Load more recent tasks")!.click());
      await vi.waitFor(() => expect(container.textContent).toContain("Off-page server unread"));
      expect(apiMocks.issuesList.mock.calls.at(-1)?.[1]).toEqual(expect.objectContaining({ unreadForUserId: "me", offset: 50 }));
    } finally {
      act(() => root.unmount());
      queryClient.clear();
    }
  });

  it.each([true, false].flatMap((streamlined) => ["mine", "recent", "unread"].map((tab) => ({ streamlined, tab }))))(
    "pre-filters persisted routine visibility before paging on $tab (streamlined=$streamlined)",
    async ({ streamlined, tab }) => {
      routerMock.location.pathname = `/inbox/${tab}`;
      apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false, enableStreamlinedUi: streamlined });
      const viewState = { issueFilters: { hideRoutineExecutions: true } };
      localStorage.setItem("paperclip:inbox:filters:company-1", JSON.stringify(viewState));
      localStorage.setItem(taskCollectionPreferencesStorageKey({ companyId: "company-1", collectionKey: "inbox" }),
        JSON.stringify({ version: 1, companyId: "company-1", collectionKey: "inbox", viewState, columns: [] }));
      const first = Array.from({ length: 50 }, (_, index) => createIssue({
        id: `manual-${index}`, identifier: `PAP-${index + 1}`, title: `Manual task ${index}`, isUnreadForMe: true,
      }));
      const offPage = createIssue({ id: "manual-50", identifier: "PAP-51", title: "Off-page manual task", isUnreadForMe: true });
      apiMocks.issuesList.mockImplementation((_companyId: string, filters: { excludeRoutineExecutions?: boolean; offset?: number }) =>
        Promise.resolve(filters.excludeRoutineExecutions ? filters.offset === 50 ? [offPage] : first : []));
      const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
      const root = createRoot(container);
      try {
        await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
        await vi.waitFor(() => expect(apiMocks.issuesList).toHaveBeenCalledTimes(1));
        expect(apiMocks.issuesList).toHaveBeenCalledWith("company-1", expect.objectContaining({
          touchedByUserId: "me", excludeRoutineExecutions: true, limit: 50, offset: 0,
          ...(tab === "unread" ? { unreadForUserId: "me" } : {}),
        }), expect.anything());
        await vi.waitFor(() => expect(container.textContent).toContain("Manual task 0"));
        const label = tab === "mine" ? "Load more tasks" : "Load more recent tasks";
        await act(async () => Array.from(container.querySelectorAll("button"))
          .find((button) => button.textContent === label)!.click());
        await vi.waitFor(() => expect(container.textContent).toContain("Off-page manual task"));
        expect(apiMocks.issuesList.mock.calls.at(-1)?.[1]).toEqual(expect.objectContaining({
          excludeRoutineExecutions: true, limit: 50, offset: 50,
        }));
        expect(container.textContent).not.toContain(label);
        expect(queryClient.getQueryCache().findAll().filter((query) => query.queryKey.includes("inbox:mine-issues"))
          .every((query) => query.state.data === undefined)).toBe(true);
      } finally {
        act(() => root.unmount());
        queryClient.clear();
      }
    },
  );

  it.each([true, false])("does not show an unfiltered routine result on Mine (streamlined=%s)", async (streamlined) => {
    routerMock.location.pathname = "/inbox/mine";
    apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false, enableStreamlinedUi: streamlined });
    const viewState = { issueFilters: { hideRoutineExecutions: true } };
    localStorage.setItem("paperclip:inbox:filters:company-1", JSON.stringify(viewState));
    localStorage.setItem(taskCollectionPreferencesStorageKey({ companyId: "company-1", collectionKey: "inbox" }),
      JSON.stringify({ version: 1, companyId: "company-1", collectionKey: "inbox", viewState, columns: [] }));
    apiMocks.issuesList.mockImplementation((_companyId: string, filters: { excludeRoutineExecutions?: boolean }) =>
      Promise.resolve(filters.excludeRoutineExecutions ? [] : [createIssue({ title: "Unfiltered routine result", originKind: "routine_execution" })]));
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
    const root = createRoot(container);
    try {
      await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
      await vi.waitFor(() => expect(apiMocks.issuesList).toHaveBeenCalledTimes(1));
      expect(apiMocks.issuesList.mock.calls[0][1]).toEqual(expect.objectContaining({ excludeRoutineExecutions: true, offset: 0, limit: 50 }));
      expect(container.textContent).not.toContain("Unfiltered routine result");
      expect(container.textContent).not.toContain("Load more tasks");
    } finally {
      act(() => root.unmount());
      queryClient.clear();
    }
  });

  it.each([true, false].flatMap((streamlined) => ["mine", "recent", "unread"].map((tab) => ({ streamlined, tab }))))(
    "pre-filters enabled external-object selection before paging on $tab (streamlined=$streamlined)",
    async ({ streamlined, tab }) => {
      routerMock.location.pathname = `/inbox/${tab}`;
      apiMocks.experimentalSettings.mockResolvedValue({ enableExternalObjects: true, enableStreamlinedUi: streamlined });
      const viewState = { issueFilters: { externalObjectStatuses: ["none", "failed"] } };
      localStorage.setItem("paperclip:inbox:filters:company-1", JSON.stringify(viewState));
      localStorage.setItem(taskCollectionPreferencesStorageKey({ companyId: "company-1", collectionKey: "inbox" }),
        JSON.stringify({ version: 1, companyId: "company-1", collectionKey: "inbox", viewState, columns: [] }));
      const first = Array.from({ length: 50 }, (_, index) => createIssue({
        id: `external-${index}`, identifier: `PAP-${index + 1}`, title: `External task ${index}`, isUnreadForMe: true,
      }));
      const offPage = createIssue({ id: "external-50", identifier: "PAP-51", title: "Off-page external match", isUnreadForMe: true });
      apiMocks.issuesList.mockImplementation((_companyId: string, filters: { externalObjectStatuses?: string; offset?: number }) =>
        Promise.resolve(filters.externalObjectStatuses === "failed,none" ? filters.offset === 50 ? [offPage] : first : []));
      const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
      const root = createRoot(container);
      try {
        await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
        await vi.waitFor(() => expect(apiMocks.issuesList.mock.calls.map(([, filters]) => filters)).toEqual([expect.objectContaining({ externalObjectStatuses: "failed,none" })]));
        expect(apiMocks.issuesList).toHaveBeenCalledWith("company-1", expect.objectContaining({
          touchedByUserId: "me", externalObjectStatuses: "failed,none", limit: 50, offset: 0,
        }), expect.anything());
        await vi.waitFor(() => expect(container.textContent).toContain("External task 0"));
        const label = tab === "mine" ? "Load more tasks" : "Load more recent tasks";
        await act(async () => Array.from(container.querySelectorAll("button"))
          .find((button) => button.textContent === label)!.click());
        await vi.waitFor(() => expect(container.textContent).toContain("Off-page external match"));
        expect(apiMocks.issuesList.mock.calls.at(-1)?.[1]).toEqual(expect.objectContaining({
          externalObjectStatuses: "failed,none", limit: 50, offset: 50,
        }));
        expect(container.textContent).not.toContain(label);
      } finally {
        act(() => root.unmount());
        queryClient.clear();
      }
    },
  );

  it.each([true, false])("does not request a disabled persisted external facet (streamlined=%s)", async (streamlined) => {
    routerMock.location.pathname = "/inbox/mine";
    apiMocks.experimentalSettings.mockResolvedValue({ enableExternalObjects: false, enableStreamlinedUi: streamlined });
    const viewState = { issueFilters: { externalObjectStatuses: ["failed"] } };
    localStorage.setItem("paperclip:inbox:filters:company-1", JSON.stringify(viewState));
    localStorage.setItem(taskCollectionPreferencesStorageKey({ companyId: "company-1", collectionKey: "inbox" }),
      JSON.stringify({ version: 1, companyId: "company-1", collectionKey: "inbox", viewState, columns: [] }));
    apiMocks.issuesList.mockResolvedValue([createIssue({ title: "Unfiltered issue" })]);
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
    const root = createRoot(container);
    try {
      await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
      await vi.waitFor(() => expect(apiMocks.issuesList).toHaveBeenCalledTimes(1));
      expect(apiMocks.issuesList.mock.calls[0][1].externalObjectStatuses).toBeUndefined();
      await vi.waitFor(() => expect(container.textContent).toContain("Unfiltered issue"));
    } finally {
      act(() => root.unmount());
      queryClient.clear();
    }
  });

  it.each([true, false])("does not show an unfiltered external-object match on Mine (streamlined=%s)", async (streamlined) => {
    routerMock.location.pathname = "/inbox/mine";
    apiMocks.experimentalSettings.mockResolvedValue({ enableExternalObjects: true, enableStreamlinedUi: streamlined });
    const viewState = { issueFilters: { externalObjectStatuses: ["failed"] } };
    localStorage.setItem("paperclip:inbox:filters:company-1", JSON.stringify(viewState));
    localStorage.setItem(taskCollectionPreferencesStorageKey({ companyId: "company-1", collectionKey: "inbox" }),
      JSON.stringify({ version: 1, companyId: "company-1", collectionKey: "inbox", viewState, columns: [] }));
    apiMocks.issuesList.mockImplementation((_companyId: string, filters: { externalObjectStatuses?: string }) =>
      Promise.resolve(filters.externalObjectStatuses === "failed" ? [] : [createIssue({ title: "Unfiltered external false match" })]));
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
    const root = createRoot(container);
    try {
      await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
      await vi.waitFor(() => expect(apiMocks.issuesList).toHaveBeenCalledTimes(1));
      expect(apiMocks.issuesList.mock.calls[0][1]).toEqual(expect.objectContaining({ externalObjectStatuses: "failed", limit: 50, offset: 0 }));
      expect(container.textContent).not.toContain("Unfiltered external false match");
      expect(container.textContent).not.toContain("Load more tasks");
    } finally {
      act(() => root.unmount());
      queryClient.clear();
    }
  });

  it.each([true, false].flatMap((streamlined) => ["mine", "recent", "unread"].map((tab) => ({ streamlined, tab }))))(
    "pre-filters live-only before paging on $tab (streamlined=$streamlined)",
    async ({ streamlined, tab }) => {
      routerMock.location.pathname = `/inbox/${tab}`;
      apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false, enableStreamlinedUi: streamlined });
      const viewState = { issueFilters: { liveOnly: true } };
      localStorage.setItem("paperclip:inbox:filters:company-1", JSON.stringify(viewState));
      localStorage.setItem(taskCollectionPreferencesStorageKey({ companyId: "company-1", collectionKey: "inbox" }),
        JSON.stringify({ version: 1, companyId: "company-1", collectionKey: "inbox", viewState, columns: [] }));
      const first = Array.from({ length: 50 }, (_, index) => createIssue({
        id: `live-${index}`, identifier: `PAP-${index + 1}`, title: `Live task ${index}`, isUnreadForMe: true,
      }));
      const offPage = createIssue({ id: "live-50", identifier: "PAP-51", title: "Off-page live match", isUnreadForMe: true });
      apiMocks.issuesList.mockImplementation((_companyId: string, filters: { liveOnly?: boolean; offset?: number }) =>
        Promise.resolve(filters.liveOnly ? filters.offset === 50 ? [offPage] : first : []));
      const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
      const root = createRoot(container);
      try {
        await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
        await vi.waitFor(() => expect(apiMocks.issuesList).toHaveBeenCalledTimes(1));
        expect(apiMocks.issuesList).toHaveBeenCalledWith("company-1", expect.objectContaining({
          touchedByUserId: "me", liveOnly: true, limit: 50, offset: 0,
        }), expect.anything());
        await vi.waitFor(() => expect(container.textContent).toContain("Live task 0"));
        const label = tab === "mine" ? "Load more tasks" : "Load more recent tasks";
        await act(async () => Array.from(container.querySelectorAll("button"))
          .find((button) => button.textContent === label)!.click());
        await vi.waitFor(() => expect(container.textContent).toContain("Off-page live match"));
        expect(apiMocks.issuesList.mock.calls.at(-1)?.[1]).toEqual(expect.objectContaining({ liveOnly: true, limit: 50, offset: 50 }));
        expect(container.textContent).not.toContain(label);
      } finally {
        act(() => root.unmount());
        queryClient.clear();
      }
    },
  );

  it.each([true, false])("does not show an unfiltered live-only false match on Mine (streamlined=%s)", async (streamlined) => {
    routerMock.location.pathname = "/inbox/mine";
    apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false, enableStreamlinedUi: streamlined });
    const viewState = { issueFilters: { liveOnly: true } };
    localStorage.setItem("paperclip:inbox:filters:company-1", JSON.stringify(viewState));
    localStorage.setItem(taskCollectionPreferencesStorageKey({ companyId: "company-1", collectionKey: "inbox" }),
      JSON.stringify({ version: 1, companyId: "company-1", collectionKey: "inbox", viewState, columns: [] }));
    apiMocks.issuesList.mockImplementation((_companyId: string, filters: { liveOnly?: boolean }) =>
      Promise.resolve(filters.liveOnly ? [] : [createIssue({ title: "Unfiltered live false match" })]));
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
    const root = createRoot(container);
    try {
      await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
      await vi.waitFor(() => expect(apiMocks.issuesList).toHaveBeenCalledTimes(1));
      expect(apiMocks.issuesList.mock.calls[0][1]).toEqual(expect.objectContaining({ liveOnly: true, limit: 50, offset: 0 }));
      expect(container.textContent).not.toContain("Unfiltered live false match");
      expect(container.textContent).not.toContain("Load more tasks");
    } finally {
      act(() => root.unmount());
      queryClient.clear();
    }
  });

  it.each([true, false].flatMap((streamlined) => ["mine", "recent", "unread"].map((tab) => ({ streamlined, tab }))))(
    "pre-filters persisted workspace selection before paging on $tab (streamlined=$streamlined)",
    async ({ streamlined, tab }) => {
      routerMock.location.pathname = `/inbox/${tab}`;
      apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: true, enableStreamlinedUi: streamlined });
      const viewState = { issueFilters: { workspaces: ["workspace-b", "workspace-a"] } };
      localStorage.setItem("paperclip:inbox:filters:company-1", JSON.stringify(viewState));
      localStorage.setItem(taskCollectionPreferencesStorageKey({ companyId: "company-1", collectionKey: "inbox" }),
        JSON.stringify({ version: 1, companyId: "company-1", collectionKey: "inbox", viewState, columns: [] }));
      const first = Array.from({ length: 50 }, (_, index) => createIssue({
        id: `workspace-${index}`, identifier: `PAP-${index + 1}`, title: `Workspace task ${index}`, isUnreadForMe: true,
      }));
      const offPage = createIssue({ id: "workspace-50", identifier: "PAP-51", title: "Off-page workspace match", isUnreadForMe: true });
      apiMocks.issuesList.mockImplementation((_companyId: string, filters: { workspaceIds?: string; offset?: number }) =>
        Promise.resolve(filters.workspaceIds === "workspace-a,workspace-b" ? filters.offset === 50 ? [offPage] : first : []));
      const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
      const root = createRoot(container);
      try {
        await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
        await vi.waitFor(() => expect(apiMocks.issuesList).toHaveBeenCalledTimes(1));
        expect(apiMocks.issuesList).toHaveBeenCalledWith("company-1", expect.objectContaining({
          touchedByUserId: "me", workspaceIds: "workspace-a,workspace-b", limit: 50, offset: 0,
        }), expect.anything());
        await vi.waitFor(() => expect(container.textContent).toContain("Workspace task 0"));
        const label = tab === "mine" ? "Load more tasks" : "Load more recent tasks";
        await act(async () => Array.from(container.querySelectorAll("button"))
          .find((button) => button.textContent === label)!.click());
        await vi.waitFor(() => expect(container.textContent).toContain("Off-page workspace match"));
        expect(apiMocks.issuesList.mock.calls.at(-1)?.[1]).toEqual(expect.objectContaining({
          workspaceIds: "workspace-a,workspace-b", limit: 50, offset: 50,
        }));
        expect(container.textContent).not.toContain(label);
      } finally {
        act(() => root.unmount());
        queryClient.clear();
      }
    },
  );

  it.each([true, false])("does not show an unfiltered workspace match on Mine (streamlined=%s)", async (streamlined) => {
    routerMock.location.pathname = "/inbox/mine";
    apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: true, enableStreamlinedUi: streamlined });
    const viewState = { issueFilters: { workspaces: ["workspace-a"] } };
    localStorage.setItem("paperclip:inbox:filters:company-1", JSON.stringify(viewState));
    localStorage.setItem(taskCollectionPreferencesStorageKey({ companyId: "company-1", collectionKey: "inbox" }),
      JSON.stringify({ version: 1, companyId: "company-1", collectionKey: "inbox", viewState, columns: [] }));
    apiMocks.issuesList.mockImplementation((_companyId: string, filters: { workspaceIds?: string }) =>
      Promise.resolve(filters.workspaceIds === "workspace-a" ? [] : [createIssue({ title: "Unfiltered workspace false match" })]));
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
    const root = createRoot(container);
    try {
      await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
      await vi.waitFor(() => expect(apiMocks.issuesList).toHaveBeenCalledTimes(1));
      expect(apiMocks.issuesList.mock.calls[0][1]).toEqual(expect.objectContaining({ workspaceIds: "workspace-a", limit: 50, offset: 0 }));
      expect(container.textContent).not.toContain("Unfiltered workspace false match");
      expect(container.textContent).not.toContain("Load more tasks");
    } finally {
      act(() => root.unmount());
      queryClient.clear();
    }
  });

  it.each([true, false].flatMap((streamlined) => ["mine", "recent", "unread"].map((tab) => ({ streamlined, tab }))))(
    "pre-filters persisted creator selection before paging on $tab (streamlined=$streamlined)",
    async ({ streamlined, tab }) => {
      routerMock.location.pathname = `/inbox/${tab}`;
      apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false, enableStreamlinedUi: streamlined });
      const agentId = "11111111-1111-4111-8111-111111111111";
      const viewState = { issueFilters: { creators: ["user:local-board", `agent:${agentId}`] } };
      localStorage.setItem("paperclip:inbox:filters:company-1", JSON.stringify(viewState));
      localStorage.setItem(taskCollectionPreferencesStorageKey({ companyId: "company-1", collectionKey: "inbox" }),
        JSON.stringify({ version: 1, companyId: "company-1", collectionKey: "inbox", viewState, columns: [] }));
      const createdByAny = `agent:${agentId},user:me`;
      const first = Array.from({ length: 50 }, (_, index) => createIssue({
        id: `creator-${index}`, identifier: `PAP-${index + 1}`, title: `Creator task ${index}`, isUnreadForMe: true,
      }));
      const offPage = createIssue({ id: "creator-50", identifier: "PAP-51", title: "Off-page creator match", isUnreadForMe: true });
      apiMocks.issuesList.mockImplementation((_companyId: string, filters: { createdByAny?: string; offset?: number }) =>
        Promise.resolve(filters.createdByAny === createdByAny ? filters.offset === 50 ? [offPage] : first : []));
      const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
      const root = createRoot(container);
      try {
        await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
        await vi.waitFor(() => expect(apiMocks.issuesList).toHaveBeenCalledTimes(1));
        expect(apiMocks.issuesList).toHaveBeenCalledWith("company-1", expect.objectContaining({
          touchedByUserId: "me", createdByAny, limit: 50, offset: 0,
        }), expect.anything());
        await vi.waitFor(() => expect(container.textContent).toContain("Creator task 0"));
        // A creator-only selection must not cache its filtered rows as the shared unfiltered page.
        const populatedPage = queryClient.getQueryCache().getAll().find((query) => query.state.data === first);
        expect(populatedPage?.queryKey).toContain("creators");
        expect(populatedPage?.queryKey).toContain(createdByAny);
        const label = tab === "mine" ? "Load more tasks" : "Load more recent tasks";
        await act(async () => Array.from(container.querySelectorAll("button"))
          .find((button) => button.textContent === label)!.click());
        await vi.waitFor(() => expect(container.textContent).toContain("Off-page creator match"));
        expect(apiMocks.issuesList.mock.calls.at(-1)?.[1]).toEqual(expect.objectContaining({
          createdByAny, limit: 50, offset: 50,
        }));
        expect(container.textContent).not.toContain(label);
      } finally {
        act(() => root.unmount());
        queryClient.clear();
      }
    },
  );

  it.each([true, false])("does not show an unfiltered creator match on Mine (streamlined=%s)", async (streamlined) => {
    routerMock.location.pathname = "/inbox/mine";
    apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false, enableStreamlinedUi: streamlined });
    const viewState = { issueFilters: { creators: ["user:local-board"] } };
    localStorage.setItem("paperclip:inbox:filters:company-1", JSON.stringify(viewState));
    localStorage.setItem(taskCollectionPreferencesStorageKey({ companyId: "company-1", collectionKey: "inbox" }),
      JSON.stringify({ version: 1, companyId: "company-1", collectionKey: "inbox", viewState, columns: [] }));
    apiMocks.issuesList.mockImplementation((_companyId: string, filters: { createdByAny?: string }) =>
      Promise.resolve(filters.createdByAny === "user:me" ? [] : [createIssue({ title: "Unfiltered creator false match" })]));
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
    const root = createRoot(container);
    try {
      await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
      await vi.waitFor(() => expect(apiMocks.issuesList).toHaveBeenCalledTimes(1));
      expect(apiMocks.issuesList.mock.calls[0][1]).toEqual(expect.objectContaining({ createdByAny: "user:me", limit: 50, offset: 0 }));
      expect(container.textContent).not.toContain("Unfiltered creator false match");
      expect(container.textContent).not.toContain("Load more tasks");
    } finally {
      act(() => root.unmount());
      queryClient.clear();
    }
  });

  it.each([true, false].flatMap((streamlined) => ["mine", "recent", "unread"].map((tab) => ({ streamlined, tab }))))(
    "pre-filters persisted responsible selection before paging on $tab (streamlined=$streamlined)",
    async ({ streamlined, tab }) => {
      routerMock.location.pathname = `/inbox/${tab}`;
      apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false, enableStreamlinedUi: streamlined });
      const agentId = "11111111-1111-4111-8111-111111111111";
      const viewState = { issueFilters: { assignees: ["__me", agentId, "__unassigned"] } };
      localStorage.setItem("paperclip:inbox:filters:company-1", JSON.stringify(viewState));
      localStorage.setItem(taskCollectionPreferencesStorageKey({ companyId: "company-1", collectionKey: "inbox" }),
        JSON.stringify({ version: 1, companyId: "company-1", collectionKey: "inbox", viewState, columns: [] }));
      const assigneeAny = `agent:${agentId},unassigned,user:me`;
      const first = Array.from({ length: 50 }, (_, index) => createIssue({
        id: `owner-${index}`, identifier: `PAP-${index + 1}`, title: `Owner task ${index}`, isUnreadForMe: true,
      }));
      const offPage = createIssue({ id: "owner-50", identifier: "PAP-51", title: "Off-page owner match", isUnreadForMe: true });
      apiMocks.issuesList.mockImplementation((_companyId: string, filters: { assigneeAny?: string; offset?: number }) =>
        Promise.resolve(filters.assigneeAny === assigneeAny ? filters.offset === 50 ? [offPage] : first : []));
      const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
      const root = createRoot(container);
      try {
        await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
        await vi.waitFor(() => expect(apiMocks.issuesList).toHaveBeenCalledTimes(1));
        expect(apiMocks.issuesList).toHaveBeenCalledWith("company-1", expect.objectContaining({
          touchedByUserId: "me", assigneeAny, limit: 50, offset: 0,
        }), expect.anything());
        await vi.waitFor(() => expect(container.textContent).toContain("Owner task 0"));
        const label = tab === "mine" ? "Load more tasks" : "Load more recent tasks";
        await act(async () => Array.from(container.querySelectorAll("button"))
          .find((button) => button.textContent === label)!.click());
        await vi.waitFor(() => expect(container.textContent).toContain("Off-page owner match"));
        expect(apiMocks.issuesList.mock.calls.at(-1)?.[1]).toEqual(expect.objectContaining({
          assigneeAny, limit: 50, offset: 50,
        }));
        expect(container.textContent).not.toContain(label);
      } finally {
        act(() => root.unmount());
        queryClient.clear();
      }
    },
  );

  it.each([true, false])("does not display an unfiltered responsible false match on Mine (streamlined=%s)", async (streamlined) => {
    routerMock.location.pathname = "/inbox/mine";
    apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false, enableStreamlinedUi: streamlined });
    const viewState = { issueFilters: { assignees: ["__unassigned"] } };
    localStorage.setItem("paperclip:inbox:filters:company-1", JSON.stringify(viewState));
    localStorage.setItem(taskCollectionPreferencesStorageKey({ companyId: "company-1", collectionKey: "inbox" }),
      JSON.stringify({ version: 1, companyId: "company-1", collectionKey: "inbox", viewState, columns: [] }));
    apiMocks.issuesList.mockImplementation((_companyId: string, filters: { assigneeAny?: string }) =>
      Promise.resolve(filters.assigneeAny === "unassigned" ? [] : [createIssue({ title: "Unfiltered owner false match" })]));
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
    const root = createRoot(container);
    try {
      await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
      await vi.waitFor(() => expect(apiMocks.issuesList).toHaveBeenCalledTimes(1));
      expect(apiMocks.issuesList.mock.calls[0][1]).toEqual(expect.objectContaining({ assigneeAny: "unassigned", limit: 50, offset: 0 }));
      expect(container.textContent).not.toContain("Unfiltered owner false match");
      expect(container.textContent).not.toContain("Load more tasks");
    } finally {
      act(() => root.unmount());
      queryClient.clear();
    }
  });

  it.each([true, false].flatMap((streamlined) => ["mine", "recent", "unread"].map((tab) => ({ streamlined, tab }))))(
    "pre-filters persisted label and project before paging on $tab (streamlined=$streamlined)",
    async ({ streamlined, tab }) => {
      routerMock.location.pathname = `/inbox/${tab}`;
      apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false, enableStreamlinedUi: streamlined });
      const viewState = { issueFilters: { labels: ["label-b", "label-a"], projects: ["project-b", "project-a"] } };
      localStorage.setItem("paperclip:inbox:filters:company-1", JSON.stringify(viewState));
      localStorage.setItem(taskCollectionPreferencesStorageKey({ companyId: "company-1", collectionKey: "inbox" }),
        JSON.stringify({ version: 1, companyId: "company-1", collectionKey: "inbox", viewState, columns: [] }));
      const first = Array.from({ length: 50 }, (_, index) => createIssue({
        id: `facet-${index}`, identifier: `PAP-${index + 1}`, projectId: "project-a", labelIds: ["label-b"], title: `Facet task ${index}`, isUnreadForMe: true,
      }));
      const offPage = createIssue({ id: "facet-50", identifier: "PAP-51", projectId: "project-b", labelIds: ["label-a"], title: "Off-page facet match", isUnreadForMe: true });
      apiMocks.issuesList.mockImplementation((_companyId: string, filters: { labelIds?: string; projectIds?: string; offset?: number }) =>
        Promise.resolve(filters.labelIds === "label-a,label-b" && filters.projectIds === "project-a,project-b"
          ? filters.offset === 50 ? [offPage] : first : []));
      const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
      const root = createRoot(container);
      try {
        await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
        await vi.waitFor(() => expect(apiMocks.issuesList).toHaveBeenCalledTimes(1));
        expect(apiMocks.issuesList).toHaveBeenCalledWith("company-1", expect.objectContaining({
          touchedByUserId: "me", labelIds: "label-a,label-b", projectIds: "project-a,project-b", limit: 50, offset: 0,
        }), expect.anything());
        await vi.waitFor(() => expect(container.textContent).toContain("Facet task 0"));
        const label = tab === "mine" ? "Load more tasks" : "Load more recent tasks";
        await act(async () => Array.from(container.querySelectorAll("button"))
          .find((button) => button.textContent === label)!.click());
        await vi.waitFor(() => expect(container.textContent).toContain("Off-page facet match"));
        expect(apiMocks.issuesList.mock.calls.at(-1)?.[1]).toEqual(expect.objectContaining({
          labelIds: "label-a,label-b", projectIds: "project-a,project-b", limit: 50, offset: 50,
        }));
        expect(container.textContent).not.toContain(label);
      } finally {
        act(() => root.unmount());
        queryClient.clear();
      }
    },
  );

  it.each([true, false])("keeps server-prefiltered Mine rows when compact fields omit label/project (streamlined=%s)", async (streamlined) => {
    routerMock.location.pathname = "/inbox/mine";
    apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false, enableStreamlinedUi: streamlined });
    const viewState = { issueFilters: { labels: ["label-a"], projects: ["project-a"] } };
    localStorage.setItem("paperclip:inbox:filters:company-1", JSON.stringify(viewState));
    localStorage.setItem(taskCollectionPreferencesStorageKey({ companyId: "company-1", collectionKey: "inbox" }),
      JSON.stringify({ version: 1, companyId: "company-1", collectionKey: "inbox", viewState, columns: [] }));
    apiMocks.issuesList.mockImplementation((_companyId: string, filters: { labelIds?: string; projectIds?: string }) =>
      Promise.resolve(filters.labelIds === "label-a" && filters.projectIds === "project-a"
        ? [createIssue({ title: "Server scoped sparse row", labelIds: [], projectId: null })] : []));
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
    const root = createRoot(container);
    try {
      await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
      await vi.waitFor(() => expect(apiMocks.issuesList).toHaveBeenCalledTimes(1));
      expect(apiMocks.issuesList.mock.calls[0][1]).toEqual(expect.objectContaining({ labelIds: "label-a", projectIds: "project-a", limit: 50, offset: 0 }));
      await vi.waitFor(() => expect(container.textContent).toContain("Server scoped sparse row"));
    } finally {
      act(() => root.unmount());
      queryClient.clear();
    }
  });

  it.each([true, false])("does not display off-page label/project false matches on Mine (streamlined=%s)", async (streamlined) => {
    routerMock.location.pathname = "/inbox/mine";
    apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false, enableStreamlinedUi: streamlined });
    const viewState = { issueFilters: { labels: ["label-a"], projects: ["project-a"] } };
    localStorage.setItem("paperclip:inbox:filters:company-1", JSON.stringify(viewState));
    localStorage.setItem(taskCollectionPreferencesStorageKey({ companyId: "company-1", collectionKey: "inbox" }),
      JSON.stringify({ version: 1, companyId: "company-1", collectionKey: "inbox", viewState, columns: [] }));
    apiMocks.issuesList.mockImplementation((_companyId: string, filters: { labelIds?: string; projectIds?: string }) =>
      Promise.resolve(filters.labelIds === "label-a" && filters.projectIds === "project-a" ? []
        : [createIssue({ title: "Unfiltered false match", projectId: "project-a", labelIds: ["label-a"] })]));
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
    const root = createRoot(container);
    try {
      await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
      await vi.waitFor(() => expect(apiMocks.issuesList).toHaveBeenCalledTimes(1));
      expect(apiMocks.issuesList.mock.calls[0][1]).toEqual(expect.objectContaining({ labelIds: "label-a", projectIds: "project-a", limit: 50, offset: 0 }));
      expect(container.textContent).not.toContain("Unfiltered false match");
      expect(container.textContent).not.toContain("Load more tasks");
    } finally {
      act(() => root.unmount());
      queryClient.clear();
    }
  });

  it.each([true, false].flatMap((streamlined) => ["mine", "recent", "unread"].map((tab) => ({ streamlined, tab }))))(
    "pre-filters persisted status before paging on $tab (streamlined=$streamlined)",
    async ({ streamlined, tab }) => {
      routerMock.location.pathname = `/inbox/${tab}`;
      apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false, enableStreamlinedUi: streamlined });
      const viewState = { issueFilters: { statuses: ["todo", "blocked"] } };
      localStorage.setItem("paperclip:inbox:filters:company-1", JSON.stringify(viewState));
      localStorage.setItem(taskCollectionPreferencesStorageKey({ companyId: "company-1", collectionKey: "inbox" }),
        JSON.stringify({ version: 1, companyId: "company-1", collectionKey: "inbox", viewState, columns: [] }));
      const first = Array.from({ length: 50 }, (_, index) => createIssue({
        id: `status-${index}`, identifier: `PAP-${index + 1}`, status: "todo", title: `Status task ${index}`, isUnreadForMe: true,
      }));
      const offPage = createIssue({ id: "status-50", identifier: "PAP-51", status: "blocked", title: "Off-page status match", isUnreadForMe: true });
      apiMocks.issuesList.mockImplementation((_companyId: string, filters: { status?: string; offset?: number }) =>
        Promise.resolve(filters.status === "todo,blocked" ? filters.offset === 50 ? [offPage] : first : []));
      const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
      const root = createRoot(container);
      try {
        await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
        await vi.waitFor(() => expect(apiMocks.issuesList).toHaveBeenCalledTimes(1));
        expect(apiMocks.issuesList).toHaveBeenCalledWith("company-1", expect.objectContaining({
          touchedByUserId: "me", status: "todo,blocked", limit: 50, offset: 0,
          ...(tab === "unread" ? { unreadForUserId: "me" } : {}),
        }), expect.anything());
        await vi.waitFor(() => expect(container.textContent).toContain("Status task 0"));
        const label = tab === "mine" ? "Load more tasks" : "Load more recent tasks";
        await act(async () => Array.from(container.querySelectorAll("button"))
          .find((button) => button.textContent === label)!.click());
        await vi.waitFor(() => expect(container.textContent).toContain("Off-page status match"));
        expect(apiMocks.issuesList.mock.calls.at(-1)?.[1]).toEqual(expect.objectContaining({ status: "todo,blocked", limit: 50, offset: 50 }));
        expect(container.textContent).not.toContain(label);
      } finally {
        act(() => root.unmount());
        queryClient.clear();
      }
    },
  );

  it.each([true, false])("does not request a page when selected status is outside Inbox scope (streamlined=%s)", async (streamlined) => {
    routerMock.location.pathname = "/inbox/mine";
    apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false, enableStreamlinedUi: streamlined });
    const viewState = { issueFilters: { statuses: ["cancelled"] } };
    localStorage.setItem("paperclip:inbox:filters:company-1", JSON.stringify(viewState));
    localStorage.setItem(taskCollectionPreferencesStorageKey({ companyId: "company-1", collectionKey: "inbox" }),
      JSON.stringify({ version: 1, companyId: "company-1", collectionKey: "inbox", viewState, columns: [] }));
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
    const root = createRoot(container);
    try {
      await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
      expect(apiMocks.issuesList).not.toHaveBeenCalled();
      expect(container.textContent).not.toContain("Load more tasks");
    } finally {
      act(() => root.unmount());
      queryClient.clear();
    }
  });

  it.each([true, false].flatMap((streamlined) => ["mine", "recent", "unread"].map((tab) => ({ streamlined, tab }))))(
    "pre-filters persisted priority globally on $tab (streamlined=$streamlined)",
    async ({ streamlined, tab }) => {
      routerMock.location.pathname = `/inbox/${tab}`;
      apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false, enableStreamlinedUi: streamlined });
      const viewState = { issueFilters: { priorities: ["critical", "high"] } };
      localStorage.setItem("paperclip:inbox:filters:company-1", JSON.stringify(viewState));
      localStorage.setItem(taskCollectionPreferencesStorageKey({ companyId: "company-1", collectionKey: "inbox" }),
        JSON.stringify({ version: 1, companyId: "company-1", collectionKey: "inbox", viewState, columns: [] }));
      const first = Array.from({ length: 50 }, (_, index) => createIssue({
        id: `priority-${index}`, identifier: `PAP-${index + 1}`, priority: "critical", title: `Priority task ${index}`, isUnreadForMe: true,
      }));
      const offPage = createIssue({ id: "priority-50", identifier: "PAP-51", priority: "high", title: "Off-page priority match", isUnreadForMe: true });
      apiMocks.issuesList.mockImplementation((_companyId: string, filters: { priorities?: string; offset?: number }) =>
        Promise.resolve(filters.priorities === "critical,high" ? filters.offset === 50 ? [offPage] : first : []));
      const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
      const root = createRoot(container);
      try {
        await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
        await vi.waitFor(() => expect(apiMocks.issuesList).toHaveBeenCalledTimes(1));
        expect(apiMocks.issuesList).toHaveBeenCalledWith("company-1", expect.objectContaining({
          touchedByUserId: "me", priorities: "critical,high", limit: 50, offset: 0,
          ...(tab === "unread" ? { unreadForUserId: "me" } : {}),
        }), expect.anything());
        await vi.waitFor(() => expect(container.textContent).toContain("Priority task 0"));
        const label = tab === "mine" ? "Load more tasks" : "Load more recent tasks";
        await vi.waitFor(() => expect(container.textContent).toContain(label));
        expect(container.textContent).not.toContain("Off-page priority match");
        await act(async () => Array.from(container.querySelectorAll("button"))
          .find((button) => button.textContent === label)!.click());
        await vi.waitFor(() => expect(container.textContent).toContain("Off-page priority match"));
        expect(apiMocks.issuesList.mock.calls.at(-1)?.[1]).toEqual(expect.objectContaining({
          priorities: "critical,high", limit: 50, offset: 50,
        }));
        expect(container.textContent).not.toContain(label);
        expect(queryClient.getQueryCache().findAll().filter((query) =>
          query.queryKey.includes("inbox-supplement") || query.queryKey.includes("inbox:mine-issues"))
          .every((query) => query.state.data === undefined)).toBe(true);
      } finally {
        act(() => root.unmount());
        queryClient.clear();
      }
    },
  );

  it.each([true, false])("keeps off-page priority no-match truthful on Mine (streamlined=%s)", async (streamlined) => {
    routerMock.location.pathname = "/inbox/mine";
    apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false, enableStreamlinedUi: streamlined });
    const viewState = { issueFilters: { priorities: ["critical"] } };
    localStorage.setItem("paperclip:inbox:filters:company-1", JSON.stringify(viewState));
    localStorage.setItem(taskCollectionPreferencesStorageKey({ companyId: "company-1", collectionKey: "inbox" }),
      JSON.stringify({ version: 1, companyId: "company-1", collectionKey: "inbox", viewState, columns: [] }));
    apiMocks.issuesList.mockImplementation((_companyId: string, filters: { priorities?: string }) =>
      Promise.resolve(filters.priorities === "critical" ? [] : [createIssue({ title: "Unfiltered false match", priority: "critical" })]));
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
    const root = createRoot(container);
    try {
      await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
      await vi.waitFor(() => expect(apiMocks.issuesList).toHaveBeenCalledTimes(1));
      expect(apiMocks.issuesList.mock.calls[0][1]).toEqual(expect.objectContaining({ priorities: "critical", offset: 0, limit: 50 }));
      expect(container.textContent).not.toContain("Unfiltered false match");
      expect(container.textContent).not.toContain("Load more tasks");
    } finally {
      act(() => root.unmount());
      queryClient.clear();
    }
  });

  it.each([true, false])("pages Mine by server offset and stops at a short page (streamlined=%s)", async (streamlined) => {
    routerMock.location.pathname = "/inbox/mine";
    apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false, enableStreamlinedUi: streamlined });
    const first = Array.from({ length: 50 }, (_, index) => createIssue({
      id: `mine-${index}`, identifier: `PAP-${index + 1}`, title: `First page task ${index}`,
    }));
    const offPage = createIssue({ id: "mine-50", identifier: "PAP-51", title: "Off-page Mine task" });
    apiMocks.issuesList.mockImplementation((_companyId: string, filters: { offset?: number; touchedByUserId?: string }) =>
      Promise.resolve(filters.touchedByUserId === "me" && filters.offset === 50 ? [offPage] : first));
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
    const root = createRoot(container);
    try {
      await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
      await vi.waitFor(() => expect(container.textContent).toContain("Load more tasks"));
      expect(apiMocks.issuesList).toHaveBeenCalledWith("company-1", expect.objectContaining({
        touchedByUserId: "me", inboxArchivedByUserId: "me", limit: 50, offset: 0,
      }), expect.anything());
      expect(container.textContent).not.toContain("Off-page Mine task");
      await act(async () => Array.from(container.querySelectorAll("button"))
        .find((button) => button.textContent === "Load more tasks")!.click());
      await vi.waitFor(() => expect(apiMocks.issuesList.mock.calls.some((call) =>
        call[1].touchedByUserId === "me" && call[1].limit === 50 && call[1].offset === 50)).toBe(true));
      await vi.waitFor(() => expect(container.textContent).toContain("Off-page Mine task"));
      expect(container.textContent).not.toContain("Load more tasks");
    } finally {
      act(() => root.unmount());
      queryClient.clear();
    }
  });

  it.each([true, false])("searches only scoped Mine pages and continues beyond 50 (streamlined=%s)", async (streamlined) => {
    routerMock.location.pathname = "/inbox/mine";
    apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false, enableStreamlinedUi: streamlined });
    const first = Array.from({ length: 50 }, (_, index) => createIssue({
      id: `scoped-${index}`, identifier: `PAP-${index + 1}`, title: `Target task ${index}`,
    }));
    const offPage = createIssue({ id: "scoped-50", identifier: "PAP-51", title: "Comment-only Mine match beyond first page" });
    apiMocks.issuesList.mockImplementation((_companyId: string, filters: { q?: string; offset?: number }) => {
      if (filters.q === "Target") return Promise.resolve(filters.offset === 50 ? [offPage] : first);
      return Promise.resolve([]);
    });
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
    const root = createRoot(container);
    try {
      await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
      await vi.waitFor(() => expect(container.querySelector('[data-slot="collection-toolbar"]') === null).toBe(!streamlined));
      const input = container.querySelector<HTMLInputElement>('input[placeholder="Search inbox…"]')!;
      await act(async () => {
        const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
        setter.call(input, "Tar");
        input.dispatchEvent(new Event("input", { bubbles: true }));
        setter.call(input, "Target");
        input.dispatchEvent(new Event("input", { bubbles: true }));
      });
      expect(apiMocks.issuesList.mock.calls.some((call) => call[1].q === "Tar")).toBe(false);
      expect(input.value).toBe("Target");
      await vi.waitFor(() => expect(apiMocks.issuesList.mock.calls.some((call) => call[1].q === "Target")).toBe(true));
      await vi.waitFor(() => expect(queryClient.getQueryCache().findAll().some((query) => query.queryKey.includes("Target") && Array.isArray(query.state.data) && query.state.data.length === 50)).toBe(true));
      expect(input.value).toBe("Target");
      await vi.waitFor(() => expect(container.textContent).toContain("Target task 0"));
      await vi.waitFor(() => expect(container.textContent).toContain("Load more tasks"));
      const searched = apiMocks.issuesList.mock.calls.filter((call) => call[1].q === "Target");
      expect(searched).toHaveLength(1);
      expect(searched[0][1]).toEqual(expect.objectContaining({
        touchedByUserId: "me", inboxArchivedByUserId: "me", limit: 50, offset: 0,
      }));
      expect(container.textContent).not.toContain("Comment-only Mine match beyond first page");
      await act(async () => Array.from(container.querySelectorAll("button"))
        .find((button) => button.textContent === "Load more tasks")!.click());
      await vi.waitFor(() => expect(container.textContent).toContain("Comment-only Mine match beyond first page"));
      expect(apiMocks.issuesList.mock.calls.filter((call) => call[1].q === "Target")).toHaveLength(2);
      expect(apiMocks.issuesList.mock.calls.at(-1)?.[1]).toEqual(expect.objectContaining({
        touchedByUserId: "me", inboxArchivedByUserId: "me", limit: 50, offset: 50,
      }));
      expect(container.textContent).not.toContain("Load more tasks");
      expect(queryClient.getQueryCache().findAll().filter((query) => query.queryKey.includes("inbox-supplement"))
        .every((query) => query.state.fetchStatus === "idle" && query.state.data === undefined)).toBe(true);
    } finally {
      act(() => root.unmount());
      queryClient.clear();
    }
  });

  it.each([true, false])("aborts stale scoped Mine search when the query changes (streamlined=%s)", async (streamlined) => {
    routerMock.location.pathname = "/inbox/mine";
    apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false, enableStreamlinedUi: streamlined });
    const pending = createDeferred<Issue[]>();
    apiMocks.issuesList.mockImplementation((_companyId: string, filters: { q?: string }) => {
      if (filters.q === "old") return pending.promise;
      if (filters.q === "new") return Promise.resolve([createIssue({ id: "fresh-search", title: "new result" })]);
      return Promise.resolve([]);
    });
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: 0 } } });
    const root = createRoot(container);
    try {
      await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
      await vi.waitFor(() => expect(container.querySelector('[data-slot="collection-toolbar"]') === null).toBe(!streamlined));
      const input = container.querySelector<HTMLInputElement>('input[placeholder="Search inbox…"]')!;
      const search = async (text: string) => act(async () => {
        Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, text);
        input.dispatchEvent(new Event("input", { bubbles: true }));
      });
      await search("old");
      await vi.waitFor(() => expect(apiMocks.issuesList.mock.calls.some((call) => call[1].q === "old")).toBe(true));
      const oldCall = apiMocks.issuesList.mock.calls.find((call) => call[1].q === "old")!;
      expect(oldCall[2]?.signal).toBeInstanceOf(AbortSignal);
      await search("new");
      await vi.waitFor(() => expect(container.textContent).toContain("new result"));
      expect(oldCall[2].signal.aborted).toBe(true);
      await act(async () => pending.resolve([createIssue({ id: "stale-search", title: "old result" })]));
      expect(container.textContent).not.toContain("old result");
    } finally {
      await act(async () => pending.resolve([]));
      act(() => root.unmount());
      queryClient.clear();
    }
  });

  it.each(["recent", "unread"].flatMap((tab) => [true, false].map((streamlined) => ({ tab, streamlined }))))(
    "searches scoped $tab pages beyond 50 without a global supplement (streamlined=$streamlined)",
    async ({ tab, streamlined }) => {
      routerMock.location.pathname = `/inbox/${tab}`;
      apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false, enableStreamlinedUi: streamlined });
      const first = Array.from({ length: 50 }, (_, index) => createIssue({
        id: `searched-${index}`, identifier: `PAP-${index + 1}`,
        title: `Target touched task ${index}`, isUnreadForMe: true,
      }));
      const offPage = createIssue({ id: "searched-50", identifier: "PAP-51", title: "Comment-only touched match", isUnreadForMe: true });
      apiMocks.issuesList.mockImplementation((_companyId: string, filters: { q?: string; offset?: number }) =>
        Promise.resolve(filters.q === "Target" ? filters.offset === 50 ? [offPage] : first : []));
      const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
      const root = createRoot(container);
      try {
        await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
        await vi.waitFor(() => expect(container.querySelector('[data-slot="collection-toolbar"]') === null).toBe(!streamlined));
        const input = container.querySelector<HTMLInputElement>('input[placeholder="Search inbox…"]')!;
        await act(async () => {
          Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, "Target");
          input.dispatchEvent(new Event("input", { bubbles: true }));
        });
        await vi.waitFor(() => expect(container.textContent).toContain("Load more recent tasks"));
        expect(apiMocks.issuesList.mock.calls.filter((call) => call[1].q === "Target")).toHaveLength(1);
        expect(apiMocks.issuesList).toHaveBeenCalledWith("company-1", expect.objectContaining({
          touchedByUserId: "me", q: "Target", unreadForUserId: tab === "unread" ? "me" : undefined,
          limit: 50, offset: 0,
        }), expect.anything());
        expect(container.textContent).not.toContain("Comment-only touched match");
        await act(async () => Array.from(container.querySelectorAll("button"))
          .find((button) => button.textContent === "Load more recent tasks")!.click());
        await vi.waitFor(() => expect(container.textContent).toContain("Comment-only touched match"));
        expect(apiMocks.issuesList.mock.calls.filter((call) => call[1].q === "Target")).toHaveLength(2);
        expect(apiMocks.issuesList.mock.calls.at(-1)?.[1]).toEqual(expect.objectContaining({ offset: 50, q: "Target" }));
        expect(queryClient.getQueryCache().findAll().filter((query) => query.queryKey.includes("inbox-supplement"))
          .every((query) => query.state.fetchStatus === "idle" && query.state.data === undefined)).toBe(true);
      } finally {
        act(() => root.unmount());
        queryClient.clear();
      }
    },
  );

  it.each(["recent", "unread"].flatMap((tab) => [true, false].map((streamlined) => ({ tab, streamlined }))))(
    "pages $tab touched tasks with a real continuation (streamlined=$streamlined)",
    async ({ tab, streamlined }) => {
      routerMock.location.pathname = `/inbox/${tab}`;
      apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false, enableStreamlinedUi: streamlined });
      const first = Array.from({ length: 50 }, (_, index) => createIssue({
        id: `touched-${index}`, identifier: `PAP-${index + 1}`,
        title: `First touched task ${index}`, isUnreadForMe: true,
      }));
      const offPage = createIssue({
        id: "touched-50", identifier: "PAP-51", title: "Off-page touched task", isUnreadForMe: true,
      });
      apiMocks.issuesList.mockImplementation((_companyId: string, filters: { offset?: number; touchedByUserId?: string }) =>
        Promise.resolve(filters.touchedByUserId === "me" && filters.offset === 50 ? [offPage] : first));
      const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
      const root = createRoot(container);
      try {
        await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
        await vi.waitFor(() => expect(container.textContent).toContain("Load more recent tasks"));
        expect(apiMocks.issuesList).toHaveBeenCalledWith("company-1", expect.objectContaining({
          touchedByUserId: "me", limit: 50, offset: 0,
        }), expect.anything());
        expect(container.textContent).not.toContain("Off-page touched task");
        await act(async () => Array.from(container.querySelectorAll("button"))
          .find((button) => button.textContent === "Load more recent tasks")!.click());
        await vi.waitFor(() => expect(apiMocks.issuesList.mock.calls.some((call) =>
          call[1].touchedByUserId === "me" && call[1].limit === 50 && call[1].offset === 50)).toBe(true));
        await vi.waitFor(() => expect(container.textContent).toContain("Off-page touched task"));
        expect(container.textContent).not.toContain("Load more recent tasks");
        expect(queryClient.getQueryCache().findAll().some((query) =>
          query.queryKey.includes("offset") && query.queryKey.includes(50)
          && Array.isArray(query.state.data) && query.state.data.some((issue: Issue) => issue.id === offPage.id),
        )).toBe(true);
      } finally {
        act(() => root.unmount());
        queryClient.clear();
      }
    },
  );

  it.each([true, false])("searches All/Everything touched tasks before paging without a 25-result supplement (streamlined=%s)", async (streamlined) => {
    routerMock.location.pathname = "/inbox/all";
    apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false, enableStreamlinedUi: streamlined });
    localStorage.setItem("paperclip:inbox:filters:company-1", JSON.stringify({ allCategoryFilter: "everything" }));
    const first = Array.from({ length: 50 }, (_, index) => createIssue({
      id: `all-search-${index}`, identifier: `PAP-${index + 1}`, title: `Target task ${index}`,
    }));
    const offPage = createIssue({ id: "all-search-50", identifier: "PAP-51", title: "Comment-only off-page match" });
    apiMocks.issuesList.mockImplementation((_companyId: string, filters: { q?: string; offset?: number; touchedByUserId?: string }) =>
      Promise.resolve(filters.touchedByUserId === "me" && filters.q === "Target"
        ? filters.offset === 50 ? [offPage] : first : []));
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
    const root = createRoot(container);
    try {
      await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
      await vi.waitFor(() => expect(container.querySelector('[data-slot="collection-toolbar"]') === null).toBe(!streamlined));
      const input = container.querySelector<HTMLInputElement>('input[placeholder="Search inbox…"]')!;
      await act(async () => {
        Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, "Target");
        input.dispatchEvent(new Event("input", { bubbles: true }));
      });
      await vi.waitFor(() => expect(container.textContent).toContain("Load more recent tasks"));
      expect(apiMocks.issuesList.mock.calls.filter((call) => call[1].q === "Target")).toHaveLength(1);
      expect(apiMocks.issuesList).toHaveBeenCalledWith("company-1", expect.objectContaining({
        touchedByUserId: "me", q: "Target", limit: 50, offset: 0,
      }), expect.anything());
      expect(container.textContent).not.toContain("Comment-only off-page match");
      await act(async () => Array.from(container.querySelectorAll("button"))
        .find((button) => button.textContent === "Load more recent tasks")!.click());
      await vi.waitFor(() => expect(container.textContent).toContain("Comment-only off-page match"));
      expect(apiMocks.issuesList.mock.calls.filter((call) => call[1].q === "Target")).toHaveLength(2);
      expect(apiMocks.issuesList.mock.calls.at(-1)?.[1]).toEqual(expect.objectContaining({ q: "Target", offset: 50 }));
      expect(container.textContent).not.toContain("Load more recent tasks");
      expect(queryClient.getQueryCache().findAll().filter((query) => query.queryKey.includes("inbox-supplement"))
        .every((query) => query.state.fetchStatus === "idle" && query.state.data === undefined)).toBe(true);
    } finally {
      act(() => root.unmount());
      queryClient.clear();
    }
  });

  it.each([true, false])("reports selected Mine zero count with archive scope (streamlined=%s)", async (streamlined) => {
    routerMock.location.pathname = "/inbox/mine";
    apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false, enableStreamlinedUi: streamlined });
    const viewState = { issueFilters: { priorities: ["critical"] } };
    localStorage.setItem("paperclip:inbox:filters:company-1", JSON.stringify(viewState));
    localStorage.setItem(taskCollectionPreferencesStorageKey({ companyId: "company-1", collectionKey: "inbox" }),
      JSON.stringify({ version: 1, companyId: "company-1", collectionKey: "inbox", viewState, columns: [] }));
    apiMocks.issuesCount.mockResolvedValue({ count: 0 });
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
    const root = createRoot(container);
    try {
      await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
      await vi.waitFor(() => expect(container.textContent).toContain("0 matching tasks"));
      expect(apiMocks.issuesCount).toHaveBeenCalledWith("company-1", expect.objectContaining({
        touchedByUserId: "me", inboxArchivedByUserId: "me", priorities: "critical",
      }), expect.anything());
      expect(apiMocks.issuesCount).toHaveBeenCalledTimes(1);
    } finally { act(() => root.unmount()); queryClient.clear(); }
  });

  it.each([true, false])("reports the selected All/Everything server count beyond the first page (streamlined=%s)", async (streamlined) => {
    routerMock.location.pathname = "/inbox/all";
    apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false, enableStreamlinedUi: streamlined });
    const viewState = { allCategoryFilter: "everything", issueFilters: { priorities: ["critical"] } };
    localStorage.setItem("paperclip:inbox:filters:company-1", JSON.stringify(viewState));
    localStorage.setItem(taskCollectionPreferencesStorageKey({ companyId: "company-1", collectionKey: "inbox" }),
      JSON.stringify({ version: 1, companyId: "company-1", collectionKey: "inbox", viewState, columns: [] }));
    apiMocks.issuesList.mockResolvedValue(Array.from({ length: 50 }, (_, i) => createIssue({ id: `count-${i}`, identifier: `PAP-${i}` })));
    apiMocks.issuesCount.mockResolvedValue({ count: 51 });
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
    const root = createRoot(container);
    try {
      await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
      await vi.waitFor(() => expect(container.textContent).toContain("51 matching tasks"));
      expect(apiMocks.issuesCount).toHaveBeenCalledWith("company-1", expect.objectContaining({
        touchedByUserId: "me", priorities: "critical", status: expect.any(String), includeRoutineExecutions: true,
      }), expect.anything());
      expect(apiMocks.issuesCount.mock.calls).toHaveLength(1);
    } finally { act(() => root.unmount()); queryClient.clear(); }
  });

  it.each([true, false])("pre-filters All/Everything touched priority before paging (streamlined=%s)", async (streamlined) => {
    routerMock.location.pathname = "/inbox/all";
    apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false, enableStreamlinedUi: streamlined });
    const viewState = { allCategoryFilter: "everything", issueFilters: { priorities: ["critical"] } };
    localStorage.setItem("paperclip:inbox:filters:company-1", JSON.stringify(viewState));
    localStorage.setItem(taskCollectionPreferencesStorageKey({ companyId: "company-1", collectionKey: "inbox" }),
      JSON.stringify({ version: 1, companyId: "company-1", collectionKey: "inbox", viewState, columns: [] }));
    const first = Array.from({ length: 50 }, (_, index) => createIssue({
      id: `all-priority-${index}`, identifier: `PAP-${index + 1}`, title: `Priority task ${index}`, priority: "critical",
    }));
    const offPage = createIssue({ id: "all-priority-50", identifier: "PAP-51", title: "Off-page priority task", priority: "critical" });
    apiMocks.issuesList.mockImplementation((_companyId: string, filters: { priorities?: string; offset?: number; touchedByUserId?: string }) =>
      Promise.resolve(filters.touchedByUserId === "me" && filters.priorities === "critical"
        ? filters.offset === 50 ? [offPage] : first : []));
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
    const root = createRoot(container);
    try {
      await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
      await vi.waitFor(() => expect(container.textContent).toContain("Load more recent tasks"));
      expect(apiMocks.issuesList.mock.calls.filter((call) => call[1].touchedByUserId === "me")).toHaveLength(1);
      expect(apiMocks.issuesList).toHaveBeenCalledWith("company-1", expect.objectContaining({
        touchedByUserId: "me", priorities: "critical", limit: 50, offset: 0,
      }), expect.anything());
      await act(async () => Array.from(container.querySelectorAll("button"))
        .find((button) => button.textContent === "Load more recent tasks")!.click());
      await vi.waitFor(() => expect(container.textContent).toContain("Off-page priority task"));
      expect(apiMocks.issuesList.mock.calls.at(-1)?.[1]).toEqual(expect.objectContaining({ priorities: "critical", offset: 50 }));
      expect(container.textContent).not.toContain("Load more recent tasks");
    } finally {
      act(() => root.unmount());
      queryClient.clear();
    }
  });

  it.each([true, false])("keeps All/Everything priority no-match server-scoped (streamlined=%s)", async (streamlined) => {
    routerMock.location.pathname = "/inbox/all";
    apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false, enableStreamlinedUi: streamlined });
    const viewState = { allCategoryFilter: "everything", issueFilters: { priorities: ["critical"] } };
    localStorage.setItem("paperclip:inbox:filters:company-1", JSON.stringify(viewState));
    localStorage.setItem(taskCollectionPreferencesStorageKey({ companyId: "company-1", collectionKey: "inbox" }),
      JSON.stringify({ version: 1, companyId: "company-1", collectionKey: "inbox", viewState, columns: [] }));
    apiMocks.issuesList.mockImplementation((_companyId: string, filters: { priorities?: string; touchedByUserId?: string }) =>
      Promise.resolve(filters.touchedByUserId === "me" && filters.priorities !== "critical"
        ? [createIssue({ title: "Unfiltered false match", priority: "critical" })] : []));
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
    const root = createRoot(container);
    try {
      await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
      await vi.waitFor(() => expect(queryClient.isFetching()).toBe(0));
      expect(apiMocks.issuesList.mock.calls.filter((call) => call[1].touchedByUserId === "me")).toHaveLength(1);
      expect(apiMocks.issuesList.mock.calls.find((call) => call[1].touchedByUserId === "me")?.[1])
        .toEqual(expect.objectContaining({ priorities: "critical", limit: 50, offset: 0 }));
      expect(container.textContent).not.toContain("Unfiltered false match");
      expect(queryClient.getQueryCache().findAll().filter((query) => query.queryKey.includes("inbox:touched-issues"))
        .every((query) => query.state.data === undefined)).toBe(true);
    } finally {
      act(() => root.unmount());
      queryClient.clear();
    }
  });

  it.each([true, false])("pre-filters All/Everything external status with one touched page (streamlined=%s)", async (streamlined) => {
    routerMock.location.pathname = "/inbox/all";
    apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false, enableStreamlinedUi: streamlined, enableExternalObjects: true });
    const viewState = { allCategoryFilter: "everything", issueFilters: { externalObjectStatuses: ["failed"] } };
    localStorage.setItem("paperclip:inbox:filters:company-1", JSON.stringify(viewState));
    localStorage.setItem(taskCollectionPreferencesStorageKey({ companyId: "company-1", collectionKey: "inbox" }),
      JSON.stringify({ version: 1, companyId: "company-1", collectionKey: "inbox", viewState, columns: [] }));
    const first = Array.from({ length: 50 }, (_, index) => createIssue({ id: `all-external-${index}`, title: `External ${index}` }));
    const offPage = createIssue({ id: "all-external-50", title: "Off-page external All match" });
    apiMocks.issuesList.mockImplementation((_companyId: string, filters: { externalObjectStatuses?: string; offset?: number }) =>
      Promise.resolve(filters.externalObjectStatuses === "failed" ? filters.offset === 50 ? [offPage] : first : []));
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
    const root = createRoot(container);
    try {
      await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
      await vi.waitFor(() => expect(container.textContent).toContain("Load more recent tasks"));
      expect(apiMocks.issuesList.mock.calls).toHaveLength(1);
      expect(apiMocks.issuesList.mock.calls[0][1]).toEqual(expect.objectContaining({
        touchedByUserId: "me", externalObjectStatuses: "failed", limit: 50, offset: 0,
      }));
      await act(async () => Array.from(container.querySelectorAll("button"))
        .find((button) => button.textContent === "Load more recent tasks")!.click());
      await vi.waitFor(() => expect(container.textContent).toContain("Off-page external All match"));
      expect(apiMocks.issuesList.mock.calls.at(-1)?.[1]).toEqual(expect.objectContaining({ externalObjectStatuses: "failed", offset: 50 }));
      expect(container.textContent).not.toContain("Load more recent tasks");
    } finally {
      act(() => root.unmount());
      queryClient.clear();
    }
  });

  it.each([true, false])("keeps All/Everything external no-match server-scoped (streamlined=%s)", async (streamlined) => {
    routerMock.location.pathname = "/inbox/all";
    apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false, enableStreamlinedUi: streamlined, enableExternalObjects: true });
    const viewState = { allCategoryFilter: "everything", issueFilters: { externalObjectStatuses: ["failed"] } };
    localStorage.setItem("paperclip:inbox:filters:company-1", JSON.stringify(viewState));
    localStorage.setItem(taskCollectionPreferencesStorageKey({ companyId: "company-1", collectionKey: "inbox" }),
      JSON.stringify({ version: 1, companyId: "company-1", collectionKey: "inbox", viewState, columns: [] }));
    apiMocks.issuesList.mockImplementation((_companyId: string, filters: { externalObjectStatuses?: string }) =>
      Promise.resolve(filters.externalObjectStatuses === "failed" ? [] : [createIssue({ title: "Unfiltered All external false match" })]));
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
    const root = createRoot(container);
    try {
      await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
      await vi.waitFor(() => expect(queryClient.isFetching()).toBe(0));
      expect(apiMocks.issuesList.mock.calls).toHaveLength(1);
      expect(apiMocks.issuesList.mock.calls[0][1]).toEqual(expect.objectContaining({
        touchedByUserId: "me", externalObjectStatuses: "failed", limit: 50, offset: 0,
      }));
      expect(container.textContent).not.toContain("Unfiltered All external false match");
    } finally {
      act(() => root.unmount());
      queryClient.clear();
    }
  });

  it.each([true, false])("uses one All/Everything issue page and targets only failed-run context (streamlined=%s)", async (streamlined) => {
    routerMock.location.pathname = "/inbox/all";
    apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false, enableStreamlinedUi: streamlined });
    localStorage.setItem("paperclip:inbox:filters:company-1", JSON.stringify({ allCategoryFilter: "everything" }));
    const target = createIssue({ id: "run-issue", identifier: "PAP-51", title: "Linked run context" });
    apiMocks.heartbeatRunsList.mockResolvedValue([createFailedRun({ contextSnapshot: { issueId: target.id } })]);
    apiMocks.issueGet.mockResolvedValue(target);
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
    const root = createRoot(container);
    try {
      await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
      await vi.waitFor(() => expect(apiMocks.issueGet).toHaveBeenCalledWith(target.id, expect.anything()));
      await vi.waitFor(() => expect(container.textContent).toContain("Linked run context"));
      expect(apiMocks.issuesList.mock.calls.filter((call) => !call[1].touchedByUserId)).toHaveLength(0);
      expect(apiMocks.issuesList.mock.calls.filter((call) => call[1].touchedByUserId === "me")).toHaveLength(1);
    } finally {
      act(() => root.unmount());
      queryClient.clear();
    }
  });

  it.each([true, false])("does not preload issue pages for a non-issue All category (streamlined=%s)", async (streamlined) => {
    routerMock.location.pathname = "/inbox/all";
    apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false, enableStreamlinedUi: streamlined });
    localStorage.setItem(
      taskCollectionPreferencesStorageKey({ companyId: "company-1", collectionKey: "inbox" }),
      JSON.stringify({ version: 1, companyId: "company-1", collectionKey: "inbox", viewState: {
        allCategoryFilter: "approvals",
      }, columns: [] }),
    );
    localStorage.setItem("paperclip:inbox:filters:company-1", JSON.stringify({ allCategoryFilter: "approvals" }));
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
    const root = createRoot(container);
    try {
      await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
      await vi.waitFor(() => expect(queryClient.isFetching()).toBe(0));
      expect(apiMocks.issuesList).not.toHaveBeenCalled();
      expect(queryClient.getQueryCache().findAll().filter((query) => query.queryKey.includes("live-descendant-summary"))
        .every((query) => query.state.fetchStatus === "idle" && query.state.data === undefined)).toBe(true);
    } finally {
      act(() => root.unmount());
      queryClient.clear();
    }
  });

  it.each([true, false])("uses only the touched issue resource for My recent tasks (streamlined=%s)", async (streamlined) => {
    routerMock.location.pathname = "/inbox/all";
    apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false, enableStreamlinedUi: streamlined });
    localStorage.setItem(
      taskCollectionPreferencesStorageKey({ companyId: "company-1", collectionKey: "inbox" }),
      JSON.stringify({ version: 1, companyId: "company-1", collectionKey: "inbox", viewState: {
        allCategoryFilter: "issues_i_touched",
      }, columns: [] }),
    );
    localStorage.setItem("paperclip:inbox:filters:company-1", JSON.stringify({ allCategoryFilter: "issues_i_touched" }));
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
    const root = createRoot(container);
    try {
      await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
      await vi.waitFor(() => expect(queryClient.isFetching()).toBe(0));
      expect(apiMocks.issuesList).toHaveBeenCalledTimes(1);
      expect(apiMocks.issuesList).toHaveBeenCalledWith("company-1", expect.objectContaining({
        touchedByUserId: "me", limit: 50, offset: 0,
      }), expect.anything());
      expect(queryClient.getQueryCache().findAll().filter((query) => query.queryKey.includes("live-descendant-summary"))
        .filter((query) => query.state.data !== undefined)).toHaveLength(1);
    } finally {
      act(() => root.unmount());
      queryClient.clear();
    }
  });

  it.each([true, false])("does not request the unrelated issue-search supplement on Blocked (streamlined=%s)", async (streamlined) => {
    routerMock.location.pathname = "/inbox/blocked";
    apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false, enableStreamlinedUi: streamlined });
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
    const root = createRoot(container);
    try {
      await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
      const input = container.querySelector<HTMLInputElement>('input[placeholder="Search inbox…"]')!;
      await act(async () => {
        Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, "REVA");
        input.dispatchEvent(new Event("input", { bubbles: true }));
      });
      expect(input.value).toBe("REVA");
      expect(apiMocks.issuesList.mock.calls.some((call) => call[1].q === "REVA")).toBe(false);
      expect(queryClient.getQueryCache().findAll().filter((query) => query.queryKey.includes("inbox-supplement"))
        .every((query) => query.state.fetchStatus === "idle" && query.state.data === undefined)).toBe(true);
    } finally {
      act(() => root.unmount());
      queryClient.clear();
    }
  });

  it.each([true, false])("does not show an earlier search supplement while a new search is pending (streamlined=%s)", async (streamlined) => {
    routerMock.location.pathname = "/inbox/recent";
    apiMocks.experimentalSettings.mockResolvedValue({ enableIsolatedWorkspaces: false, enableStreamlinedUi: streamlined });
    let resolvePending!: (rows: Issue[]) => void;
    const pending = new Promise<Issue[]>((resolve) => { resolvePending = resolve; });
    apiMocks.issuesList.mockImplementation((_companyId: string, filters: { q?: string }) => {
      if (filters.q === "old") return Promise.resolve([createIssue({ id: "old-search", title: "Old search supplement" })]);
      if (filters.q === "new") return pending;
      if (filters.q === "newer") return Promise.resolve([]);
      return Promise.resolve([]);
    });
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: 0 } } });
    const root = createRoot(container);
    const setSearch = async (value: string) => {
      const input = container.querySelector<HTMLInputElement>('input[placeholder="Search inbox…"]')!;
      await act(async () => {
        Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, value);
        input.dispatchEvent(new Event("input", { bubbles: true }));
      });
    };
    try {
      await act(async () => root.render(<QueryClientProvider client={queryClient}><Inbox /></QueryClientProvider>));
      await vi.waitFor(() => expect(container.querySelector('[data-slot="collection-toolbar"]') === null).toBe(!streamlined));
      await vi.waitFor(() => expect(container.querySelector('input[placeholder="Search inbox…"]')).not.toBeNull());
      await setSearch("old");
      await vi.waitFor(() => expect(apiMocks.issuesList.mock.calls.some((call) => call[1].q === "old")).toBe(true));
      if (streamlined) await vi.waitFor(() => expect(container.textContent).toContain("Old search supplement"));
      await setSearch("new");
      await vi.waitFor(() => expect(apiMocks.issuesList.mock.calls.some((call) => call[1].q === "new")).toBe(true));
      expect(container.textContent).not.toContain("Old search supplement");
      expect(queryClient.getQueryData(queryClient.getQueryCache().findAll().find((query) =>
        query.queryKey.includes("inbox-supplement") && query.queryKey.includes("new"),
      )!.queryKey)).toBeUndefined();
      const newCall = apiMocks.issuesList.mock.calls.find((call) => call[1].q === "new");
      expect(newCall?.[2]?.signal).toBeInstanceOf(AbortSignal);
      await setSearch("newer");
      await vi.waitFor(() => expect(apiMocks.issuesList.mock.calls.some((call) => call[1].q === "newer")).toBe(true));
      expect(newCall?.[2]?.signal.aborted).toBe(true);
      expect(container.textContent).not.toContain("Old search supplement");
    } finally {
      await act(async () => resolvePending([]));
      act(() => root.unmount());
      queryClient.clear();
    }
  });

  it("paints row hover via CSS only, without moving React selection state", async () => {
    routerMock.location.pathname = "/inbox/mine";
    const issueA = createIssue({ id: "issue-a", identifier: "PAP-1001", title: "First inbox row" });
    const issueB = createIssue({ id: "issue-b", identifier: "PAP-1002", title: "Second inbox row" });
    apiMocks.issuesList.mockResolvedValue([issueA, issueB]);

    const queryClient = new QueryClient({
      defaultOptions: { queries: { retry: false, staleTime: 0, gcTime: 0 } },
    });
    const root = createRoot(container);

    await act(async () => {
      root.render(
        <QueryClientProvider client={queryClient}>
          <Inbox />
        </QueryClientProvider>,
      );
    });
    await vi.waitFor(() => {
      expect(container.querySelectorAll("[data-inbox-item]").length).toBeGreaterThanOrEqual(2);
    });

    const rows = container.querySelectorAll("[data-inbox-item]");

    // The hover wash lives on the IssueRow root band (the overlay link's
    // parent), not the overlay link itself.
    const bandOf = (row: Element): HTMLElement | null =>
      row.querySelector<HTMLAnchorElement>("a[data-inbox-issue-link]")?.parentElement ?? null;

    // Nothing selected before hover — both rows show the hover-accent class.
    expect(bandOf(rows[0]!)?.className).toContain("hover:bg-accent/50");
    expect(bandOf(rows[1]!)?.className).toContain("hover:bg-accent/50");

    // Hovering paints via CSS `:hover` only — it must NOT flip a row into the
    // state-selected band (which would swap to hover:bg-transparent). Coupling
    // hover to React state was the per-hover re-render storm behind the lag;
    // scrubbing the list must not touch selection state. (Keyboard nav that
    // continues from the hovered row is exercised in live/e2e verification.)
    await act(async () => {
      rows[1]!.dispatchEvent(new MouseEvent("mouseover", { bubbles: true }));
      rows[1]!.dispatchEvent(new MouseEvent("mouseenter", { bubbles: false }));
    });
    expect(bandOf(rows[0]!)?.className).toContain("hover:bg-accent/50");
    expect(bandOf(rows[1]!)?.className).toContain("hover:bg-accent/50");
    expect(bandOf(rows[1]!)?.className).not.toContain("hover:bg-transparent");

    act(() => {
      root.unmount();
    });
  });

  it("does not indent unread rows: the mark-read dot overlays the shared task-row gutter", async () => {
    routerMock.location.pathname = "/inbox/mine";
    // Two sibling leaf rows, one unread and one read, so their leading columns
    // are directly comparable.
    const unread = createIssue({
      id: "issue-unread",
      identifier: "PAP-2001",
      title: "Unread inbox row",
      isUnreadForMe: true,
    });
    const read = createIssue({
      id: "issue-read",
      identifier: "PAP-2002",
      title: "Read inbox row",
      isUnreadForMe: false,
    });
    apiMocks.issuesList.mockResolvedValue([unread, read]);

    const queryClient = new QueryClient({
      defaultOptions: { queries: { retry: false, staleTime: 0, gcTime: 0 } },
    });
    const root = createRoot(container);

    await act(async () => {
      root.render(
        <QueryClientProvider client={queryClient}>
          <Inbox />
        </QueryClientProvider>,
      );
    });
    await vi.waitFor(() => {
      expect(container.textContent).toContain("Unread inbox row");
      expect(container.textContent).toContain("Read inbox row");
    });

    const rows = Array.from(container.querySelectorAll("[data-inbox-item]"));
    const rowFor = (text: string) => rows.find((row) => row.textContent?.includes(text));
    const markReadButton = (row: Element) => row.querySelector('button[aria-label="Mark as read"]');
    // The canonical spacer reserves the disclosure column on every leaf row.
    const hasLeadingSpacer = (row: Element) =>
      !!row.querySelector('[data-slot="task-row-disclosure-spacer"]');
    // The overlay anchor is present on read AND unread Inbox rows without
    // consuming a layout column.
    const dotSlot = (row: Element) =>
      row.querySelector('[data-testid="issue-row-unread-slot"]');

    const unreadRow = rowFor("Unread inbox row")!;
    const readRow = rowFor("Read inbox row")!;

    // Both rows share the canonical task-row geometry. The dot is absolutely
    // positioned in the row gutter, so Inbox does not gain a column that Tasks
    // lacks and unread state cannot shift status/title alignment.
    const unreadSlot = dotSlot(unreadRow);
    const readSlot = dotSlot(readRow);
    expect(unreadSlot).not.toBeNull();
    expect(readSlot).not.toBeNull();
    expect(unreadSlot?.className).toContain("absolute");
    // Only the unread row carries the dot button; the read slot is empty.
    expect(markReadButton(unreadSlot!)).not.toBeNull();
    expect(readSlot?.querySelector('button[aria-label="Mark as read"]')).toBeNull();
    expect(hasLeadingSpacer(unreadRow)).toBe(true);

    // Read rows keep the same spacer, so both rows line up.
    expect(hasLeadingSpacer(readRow)).toBe(true);

    act(() => {
      root.unmount();
    });
  });

  it("keeps hover→j/k selection in sync after the list reshapes (PAP-9679)", async () => {
    routerMock.location.pathname = "/inbox/mine";
    const issueA = createIssue({ id: "issue-a", identifier: "PAP-2001", title: "Sync row A" });
    const issueB = createIssue({ id: "issue-b", identifier: "PAP-2002", title: "Sync row B" });
    const issueC = createIssue({ id: "issue-c", identifier: "PAP-2003", title: "Sync row C" });
    apiMocks.issuesList.mockResolvedValue([issueA, issueB, issueC]);

    const queryClient = new QueryClient({
      defaultOptions: { queries: { retry: false, staleTime: 0, gcTime: 0 } },
    });
    const root = createRoot(container);

    // Canonical task rows put the selected wash on the root band (the overlay
    // link's parent); find the row with the standalone selected utility.
    const bandOf = (row: Element): HTMLElement | null =>
      row.querySelector<HTMLAnchorElement>("a[data-inbox-issue-link]")?.parentElement ?? null;
    const selectedRowIndex = () =>
      [...container.querySelectorAll("[data-inbox-item]")].findIndex((row) =>
        bandOf(row)?.className.split(/\s+/).includes("bg-accent/50"),
      );

    try {
      await act(async () => {
        root.render(
          <QueryClientProvider client={queryClient}>
            <Inbox />
          </QueryClientProvider>,
        );
      });
      await vi.waitFor(() => {
        expect(container.querySelectorAll("[data-inbox-item]").length).toBeGreaterThanOrEqual(3);
      });

      // Pointer physically moves, then hovers the middle row (index 1).
      await act(async () => {
        window.dispatchEvent(new MouseEvent("mousemove", { bubbles: true }));
        const rows = container.querySelectorAll("[data-inbox-item]");
        rows[1]!.dispatchEvent(new MouseEvent("mouseover", { bubbles: true }));
        rows[1]!.dispatchEvent(new MouseEvent("mouseenter", { bubbles: false }));
      });

      // A poll reshapes the list (row B's title changes → new nav array) before
      // the keypress. This is what used to null the hovered index and strand
      // j/k back at the top.
      apiMocks.issuesList.mockResolvedValue([issueA, { ...issueB, title: "Sync row B (updated)" }, issueC]);
      await act(async () => {
        await queryClient.invalidateQueries();
      });
      await vi.waitFor(() => {
        expect(container.textContent).toContain("Sync row B (updated)");
      });

      // j must continue from the hovered row (index 1) → index 2, not jump to
      // the top of the list.
      await act(async () => {
        document.body.dispatchEvent(new KeyboardEvent("keydown", { key: "j", bubbles: true }));
      });
      expect(selectedRowIndex()).toBe(2);
    } finally {
      act(() => {
        root.unmount();
      });
    }
  });

  it("holds the inbox order across a reordering poll, then re-sorts at an attention boundary (PAP-16015)", async () => {
    routerMock.location.pathname = "/inbox/mine";
    const base = new Date("2026-03-11T00:00:00.000Z").getTime();
    const issueA = createIssue({
      id: "issue-a",
      identifier: "PAP-3001",
      title: "Pin row A",
      lastActivityAt: new Date(base + 3000),
    });
    const issueB = createIssue({
      id: "issue-b",
      identifier: "PAP-3002",
      title: "Pin row B",
      lastActivityAt: new Date(base + 2000),
    });
    const issueC = createIssue({
      id: "issue-c",
      identifier: "PAP-3003",
      title: "Pin row C",
      lastActivityAt: new Date(base + 1000),
    });
    apiMocks.issuesList.mockResolvedValue([issueA, issueB, issueC]);

    const queryClient = new QueryClient({
      defaultOptions: { queries: { retry: false, staleTime: 0, gcTime: 0 } },
    });
    const root = createRoot(container);

    // Collapse each displayed row to its A/B/C identity so we can assert order.
    const orderOf = () =>
      [...container.querySelectorAll("[data-inbox-item]")].flatMap((row) => {
        const text = row.textContent ?? "";
        if (text.includes("Pin row A")) return ["A"];
        if (text.includes("Pin row B")) return ["B"];
        if (text.includes("Pin row C")) return ["C"];
        return [];
      });

    const visibilityDescriptor = Object.getOwnPropertyDescriptor(document, "visibilityState");
    const setVisibility = (state: DocumentVisibilityState) => {
      Object.defineProperty(document, "visibilityState", { configurable: true, get: () => state });
    };
    let nowValue = base + 1_000_000;
    const nowSpy = vi.spyOn(Date, "now").mockImplementation(() => nowValue);

    try {
      await act(async () => {
        root.render(
          <QueryClientProvider client={queryClient}>
            <Inbox />
          </QueryClientProvider>,
        );
      });
      await vi.waitFor(() => {
        expect(container.querySelectorAll("[data-inbox-item]").length).toBeGreaterThanOrEqual(3);
      });
      expect(orderOf()).toEqual(["A", "B", "C"]);

      // A poll makes row C the most-recently-active: the fresh sort is now [C, A, B].
      apiMocks.issuesList.mockResolvedValue([
        { ...issueA },
        { ...issueB },
        { ...issueC, lastActivityAt: new Date(base + 9000) },
      ]);
      await act(async () => {
        await queryClient.invalidateQueries();
      });
      await vi.waitFor(() => {
        expect(container.textContent).toContain("Pin row C");
      });

      // No attention boundary has fired, so the displayed order is held, not reshuffled.
      expect(orderOf()).toEqual(["A", "B", "C"]);

      // The tab is hidden long enough to lose attention, then regains focus: that
      // visibility boundary is a commit point, so the inbox adopts the fresh order.
      await act(async () => {
        setVisibility("hidden");
        document.dispatchEvent(new Event("visibilitychange"));
      });
      nowValue += 31_000;
      await act(async () => {
        setVisibility("visible");
        document.dispatchEvent(new Event("visibilitychange"));
      });
      await vi.waitFor(() => {
        expect(orderOf()).toEqual(["C", "A", "B"]);
      });
    } finally {
      nowSpy.mockRestore();
      if (visibilityDescriptor) {
        Object.defineProperty(document, "visibilityState", visibilityDescriptor);
      } else {
        setVisibility("visible");
      }
      act(() => {
        root.unmount();
      });
    }
  });

  it("keeps other issue archive controls enabled while one archive is pending", async () => {
    routerMock.location.pathname = "/inbox/mine";
    const issueA = createIssue({ id: "issue-a", identifier: "PAP-1001", title: "First inbox row" });
    const issueB = createIssue({ id: "issue-b", identifier: "PAP-1002", title: "Second inbox row" });
    apiMocks.issuesList.mockResolvedValue([issueA, issueB]);
    const archiveA = createDeferred<{ id: string; archivedAt: Date }>();
    apiMocks.archiveFromInbox.mockImplementation((id: string) =>
      id === "issue-a" ? archiveA.promise : Promise.resolve({ id, archivedAt: new Date() }),
    );

    const queryClient = new QueryClient({
      defaultOptions: { queries: { retry: false, staleTime: 0, gcTime: 0 } },
    });
    const root = createRoot(container);

    await act(async () => {
      root.render(
        <QueryClientProvider client={queryClient}>
          <Inbox />
        </QueryClientProvider>,
      );
    });
    await vi.waitFor(() => {
      expect(container.textContent).toContain("First inbox row");
      expect(container.textContent).toContain("Second inbox row");
    });

    const initialArchiveButtons = Array.from(
      container.querySelectorAll<HTMLButtonElement>('button[aria-label="Archive"]'),
    );
    expect(initialArchiveButtons.length).toBeGreaterThanOrEqual(2);

    await act(async () => {
      initialArchiveButtons[0]!.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
    });

    await vi.waitFor(() => {
      expect(apiMocks.archiveFromInbox).toHaveBeenCalledWith("issue-a");
      expect(container.textContent).not.toContain("First inbox row");
      expect(container.textContent).toContain("Second inbox row");
    });

    const remainingArchiveButton = container.querySelector<HTMLButtonElement>(
      'button[aria-label="Archive"]',
    );
    expect(remainingArchiveButton).not.toBeNull();
    expect(remainingArchiveButton?.disabled).toBe(false);

    await act(async () => {
      remainingArchiveButton!.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
    });

    await vi.waitFor(() => {
      expect(apiMocks.archiveFromInbox).toHaveBeenCalledWith("issue-b");
    });

    await act(async () => {
      archiveA.resolve({ id: "issue-a", archivedAt: new Date() });
    });

    act(() => {
      root.unmount();
    });
  });

  it("keeps a successful archive hidden when stale query data arrives", async () => {
    routerMock.location.pathname = "/inbox/mine";
    const archivedIssue = createIssue({
      id: "issue-a",
      identifier: "PAP-1001",
      title: "Archived inbox row",
    });
    apiMocks.issuesList.mockResolvedValue([archivedIssue]);

    const queryClient = new QueryClient({
      defaultOptions: { queries: { retry: false, staleTime: 0, gcTime: 0 } },
    });
    const root = createRoot(container);

    await act(async () => {
      root.render(
        <QueryClientProvider client={queryClient}>
          <Inbox />
        </QueryClientProvider>,
      );
    });
    await vi.waitFor(() => {
      expect(container.textContent).toContain("Archived inbox row");
    });

    const archiveButton = container.querySelector<HTMLButtonElement>('button[aria-label="Archive"]');
    expect(archiveButton).not.toBeNull();

    await act(async () => {
      archiveButton!.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
    });
    await vi.waitFor(() => {
      expect(apiMocks.archiveFromInbox).toHaveBeenCalledWith("issue-a");
      expect(container.textContent).not.toContain("Archived inbox row");
    });

    await act(async () => {
      queryClient.setQueriesData<Issue[]>(
        { queryKey: ["issues", "company-1", "mine-by-me"] },
        [archivedIssue],
      );
    });

    expect(container.textContent).not.toContain("Archived inbox row");

    act(() => {
      root.unmount();
    });
  });

  it("restores a locally hidden archive when undo is pressed", async () => {
    routerMock.location.pathname = "/inbox/mine";
    const archivedIssue = createIssue({
      id: "issue-a",
      identifier: "PAP-1001",
      title: "Undoable inbox row",
    });
    apiMocks.issuesList.mockResolvedValue([archivedIssue]);

    const queryClient = new QueryClient({
      defaultOptions: { queries: { retry: false, staleTime: 0, gcTime: 0 } },
    });
    const root = createRoot(container);

    try {
      await act(async () => {
        root.render(
          <QueryClientProvider client={queryClient}>
            <Inbox />
          </QueryClientProvider>,
        );
      });
      await vi.waitFor(() => {
        expect(container.textContent).toContain("Undoable inbox row");
      });

      const archiveButton = container.querySelector<HTMLButtonElement>('button[aria-label="Archive"]');
      expect(archiveButton).not.toBeNull();
      await act(async () => {
        archiveButton!.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
      });
      await vi.waitFor(() => {
        expect(container.textContent).not.toContain("Undoable inbox row");
        expect(queryClient.isMutating()).toBe(0);
      });

      await act(async () => {
        document.body.dispatchEvent(new KeyboardEvent("keydown", { key: "u", bubbles: true }));
      });
      await vi.waitFor(() => {
        expect(apiMocks.unarchiveFromInbox).toHaveBeenCalledWith("issue-a");
        expect(container.textContent).toContain("Undoable inbox row");
      });
    } finally {
      act(() => root.unmount());
    }
  });
});

describe("FailedRunInboxRow", () => {
  let container: HTMLDivElement;

  beforeEach(() => {
    container = document.createElement("div");
    document.body.appendChild(container);
  });

  afterEach(() => {
    container.remove();
  });

  it("suppresses accent hover styling when selected", () => {
    const root = createRoot(container);
    const run = createFailedRun();

    act(() => {
      root.render(
        <FailedRunInboxRow
          run={run}
          issueById={new Map()}
          agentName="Agent"
          issueLinkState={null}
          onDismiss={() => {}}
          onRetry={() => {}}
          isRetrying={false}
          selected
        />,
      );
    });

    const link = container.querySelector("a");
    expect(link).not.toBeNull();
    expect(link?.className).toContain("hover:bg-transparent");
    expect(link?.className).not.toContain("hover:bg-accent/50");

    act(() => {
      root.unmount();
    });
  });
});

describe("InboxIssueMetaLeading", () => {
  let container: HTMLDivElement;

  beforeEach(() => {
    container = document.createElement("div");
    document.body.appendChild(container);
  });

  afterEach(() => {
    container.remove();
  });

  it("keeps status and live accents visible", () => {
    const root = createRoot(container);

    act(() => {
      root.render(<InboxIssueMetaLeading issue={createIssue()} isLive />);
    });

    // The status glyph is an <svg> coloured from its --status-task-icon-* var.
    const statusIcon = Array.from(container.querySelectorAll("svg")).find((svg) =>
      (svg.getAttribute("style") ?? "").includes("--status-task-icon"),
    );
    const liveBadge = container.querySelector('span[class*="px-1.5"][class*="bg-blue-500/10"]');
    const liveBadgeLabel = Array.from(container.querySelectorAll("span")).find(
      // The pill chassis is a Badge (itself a span with textContent "Live");
      // the label is the inner span without the rounded-full chassis class.
      (node) => node.textContent === "Live" && node.className.includes("text-") && !node.className.includes("rounded-full"),
    );
    const liveDot = container.querySelector('span[class*="bg-blue-500"]');
    const pulseRing = container.querySelector('span[class*="animate-pulse"]');

    expect(statusIcon).not.toBeUndefined();
    // Status accent stays visible — not neutralized to muted.
    expect(statusIcon?.getAttribute("class") ?? "").not.toContain("!text-muted-foreground");
    expect(liveBadge).not.toBeNull();
    expect(liveBadge?.className).toContain("bg-blue-500/10");
    expect(liveBadgeLabel).not.toBeNull();
    expect(liveBadgeLabel?.className).toContain("text-blue-600");
    expect(liveDot).not.toBeNull();
    expect(pulseRing).not.toBeNull();

    act(() => {
      root.unmount();
    });
  });
});

describe("InboxIssueTrailingColumns", () => {
  let container: HTMLDivElement;

  beforeEach(() => {
    container = document.createElement("div");
    document.body.appendChild(container);
  });

  afterEach(() => {
    container.remove();
  });

  it("renders an empty tags cell when an issue has no labels", () => {
    const root = createRoot(container);

    act(() => {
      root.render(
        <InboxIssueTrailingColumns
          issue={createIssue({ labels: [], labelIds: [] })}
          columns={["labels"]}
          projectName={null}
          projectColor={null}
          workspaceName={null}
          assigneeName={null}
          currentUserId={null}
          parentIdentifier={null}
          parentTitle={null}
        />,
      );
    });

    expect(container.textContent).toBe("");

    act(() => {
      root.unmount();
    });
  });

  it("leaves the workspace cell blank when no explicit workspace label should be shown", () => {
    const root = createRoot(container);

    act(() => {
      root.render(
        <InboxIssueTrailingColumns
          issue={createIssue()}
          columns={["workspace"]}
          projectName={null}
          projectColor={null}
          workspaceName={null}
          assigneeName={null}
          currentUserId={null}
          parentIdentifier={null}
          parentTitle={null}
        />,
      );
    });

    expect(container.textContent).toBe("");

    act(() => {
      root.unmount();
    });
  });
});

describe("formatJoinRequestInboxLabel", () => {
  it("shows the human requester's name and email when available", () => {
    expect(formatJoinRequestInboxLabel(createJoinRequest())).toBe(
      "Jordan Example (joiner@example.com)",
    );
  });

  it("falls back to the email snapshot when the requester profile is missing", () => {
    expect(
      formatJoinRequestInboxLabel(
        createJoinRequest({
          requesterUser: null,
          requestEmailSnapshot: "snapshot@example.com",
          requestingUserId: null,
        }),
      ),
    ).toBe("snapshot@example.com");
  });
});

describe("InboxGroupHeader", () => {
  let container: HTMLDivElement;

  beforeEach(() => {
    container = document.createElement("div");
    document.body.appendChild(container);
  });

  afterEach(() => {
    container.remove();
  });

  it("shows a left caret and expanded state for collapsible mobile headers", () => {
    const root = createRoot(container);

    act(() => {
      root.render(<InboxGroupHeader label="Primary workspace (default)" collapsible collapsed={false} />);
    });

    const button = container.querySelector("button");
    expect(button).not.toBeNull();
    expect(button?.getAttribute("aria-expanded")).toBe("true");
    expect(button?.textContent).toContain("Primary workspace (default)");
    const caret = container.querySelector("svg");
    expect(caret?.className.baseVal).toContain("rotate-90");

    act(() => {
      root.unmount();
    });
  });

  it("keeps the caret collapsed when the mobile group is hidden", () => {
    const root = createRoot(container);

    act(() => {
      root.render(<InboxGroupHeader label="Feature Branch" collapsible collapsed />);
    });

    const button = container.querySelector("button");
    expect(button?.getAttribute("aria-expanded")).toBe("false");
    const caret = container.querySelector("svg");
    expect(caret?.className.baseVal).not.toContain("rotate-90");

    act(() => {
      root.unmount();
    });
  });
});
