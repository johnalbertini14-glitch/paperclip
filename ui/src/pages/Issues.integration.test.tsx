// @vitest-environment jsdom
import { act } from "react";
import { createRoot } from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { TooltipProvider } from "../components/ui/tooltip";
import { Issues } from "./Issues";

const state = vi.hoisted(() => ({ list: vi.fn(), search: "", companyId: "company-1", aborts: [] as AbortSignal[], realChild: false, workspacesEnabled: false, externalObjectsEnabled: false, agents: [] as { id: string; name: string }[], projects: [] as { id: string; name: string; workspaces?: { id: string; name: string }[] }[] }));
vi.mock("@/lib/router", () => ({
  useLocation: () => ({ pathname: "/issues", search: window.location.search, hash: "" }),
  useNavigate: () => vi.fn(),
  useSearchParams: () => [new URLSearchParams(window.location.search), vi.fn()],
  Link: ({ children, to }: { children: React.ReactNode; to: string }) => <a href={to}>{children}</a>,
}));
vi.mock("../api/issues", () => ({ issuesApi: { listCompact: state.list, listLabels: () => Promise.resolve([
  { id: "11111111-1111-4111-8111-111111111111", name: "Urgent", color: null },
  { id: "22222222-2222-4222-8222-222222222222", name: "Follow-up", color: null },
]) } }));
vi.mock("../api/agents", () => ({ agentsApi: { list: () => Promise.resolve(state.agents) } }));
vi.mock("../api/projects", () => ({ projectsApi: { list: () => Promise.resolve(state.projects) } }));
vi.mock("../api/auth", () => ({ authApi: { getSession: () => Promise.resolve({ user: { id: "local-board" } }) } }));
vi.mock("../api/access", () => ({ accessApi: {
  listMembers: () => Promise.resolve({ members: [], access: {} }),
  listUserDirectory: () => Promise.resolve({ users: [] }),
} }));
vi.mock("../api/execution-workspaces", () => ({ executionWorkspacesApi: {
  list: () => Promise.resolve([]), listSummaries: () => Promise.resolve([]),
} }));
vi.mock("../api/instanceSettings", () => ({ instanceSettingsApi: {
  getExperimental: () => Promise.resolve({ enableIsolatedWorkspaces: state.workspacesEnabled, enableExternalObjects: state.externalObjectsEnabled, enableStreamlinedUi: false }),
} }));
vi.mock("../api/externalObjects", () => ({ externalObjectsApi: { getIssueSummaries: () => Promise.resolve({ summaries: {} }) } }));
vi.mock("../api/heartbeats", () => ({ heartbeatsApi: { liveRunsForCompany: () => Promise.resolve([]) } }));
vi.mock("../context/CompanyContext", () => ({ useCompany: () => ({ selectedCompanyId: state.companyId }) }));
vi.mock("../context/BreadcrumbContext", () => ({ useBreadcrumbs: () => ({ setBreadcrumbs: vi.fn() }) }));
vi.mock("../context/DialogContext", () => ({ useDialogActions: () => ({ openNewIssue: vi.fn() }) }));
vi.mock("../hooks/useStreamlinedUiEnabled", () => ({ useStreamlinedUiEnabled: () => ({ enabled: state.realChild }) }));
vi.mock("../hooks/useCombinedInboxTasksEnabled", () => ({ useCombinedInboxTasksEnabled: () => ({ enabled: false }) }));
vi.mock("@/hooks/useSharedPolling", () => ({
  useSharedPollingQuery: () => ({ enabled: false, refetchInterval: false }),
  usePublishSharedQueryData: () => {},
}));
vi.mock("../components/IssuesList", async (importOriginal) => {
  const real = await importOriginal<typeof import("../components/IssuesList")>();
  return { ...real,
  IssuesList: (props: React.ComponentProps<typeof real.IssuesList>) => state.realChild
    ? <real.IssuesList {...props} />
    : <MockIssuesList {...props} />,
  };
});
function MockIssuesList({ issues, isLoading, initialSearch, onSearchChange, onStatusFilterChange, onPriorityFilterChange, onAssigneeFilterChange, hasMoreIssues, onLoadMoreIssues }: {
    issues: { title: string }[]; isLoading?: boolean; initialSearch?: string;
    onSearchChange?: (value: string) => void; onStatusFilterChange?: (statuses: string[]) => void;
    onPriorityFilterChange?: (priorities: string[]) => void;
    onAssigneeFilterChange?: (assignees: string[], currentUserId: string | null) => void;
    hasMoreIssues?: boolean; onLoadMoreIssues?: () => void;
  }) { return <div>
    <span data-testid="rows">{issues.map((issue) => issue.title).join(",")}</span>
    <span data-testid="loading">{String(isLoading)}</span>
    <span data-testid="search">{initialSearch}</span>
    <button onClick={() => onSearchChange?.(state.search)}>Search</button>
    <button onClick={() => onStatusFilterChange?.(["blocked", "todo"])}>Filter status</button>
    <button onClick={() => onPriorityFilterChange?.(["critical", "high"])}>Filter priority</button>
    <button onClick={() => onAssigneeFilterChange?.(["11111111-1111-4111-8111-111111111111", "__unassigned", "__me"], "22222222-2222-4222-8222-222222222222")}>Filter assignee</button>
    {hasMoreIssues && <button onClick={onLoadMoreIssues}>Load more</button>}
  </div>; }

// eslint-disable-next-line @typescript-eslint/no-explicit-any
(globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
const page = (prefix: string, count: number) => Array.from({ length: count }, (_, i) => ({ id: `${prefix}-${i}`, title: `${prefix}-${i}` }));
const defer = <T,>() => {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => { resolve = done; });
  return { promise, resolve };
};
async function flush() { await act(async () => { await new Promise((resolve) => setTimeout(resolve, 0)); }); }

describe("Tasks server-paged search integration", () => {
  let container: HTMLDivElement;
  let root: ReturnType<typeof createRoot>;
  let client: QueryClient;
  beforeEach(() => {
    window.history.replaceState(null, "", "/issues");
    localStorage.clear();
    state.search = "";
    state.companyId = "company-1";
    state.aborts = [];
    state.realChild = false;
    state.workspacesEnabled = false;
    state.externalObjectsEnabled = false;
    state.agents = [];
    state.projects = [];
    state.list.mockReset();
    container = document.createElement("div");
    document.body.appendChild(container);
    root = createRoot(container);
    client = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: 0 } } });
  });
  afterEach(() => { act(() => root.unmount()); client.clear(); container.remove(); });
  const rows = () => container.querySelector('[data-testid="rows"]')?.textContent ?? "";
  const click = async (label: string) => {
    const button = [...container.querySelectorAll("button")].find((el) => el.textContent === label);
    expect(button, `missing ${label}`).toBeTruthy();
    await act(async () => { button!.click(); });
    await flush();
  };
  it("finds an off-page result and continues searched pages with offset 50", async () => {
    state.list.mockImplementation((_company, params: { q?: string; offset: number }) => {
      if (!params.q) return Promise.resolve(page("ordinary", 50));
      if (params.offset === 0) return Promise.resolve(page("match", 50));
      return Promise.resolve([{ id: "off-page", title: "off-page target" }]);
    });
    await act(async () => root.render(<QueryClientProvider client={client}><Issues /></QueryClientProvider>));
    await flush();
    expect(rows()).toContain("ordinary-0");
    state.search = "target";
    await click("Search");
    expect(rows()).toContain("match-0");
    expect(rows()).not.toContain("ordinary-0");
    await click("Load more");
    expect(rows()).toContain("off-page target");
    expect(state.list.mock.calls.map(([, params]) => [params.q, params.limit, params.offset])).toEqual([
      [undefined, 50, 0], ["target", 50, 0], ["target", 50, 50],
    ]);
  });
  it("requests status OR before paging and switches away from unfiltered cached rows", async () => {
    state.list.mockImplementation((_company, params: { status?: string; offset: number }) => {
      if (!params.status) return Promise.resolve(page("unfiltered", 50));
      return Promise.resolve([{ id: "off-page-status", title: "off-page blocked target" }]);
    });
    await act(async () => root.render(<QueryClientProvider client={client}><Issues /></QueryClientProvider>));
    await flush();
    expect(rows()).toContain("unfiltered-0");
    await click("Filter status");
    expect(rows()).toBe("off-page blocked target");
    expect(state.list.mock.calls.map(([, params]) => [params.status, params.limit, params.offset])).toEqual([
      [undefined, 50, 0], ["blocked,todo", 50, 0],
    ]);
  });
  it("uses persisted status on the first server page without an unfiltered preload", async () => {
    localStorage.setItem("paperclip:issues-view:company-1", JSON.stringify({ statuses: ["blocked"] }));
    state.list.mockResolvedValue([{ id: "persisted", title: "persisted match" }]);
    await act(async () => root.render(<QueryClientProvider client={client}><Issues /></QueryClientProvider>));
    await flush();
    expect(rows()).toBe("persisted match");
    expect(state.list.mock.calls.map(([, params]) => [params.status, params.limit, params.offset])).toEqual([
      ["blocked", 50, 0],
    ]);
  });
  it("loads the new company's persisted facets on its first request without leaking old rows", async () => {
    localStorage.setItem("paperclip:issues-view:company-1", JSON.stringify({ statuses: ["blocked"], priorities: ["critical"] }));
    localStorage.setItem("paperclip:issues-view:company-2", JSON.stringify({ statuses: ["todo"], priorities: ["low"] }));
    state.list.mockImplementation((company: string) => Promise.resolve([{ id: company, title: company }]));
    await act(async () => root.render(<QueryClientProvider client={client}><Issues /></QueryClientProvider>));
    await flush();
    expect(rows()).toBe("company-1");
    state.companyId = "company-2";
    await act(async () => root.render(<QueryClientProvider client={client}><Issues /></QueryClientProvider>));
    await flush();
    expect(rows()).toBe("company-2");
    expect(state.list.mock.calls.map(([company, params]) => [company, params.status, params.priorities, params.limit, params.offset])).toEqual([
      ["company-1", "blocked", "critical", 50, 0],
      ["company-2", "todo", "low", 50, 0],
    ]);
  });
  it("aborts an in-flight search and never displays its late result for a newer query", async () => {
    // The query key also isolates priority and status changes from this search request.
    const old = defer<{ id: string; title: string }[]>();
    state.list.mockImplementation((_company, params: { q?: string }, options: { signal: AbortSignal }) => {
      if (params.q === "old") { state.aborts.push(options.signal); return old.promise; }
      return Promise.resolve(page(params.q ?? "ordinary", 1));
    });
    await act(async () => root.render(<QueryClientProvider client={client}><Issues /></QueryClientProvider>));
    await flush();
    state.search = "old";
    await click("Search");
    expect(rows()).not.toContain("ordinary-0");
    state.search = "new";
    await click("Search");
    expect(rows()).toBe("new-0");
    expect(state.aborts[0]?.aborted).toBe(true);
    await act(async () => { old.resolve([{ id: "stale", title: "stale-old" }]); });
    await flush();
    expect(rows()).toBe("new-0");
  });
  it("applies priority OR before paging and excludes the old unfiltered page", async () => {
    state.list.mockImplementation((_company, params: { priorities?: string }) =>
      Promise.resolve(params.priorities ? [{ id: "off-page", title: "off-page critical" }] : page("ordinary", 50)));
    await act(async () => root.render(<QueryClientProvider client={client}><Issues /></QueryClientProvider>));
    await flush();
    expect(rows()).toContain("ordinary-0");
    await click("Filter priority");
    expect(rows()).toBe("off-page critical");
    expect(state.list.mock.calls.map(([, params]) => [params.priorities, params.limit, params.offset])).toEqual([
      [undefined, 50, 0], ["critical,high", 50, 0],
    ]);
  });
  it("applies persisted priority on the first server request", async () => {
    localStorage.setItem("paperclip:issues-view:company-1", JSON.stringify({ priorities: ["critical"] }));
    state.list.mockResolvedValue([{ id: "persisted", title: "persisted critical" }]);
    await act(async () => root.render(<QueryClientProvider client={client}><Issues /></QueryClientProvider>));
    await flush();
    expect(rows()).toBe("persisted critical");
    expect(state.list.mock.calls.map(([, params]) => [params.priorities, params.limit, params.offset])).toEqual([
      ["critical", 50, 0],
    ]);
  });
  it("requests an off-page typed assignee OR match without retaining the old page", async () => {
    state.list.mockImplementation((_company, params: { assigneeAny?: string }) =>
      Promise.resolve(params.assigneeAny ? [{ id: "off-page", title: "off-page owner" }] : page("ordinary", 50)));
    await act(async () => root.render(<QueryClientProvider client={client}><Issues /></QueryClientProvider>));
    await flush();
    expect(rows()).toContain("ordinary-0");
    await click("Filter assignee");
    expect(rows()).toBe("off-page owner");
    expect(state.list.mock.calls.map(([, params]) => [params.assigneeAny, params.limit, params.offset])).toEqual([
      [undefined, 50, 0],
      ["agent:11111111-1111-4111-8111-111111111111,unassigned,user:me", 50, 0],
    ]);
  });
  it("does not preload an unfiltered page for a persisted Me selection", async () => {
    localStorage.setItem("paperclip:issues-view:company-1", JSON.stringify({ assignees: ["__me"] }));
    state.list.mockResolvedValue([{ id: "owned", title: "owned issue" }]);
    await act(async () => root.render(<QueryClientProvider client={client}><Issues /></QueryClientProvider>));
    await flush();
    expect(state.list).not.toHaveBeenCalled();
    await click("Filter assignee");
    expect(state.list.mock.calls.map(([, params]) => params.assigneeAny)).toEqual([
      "agent:11111111-1111-4111-8111-111111111111,unassigned,user:me",
    ]);
  });
  it("sends real Responsible clicks through the parent paged query and renders an off-page match", async () => {
    state.realChild = true;
    const agentId = "11111111-1111-4111-8111-111111111111";
    state.agents = [{ id: agentId, name: "Worker A" }];
    state.list.mockImplementation((_company, params: { assigneeAny?: string }) =>
      Promise.resolve(params.assigneeAny
        ? [{ id: "off-page", title: "off-page owner", status: "todo", priority: "medium", companyId: "company-1", labels: [], labelIds: [] }]
        : []));
    await act(async () => root.render(<QueryClientProvider client={client}><TooltipProvider><Issues /></TooltipProvider></QueryClientProvider>));
    await flush();
    const filter = container.querySelector<HTMLButtonElement>('button[title="Filter"]');
    expect(filter).not.toBeNull();
    await act(async () => { filter!.click(); });
    const responsible = document.querySelector('[data-filter-options="responsible"]');
    expect(responsible).not.toBeNull();
    const select = async (label: string) => {
      const option = [...responsible!.querySelectorAll("label")].find((item) => item.textContent?.trim() === label);
      expect(option, `missing ${label}`).toBeTruthy();
      await act(async () => { option!.click(); });
      await flush();
    };
    await select("Me");
    expect(state.list.mock.calls.at(-1)?.[1]).toMatchObject({ assigneeAny: "user:me", limit: 50, offset: 0 });
    await select("Worker A");
    expect(state.list.mock.calls.at(-1)?.[1]).toMatchObject({ assigneeAny: `user:me,agent:${agentId}`, limit: 50, offset: 0 });
    await select("No responsible");
    expect(state.list.mock.calls.at(-1)?.[1]).toMatchObject({ assigneeAny: `user:me,agent:${agentId},unassigned`, limit: 50, offset: 0 });
    expect(container.textContent).toContain("off-page owner");
    expect(state.list.mock.calls[0]?.[1]).toMatchObject({ limit: 50, offset: 0 });

  });
  it("sends real multi-label selections before the 50-row page and renders an off-page match", async () => {
    state.realChild = true;
    const first = "11111111-1111-4111-8111-111111111111";
    const second = "22222222-2222-4222-8222-222222222222";
    state.list.mockImplementation((_company, params: { labelIds?: string }) =>
      Promise.resolve(params.labelIds
        ? [{ id: "off-page", title: "off-page labelled", status: "todo", priority: "medium", companyId: "company-1", labels: [], labelIds: [first] }]
        : []));
    await act(async () => root.render(<QueryClientProvider client={client}><TooltipProvider><Issues /></TooltipProvider></QueryClientProvider>));
    await flush();
    const filter = container.querySelector<HTMLButtonElement>('button[title="Filter"]');
    expect(filter).not.toBeNull();
    await act(async () => { filter!.click(); });
    const options = document.querySelector('[data-filter-options="labels"]');
    expect(options).not.toBeNull();
    for (const [label, ids] of [["Urgent", first], ["Follow-up", `${first},${second}`]]) {
      const option = [...options!.querySelectorAll("label")].find((item) => item.textContent?.trim() === label);
      expect(option, `missing ${label}`).toBeTruthy();
      await act(async () => { option!.click(); });
      await flush();
      expect(state.list.mock.calls.at(-1)?.[1]).toMatchObject({ labelIds: ids, limit: 50, offset: 0 });
    }
    expect(container.textContent).toContain("off-page labelled");
  });
  it("uses persisted labels on the first page without an unfiltered request", async () => {
    const id = "11111111-1111-4111-8111-111111111111";
    localStorage.setItem("paperclip:issues-view:company-1", JSON.stringify({ labels: [id] }));
    state.list.mockResolvedValue([{ id: "labelled", title: "persisted label" }]);
    await act(async () => root.render(<QueryClientProvider client={client}><Issues /></QueryClientProvider>));
    await flush();
    expect(state.list.mock.calls.map(([, params]) => [params.labelIds, params.limit, params.offset])).toEqual([[id, 50, 0]]);
  });
  it("sends real multi-project selections before pagination and displays an off-page match", async () => {
    state.realChild = true;
    const first = "11111111-1111-4111-8111-111111111111";
    const second = "22222222-2222-4222-8222-222222222222";
    state.projects = [{ id: first, name: "Alpha project" }, { id: second, name: "Beta project" }];
    state.list.mockImplementation((_company, params: { projectIds?: string }) =>
      Promise.resolve(params.projectIds
        ? [{ id: "off-page-project", title: "off-page project match", projectId: first, status: "todo", priority: "medium", companyId: "company-1", labels: [], labelIds: [] }]
        : []));
    await act(async () => root.render(<QueryClientProvider client={client}><TooltipProvider><Issues /></TooltipProvider></QueryClientProvider>));
    await flush();
    const filter = container.querySelector<HTMLButtonElement>('button[title="Filter"]');
    expect(filter).not.toBeNull();
    await act(async () => { filter!.click(); });
    const options = document.querySelector('[data-filter-options="projects"]');
    expect(options).not.toBeNull();
    for (const [label, ids] of [["Alpha project", first], ["Beta project", `${first},${second}`]]) {
      const option = [...options!.querySelectorAll("label")].find((item) => item.textContent?.trim() === label);
      expect(option, `missing ${label}`).toBeTruthy();
      await act(async () => { option!.click(); });
      await flush();
      expect(state.list.mock.calls.at(-1)?.[1]).toMatchObject({ projectIds: ids, limit: 50, offset: 0 });
    }
    expect(container.textContent).toContain("off-page project match");
  });
  it("uses persisted projects in the first request without an unfiltered preload", async () => {
    const id = "11111111-1111-4111-8111-111111111111";
    localStorage.setItem("paperclip:issues-view:company-1", JSON.stringify({ projects: [id] }));
    state.list.mockResolvedValue([{ id: "project-match", title: "persisted project" }]);
    await act(async () => root.render(<QueryClientProvider client={client}><Issues /></QueryClientProvider>));
    await flush();
    expect(state.list.mock.calls.map(([, params]) => [params.projectIds, params.limit, params.offset])).toEqual([[id, 50, 0]]);
  });
  it("sends real creator selections before pagination and displays an off-page match", async () => {
    state.realChild = true;
    const agent = "11111111-1111-4111-8111-111111111111";
    state.agents = [{ id: agent, name: "Worker A" }];
    state.list.mockImplementation((_company, params: { createdByAny?: string }) =>
      Promise.resolve(params.createdByAny
        ? [{ id: "off-page-created", title: "off-page creator match", createdByAgentId: agent, status: "todo", priority: "medium", companyId: "company-1", labels: [], labelIds: [] }]
        : []));
    await act(async () => root.render(<QueryClientProvider client={client}><TooltipProvider><Issues /></TooltipProvider></QueryClientProvider>));
    await flush();
    const filter = container.querySelector<HTMLButtonElement>('button[title="Filter"]');
    expect(filter).not.toBeNull();
    await act(async () => { filter!.click(); });
    const options = document.querySelector('[data-filter-options="creators"]');
    expect(options).not.toBeNull();
    for (const [label, ids] of [["Worker A", `agent:${agent}`], ["Board", `agent:${agent},user:me`]]) {
      const option = [...options!.querySelectorAll("button")].find((item) => item.textContent?.trim() === label);
      expect(option, `missing ${label}`).toBeTruthy();
      await act(async () => { option!.click(); });
      await flush();
      expect(state.list.mock.calls.at(-1)?.[1]).toMatchObject({ createdByAny: ids, limit: 50, offset: 0 });
    }
    expect(container.textContent).toContain("off-page creator match");
  });
  it("uses persisted creators in the first request without an unfiltered preload", async () => {
    const agent = "11111111-1111-4111-8111-111111111111";
    localStorage.setItem("paperclip:issues-view:company-1", JSON.stringify({ creators: [`agent:${agent}`] }));
    state.list.mockResolvedValue([{ id: "created", title: "persisted creator" }]);
    await act(async () => root.render(<QueryClientProvider client={client}><Issues /></QueryClientProvider>));
    await flush();
    expect(state.list.mock.calls.map(([, params]) => [params.createdByAny, params.limit, params.offset])).toEqual([[`agent:${agent}`, 50, 0]]);
  });
  it("sends real visibility selections before pagination and shows an off-page live issue", async () => {
    state.realChild = true;
    state.list.mockImplementation((_company, params: { liveOnly?: boolean }) =>
      Promise.resolve(params.liveOnly
        ? [{ id: "live-off-page", title: "live off-page", status: "todo", priority: "medium", companyId: "company-1", originKind: "manual", labels: [], labelIds: [] }]
        : []));
    await act(async () => root.render(<QueryClientProvider client={client}><TooltipProvider><Issues /></TooltipProvider></QueryClientProvider>));
    await flush();
    const filter = container.querySelector<HTMLButtonElement>('button[title="Filter"]');
    expect(filter).not.toBeNull();
    await act(async () => { filter!.click(); });
    for (const [label, expected] of [
      ["Live runs only", { liveOnly: true }],
      ["Hide routine runs", { liveOnly: true, excludeRoutineExecutions: true }],
    ] as const) {
      const option = [...document.querySelectorAll("label")].find((item) => item.textContent?.trim() === label);
      expect(option, `missing ${label}`).toBeTruthy();
      await act(async () => { option!.click(); });
      await flush();
      expect(state.list.mock.calls.at(-1)?.[1]).toMatchObject({ ...expected, limit: 50, offset: 0 });
    }
    expect(container.textContent).toContain("live off-page");
  });
  it("uses persisted visibility on the first page without an unfiltered preload", async () => {
    localStorage.setItem("paperclip:issues-view:company-1", JSON.stringify({ liveOnly: true, hideRoutineExecutions: true }));
    state.list.mockResolvedValue([{ id: "live", title: "persisted live" }]);
    await act(async () => root.render(<QueryClientProvider client={client}><Issues /></QueryClientProvider>));
    await flush();
    expect(state.list.mock.calls.map(([, params]) => [params.liveOnly, params.excludeRoutineExecutions, params.limit, params.offset]))
      .toEqual([[true, true, 50, 0]]);
  });
  it("sends real multi-workspace selections before paging and shows a returned off-page match", async () => {
    state.realChild = true;
    state.workspacesEnabled = true;
    const first = "11111111-1111-4111-8111-111111111111";
    const second = "22222222-2222-4222-8222-222222222222";
    state.projects = [{ id: "33333333-3333-4333-8333-333333333333", name: "Alpha", workspaces: [
      { id: first, name: "One" }, { id: second, name: "Two" },
    ] }];
    state.list.mockImplementation((_company, params: { workspaceIds?: string }) =>
      Promise.resolve(params.workspaceIds
        ? [{ id: "off-page-workspace", title: "off-page workspace", projectWorkspaceId: first, status: "todo", priority: "medium", companyId: "company-1", labels: [], labelIds: [] }]
        : []));
    await act(async () => root.render(<QueryClientProvider client={client}><TooltipProvider><Issues /></TooltipProvider></QueryClientProvider>));
    await flush();
    const filter = container.querySelector<HTMLButtonElement>('button[title="Filter"]');
    expect(filter).not.toBeNull();
    await act(async () => { filter!.click(); });
    const options = document.querySelector('[data-filter-options="workspaces"]');
    expect(options).not.toBeNull();
    for (const [label, ids] of [["One", first], ["Two", `${first},${second}`]]) {
      const option = [...options!.querySelectorAll("label")].find((item) => item.textContent?.trim() === label);
      expect(option, `missing ${label}`).toBeTruthy();
      await act(async () => { option!.click(); });
      await flush();
      expect(state.list.mock.calls.at(-1)?.[1]).toMatchObject({ workspaceIds: ids, limit: 50, offset: 0 });
    }
    expect(container.textContent).toContain("off-page workspace");
  });
  it("uses persisted workspace IDs in its first request without an unfiltered preload", async () => {
    const id = "11111111-1111-4111-8111-111111111111";
    localStorage.setItem("paperclip:issues-view:company-1", JSON.stringify({ workspaces: [id] }));
    state.list.mockResolvedValue([{ id: "match", title: "persisted workspace" }]);
    await act(async () => root.render(<QueryClientProvider client={client}><Issues /></QueryClientProvider>));
    await flush();
    expect(state.list.mock.calls.map(([, params]) => [params.workspaceIds, params.limit, params.offset])).toEqual([[id, 50, 0]]);
  });
  it("sends real external-object selections before paging and shows an off-page result", async () => {
    state.realChild = true;
    state.externalObjectsEnabled = true;
    state.list.mockImplementation((_company, params: { externalObjectStatuses?: string }) => Promise.resolve(
      params.externalObjectStatuses
        ? [{ id: "off-page-external", title: "off-page external", status: "todo", priority: "medium", companyId: "company-1", labels: [], labelIds: [] }]
        : [],
    ));
    await act(async () => root.render(<QueryClientProvider client={client}><TooltipProvider><Issues /></TooltipProvider></QueryClientProvider>));
    await flush();
    const filter = container.querySelector<HTMLButtonElement>('button[title="Filter"]');
    expect(filter).not.toBeNull();
    await act(async () => { filter!.click(); });
    for (const [label, statuses] of [["Any failed", "failed"], ["No external objects", "failed,none"]]) {
      const option = [...document.querySelectorAll("label")].find((item) => item.textContent?.trim() === label);
      expect(option, `missing ${label}`).toBeTruthy();
      await act(async () => { option!.click(); });
      await flush();
      expect(state.list.mock.calls.at(-1)?.[1]).toMatchObject({ externalObjectStatuses: statuses, limit: 50, offset: 0 });
    }
    expect(container.textContent).toContain("off-page external");
  });
  it("uses persisted external-object statuses in its first request when the feature is enabled", async () => {
    state.externalObjectsEnabled = true;
    localStorage.setItem("paperclip:issues-view:company-1", JSON.stringify({ externalObjectStatuses: ["failed"] }));
    state.list.mockResolvedValue([{ id: "match", title: "persisted external" }]);
    await act(async () => root.render(<QueryClientProvider client={client}><Issues /></QueryClientProvider>));
    await flush();
    expect(state.list.mock.calls.map(([, params]) => [params.externalObjectStatuses, params.limit, params.offset]))
      .toEqual([["failed", 50, 0]]);
  });
  it("does not send a disabled persisted external-object facet", async () => {
    localStorage.setItem("paperclip:issues-view:company-1", JSON.stringify({ externalObjectStatuses: ["failed"] }));
    state.list.mockResolvedValue([]);
    await act(async () => root.render(<QueryClientProvider client={client}><Issues /></QueryClientProvider>));
    await flush();
    expect(state.list.mock.calls.map(([, params]) => [params.externalObjectStatuses, params.limit, params.offset]))
      .toEqual([[undefined, 50, 0]]);
  });
});
