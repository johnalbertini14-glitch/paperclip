import { useEffect, useMemo, useCallback, useRef, useState } from "react";
import type { ReactNode } from "react";
import { useLocation, useNavigate, useSearchParams } from "@/lib/router";
import { useInfiniteQuery, useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { issuesApi } from "../api/issues";
import { agentsApi } from "../api/agents";
import { projectsApi } from "../api/projects";
import { instanceSettingsApi } from "../api/instanceSettings";
import { heartbeatsApi } from "../api/heartbeats";
import { useCompany } from "../context/CompanyContext";
import { useBreadcrumbs } from "../context/BreadcrumbContext";
import { collectLiveIssueIds } from "../lib/liveIssueIds";
import { usePublishSharedQueryData, useSharedPollingQuery } from "@/hooks/useSharedPolling";
import { queryKeys } from "../lib/queryKeys";
import { createIssueDetailLocationState } from "../lib/issueDetailBreadcrumb";
import { EmptyState } from "../components/EmptyState";
import { IssuesList, loadInitialIssueViewState } from "../components/IssuesList";
import { TaskViewsMenu } from "../components/TaskViewsMenu";
import { Button } from "@/components/ui/button";
import { CircleDot, Plus } from "lucide-react";
import type { Issue } from "@paperclipai/shared";
import { useStreamlinedUiEnabled } from "../hooks/useStreamlinedUiEnabled";
import { useCombinedInboxTasksEnabled } from "../hooks/useCombinedInboxTasksEnabled";
import { useDialogActions } from "../context/DialogContext";
import { useInboxBadge } from "../hooks/useInboxBadge";
import { Inbox } from "./Inbox";
import {
  ORGANIZATION_SCOPED_PARAMS,
  TASK_VIEW_PARAM,
  loadLastTaskView,
  normalizeTaskViewKey,
  resolveInitialTaskView,
  saveLastTaskView,
  taskView,
  type TaskViewKey,
} from "../lib/task-views";

const ISSUES_PAGE_SIZE = 50;
export const ISSUES_ROW_PRESENTATION = "task" as const;
export const ISSUES_TOOLBAR_PRESENTATION = "collection" as const;

export function resolveIssuesPresentation(streamlinedUiEnabled: boolean) {
  return streamlinedUiEnabled
    ? { rowPresentation: ISSUES_ROW_PRESENTATION, toolbarPresentation: ISSUES_TOOLBAR_PRESENTATION }
    : { rowPresentation: "legacy" as const, toolbarPresentation: "legacy" as const };
}

export function getNextIssuesPageOffset(
  loadedPageSize: number,
  currentOffset: number,
  pageSize: number = ISSUES_PAGE_SIZE,
): number | undefined {
  return loadedPageSize >= pageSize ? currentOffset + pageSize : undefined;
}

export function mergeIssuePagesStable<T extends { id: string }>(pages: T[][]): T[] {
  const seenIssueIds = new Set<string>();
  const merged: T[] = [];

  for (const page of pages) {
    for (const issue of page) {
      if (seenIssueIds.has(issue.id)) continue;
      seenIssueIds.add(issue.id);
      merged.push(issue);
    }
  }

  return merged;
}

export function buildIssuesSearchUrl(currentHref: string, search: string): string | null {
  const url = new URL(currentHref);
  const currentSearch = url.searchParams.get("q") ?? "";
  if (currentSearch === search) return null;

  if (search.length > 0) {
    url.searchParams.set("q", search);
  } else {
    url.searchParams.delete("q");
  }

  return `${url.pathname}${url.search}${url.hash}`;
}

/**
 * Tasks — the single task surface after PAP-670 merged Inbox into it.
 *
 * This component only resolves `?view=` to a view and hands off: My-work views
 * render the inbox list, organization views render the task collection. Both
 * get the same Views control in their toolbar, so the switch reads as one page.
 */
export function Issues() {
  const { enabled: streamlinedUiEnabled } = useStreamlinedUiEnabled();
  const { enabled: combinedInboxTasksEnabled } = useCombinedInboxTasksEnabled();
  // The merged surface is Combined Inbox + Task List only. With the flag off, and always in
  // the legacy shell, Tasks is the plain task list and Inbox keeps its pages.
  return streamlinedUiEnabled && combinedInboxTasksEnabled ? <StreamlinedTasks /> : <OrganizationIssues />;
}

function StreamlinedTasks() {
  const navigate = useNavigate();
  const [searchParams, setSearchParams] = useSearchParams();
  const { selectedCompanyId } = useCompany();
  const { openNewIssue } = useDialogActions();
  const inboxBadge = useInboxBadge(selectedCompanyId);

  const requestedView = searchParams.get(TASK_VIEW_PARAM);
  const hasOrganizationScopedParam = ORGANIZATION_SCOPED_PARAMS.some(
    (param) => (searchParams.get(param) ?? "").length > 0,
  );
  // Read the stored view once per mount so a later write can't yank the view
  // out from under the user mid-session.
  const [lastUsedView] = useState<TaskViewKey>(() => loadLastTaskView());
  const view = resolveInitialTaskView(requestedView, hasOrganizationScopedParam, lastUsedView);
  const definition = taskView(view);

  // Make the resolved view addressable without dropping the params that
  // brought the user here — and correct a requested view that was overridden
  // (an inbox view carrying an organization filter opens All tasks).
  useEffect(() => {
    if (normalizeTaskViewKey(requestedView) === view) return;
    setSearchParams((current) => {
      const next = new URLSearchParams(current);
      next.set(TASK_VIEW_PARAM, view);
      return next;
    }, { replace: true });
  }, [requestedView, view, setSearchParams]);

  const selectView = useCallback((next: TaskViewKey) => {
    saveLastTaskView(next);
    // A view switch starts clean: the previous view's search and filters are
    // its own, not the new view's.
    navigate(`/issues?${TASK_VIEW_PARAM}=${next}`);
  }, [navigate]);

  const viewsMenu = (
    <TaskViewsMenu value={view} onChange={selectView} badgeCount={inboxBadge.inbox} />
  );

  if (definition.surface === "inbox") {
    return (
      <Inbox
        tab={definition.inboxTab}
        surfaceLabel="Tasks"
        toolbarContext={(
          <div className="flex min-w-0 items-center gap-2">
            {viewsMenu}
            <Button size="sm" variant="outline" aria-label="New Task" onClick={() => openNewIssue()}>
              <Plus className="h-4 w-4 sm:mr-1" />
              <span className="hidden sm:inline">New Task</span>
            </Button>
          </div>
        )}
      />
    );
  }

  return <OrganizationIssues toolbarContext={viewsMenu} initialStatuses={definition.statuses} />;
}

function OrganizationIssues({
  toolbarContext,
  initialStatuses,
}: { toolbarContext?: ReactNode; initialStatuses?: string[] } = {}) {
  const { enabled: streamlinedUiEnabled } = useStreamlinedUiEnabled();
  const issuesPresentation = resolveIssuesPresentation(streamlinedUiEnabled);
  const { selectedCompanyId } = useCompany();
  const { setBreadcrumbs } = useBreadcrumbs();
  const location = useLocation();
  const [searchParams] = useSearchParams();
  const queryClient = useQueryClient();
  const fetchNextPageInFlightRef = useRef(false);

  const urlSearch = searchParams.get("q") ?? "";
  const [searchOverride, setSearchOverride] = useState<{ search: string; locationSearch: string } | null>(null);
  const initialAssignees = searchParams.get("assignee") ? [searchParams.get("assignee")!] : undefined;
  const initialWorkspaces = searchParams.getAll("workspace").filter((workspaceId) => workspaceId.length > 0);
  const [scopedFilters, setScopedFilters] = useState(() => ({
    companyId: selectedCompanyId,
    ...loadInitialIssueViewState(selectedCompanyId, initialAssignees, initialWorkspaces.length ? initialWorkspaces : undefined, initialStatuses),
  }));
  // Reset before the first query for a newly selected company, not in an effect
  // after a request with the previous company's facets has already started.
  if (scopedFilters.companyId !== selectedCompanyId) {
    setScopedFilters({
      companyId: selectedCompanyId,
      ...loadInitialIssueViewState(selectedCompanyId, initialAssignees, initialWorkspaces.length ? initialWorkspaces : undefined, initialStatuses),
    });
  }
  const statusFilter = scopedFilters.statuses;
  const priorityFilter = scopedFilters.priorities;
  const labelFilter = scopedFilters.labels;
  const projectFilter = scopedFilters.projects;
  const workspaceFilter = scopedFilters.workspaces;
  const { data: experimentalSettings, isFetched: experimentalSettingsFetched } = useQuery({
    queryKey: queryKeys.instance.experimentalSettings,
    queryFn: () => instanceSettingsApi.getExperimental(),
    retry: false,
  });
  const externalObjectStatuses = experimentalSettings?.enableExternalObjects === true
    ? scopedFilters.externalObjectStatuses.join(",") : "";
  const liveOnly = scopedFilters.liveOnly === true;
  const hideRoutineExecutions = scopedFilters.hideRoutineExecutions;
  const creatorFilter = scopedFilters.creators;
  const createdByAny = creatorFilter.map((value) => value === "user:local-board" ? "user:me" : value).join(",");
  const assigneeFilter = scopedFilters.assignees;
  const [assigneeUserId, setAssigneeUserId] = useState<string | null>(null);
  const handleStatusFilterChange = useCallback((statuses: string[]) => {
    setScopedFilters((previous) => previous.statuses.join(",") === statuses.join(",") ? previous : { ...previous, statuses });
  }, []);
  const handlePriorityFilterChange = useCallback((priorities: string[]) => {
    setScopedFilters((previous) => previous.priorities.join(",") === priorities.join(",") ? previous : { ...previous, priorities });
  }, []);
  const handleLabelFilterChange = useCallback((labels: string[]) => {
    setScopedFilters((previous) => previous.labels.join(",") === labels.join(",") ? previous : { ...previous, labels });
  }, []);
  const handleProjectFilterChange = useCallback((projects: string[]) => {
    setScopedFilters((previous) => previous.projects.join(",") === projects.join(",") ? previous : { ...previous, projects });
  }, []);
  const handleWorkspaceFilterChange = useCallback((workspaces: string[]) => {
    setScopedFilters((previous) => previous.workspaces.join(",") === workspaces.join(",") ? previous : { ...previous, workspaces });
  }, []);
  const handleExternalObjectFilterChange = useCallback((statuses: string[]) => {
    setScopedFilters((previous) => previous.externalObjectStatuses.join(",") === statuses.join(",")
      ? previous : { ...previous, externalObjectStatuses: statuses });
  }, []);
  const handleCreatorFilterChange = useCallback((creators: string[]) => {
    setScopedFilters((previous) => previous.creators.join(",") === creators.join(",") ? previous : { ...previous, creators });
  }, []);
  const handleVisibilityFilterChange = useCallback((live: boolean, hideRoutine: boolean) => {
    setScopedFilters((previous) => previous.liveOnly === live && previous.hideRoutineExecutions === hideRoutine
      ? previous : { ...previous, liveOnly: live, hideRoutineExecutions: hideRoutine });
  }, []);
  const handleAssigneeFilterChange = useCallback((assignees: string[], currentUserId: string | null) => {
    setScopedFilters((previous) => previous.assignees.join(",") === assignees.join(",") ? previous : { ...previous, assignees });
    setAssigneeUserId(currentUserId);
  }, []);
  const resolvedAssignees = assigneeFilter.map((value) =>
    value === "__unassigned" ? "unassigned" : value === "__me"
      ? (assigneeUserId ? "user:me" : null) : `agent:${value}`);
  const assigneesReady = !assigneeFilter.includes("__me") || assigneeUserId !== null;
  const assigneeAny = resolvedAssignees.filter((value): value is string => value !== null).join(",");
  const syncedSearch = useMemo(() => {
    if (typeof window !== "undefined" && searchOverride?.locationSearch === window.location.search) {
      return searchOverride.search;
    }
    return urlSearch;
  }, [searchOverride, urlSearch, location.search]);
  const participantAgentId = searchParams.get("participantAgentId") ?? undefined;
  const workspaceIdFilter = initialWorkspaces.length === 1 ? initialWorkspaces[0] : undefined;
  const handleSearchChange = useCallback((search: string) => {
    const nextUrl = buildIssuesSearchUrl(window.location.href, search);
    if (!nextUrl) {
      setSearchOverride(null);
      return;
    }
    window.history.replaceState(window.history.state, "", nextUrl);
    setSearchOverride({ search, locationSearch: window.location.search });
  }, []);

  const { data: agents } = useQuery({
    queryKey: queryKeys.agents.list(selectedCompanyId!),
    queryFn: () => agentsApi.list(selectedCompanyId!),
    enabled: !!selectedCompanyId,
  });

  const { data: projects } = useQuery({
    queryKey: queryKeys.projects.list(selectedCompanyId!, { includeArchived: true }),
    queryFn: () => projectsApi.list(selectedCompanyId!, { includeArchived: true }),
    enabled: !!selectedCompanyId,
  });

  const liveRunsQueryKey = queryKeys.liveRuns(selectedCompanyId!);
  const sharedLiveRuns = useSharedPollingQuery({
    companyId: selectedCompanyId,
    resourceKey: "live-runs",
    queryKey: liveRunsQueryKey,
    enabled: !!selectedCompanyId,
    // Event-sourced via LiveUpdatesProvider (GitHub issue 9627); no interval poll needed.
    refetchInterval: false,
    leaderOnly: true,
  });
  const { data: liveRuns, dataUpdatedAt: liveRunsUpdatedAt } = useQuery({
    queryKey: liveRunsQueryKey,
    queryFn: () => heartbeatsApi.liveRunsForCompany(selectedCompanyId!),
    enabled: sharedLiveRuns.enabled,
    refetchInterval: sharedLiveRuns.refetchInterval,
  });
  usePublishSharedQueryData(sharedLiveRuns, liveRuns, liveRunsUpdatedAt);

  const issueLinkState = useMemo(
    () =>
      createIssueDetailLocationState(
        "Tasks",
        `${location.pathname}${location.search}${location.hash}`,
        "issues",
      ),
    [location.pathname, location.search, location.hash],
  );

  useEffect(() => {
    setBreadcrumbs([{ label: "Tasks" }]);
  }, [setBreadcrumbs]);

  const issuePageSize = ISSUES_PAGE_SIZE;

  const {
    data: issuePages,
    isLoading,
    isFetchingNextPage,
    error,
    hasNextPage,
    fetchNextPage,
  } = useInfiniteQuery({
    queryKey: [
      ...queryKeys.issues.list(selectedCompanyId!),
      "participant-agent",
      participantAgentId ?? "__all__",
      "workspace",
      workspaceIdFilter ?? "__all__",
      "compact",
      "with-routine-executions",
      "infinite",
      issuePageSize,
      "search",
      syncedSearch.trim(),
      "statuses",
      statusFilter.join(","),
      "priorities",
      priorityFilter.join(","),
      "labels",
      labelFilter.join(","),
      "projects",
      projectFilter.join(","),
      "workspaces",
      workspaceFilter.join(","),
      "external-object-statuses",
      externalObjectStatuses,
      "creators",
      createdByAny,
      "assignees",
      assigneeAny,
      "visibility",
      liveOnly,
      hideRoutineExecutions,
    ],
    queryFn: ({ pageParam, signal }) => issuesApi.listCompact(selectedCompanyId!, {
      ...(syncedSearch.trim() ? { q: syncedSearch.trim() } : {}),
      ...(statusFilter.length ? { status: statusFilter.join(",") } : {}),
      ...(priorityFilter.length ? { priorities: priorityFilter.join(",") } : {}),
      ...(labelFilter.length ? { labelIds: labelFilter.join(",") } : {}),
      ...(projectFilter.length ? { projectIds: projectFilter.join(",") } : {}),
      ...(workspaceFilter.length ? { workspaceIds: workspaceFilter.join(",") } : {}),
      ...(externalObjectStatuses ? { externalObjectStatuses } : {}),
      ...(createdByAny ? { createdByAny } : {}),
      ...(assigneeAny ? { assigneeAny } : {}),
      ...(liveOnly ? { liveOnly: true } : {}),
      ...(hideRoutineExecutions ? { excludeRoutineExecutions: true } : {}),
      participantAgentId,
      includeRoutineExecutions: true,
      limit: issuePageSize,
      offset: pageParam,
      sortField: "updated",
      sortDir: "desc",
    }, { signal }),
    initialPageParam: 0,
    getNextPageParam: (lastPage, _allPages, lastPageParam) =>
      getNextIssuesPageOffset(lastPage.length, lastPageParam, issuePageSize),
    enabled: !!selectedCompanyId && assigneesReady
      && (scopedFilters.externalObjectStatuses.length === 0 || experimentalSettingsFetched),
  });

  const issues = useMemo(() => mergeIssuePagesStable(issuePages?.pages ?? []) as Issue[], [issuePages]);
  const liveIssueIds = useMemo(() => collectLiveIssueIds(liveRuns, issues), [issues, liveRuns]);
  const hasMoreServerIssues = hasNextPage === true;
  const loadMoreServerIssues = useCallback(() => {
    if (!hasNextPage || isFetchingNextPage || fetchNextPageInFlightRef.current) return;
    fetchNextPageInFlightRef.current = true;
    void fetchNextPage({ cancelRefetch: false }).finally(() => {
      fetchNextPageInFlightRef.current = false;
    });
  }, [fetchNextPage, hasNextPage, isFetchingNextPage]);

  const updateIssue = useMutation({
    mutationFn: ({ id, data }: { id: string; data: Record<string, unknown> }) =>
      issuesApi.update(id, data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.issues.list(selectedCompanyId!) });
    },
  });

  if (!selectedCompanyId) {
    return (
      <EmptyState
        icon={CircleDot}
        message={streamlinedUiEnabled
          ? "Select an organization to view tasks."
          : "Select a company to view tasks."}
      />
    );
  }

  return (
    <IssuesList
      key={selectedCompanyId}
      issues={issues ?? []}
      isLoading={isLoading}
      isLoadingMoreIssues={isFetchingNextPage}
      error={error as Error | null}
      agents={agents}
      projects={projects}
      liveIssueIds={liveIssueIds}
      viewStateKey="paperclip:issues-view"
      rowPresentation={issuesPresentation.rowPresentation}
      toolbarPresentation={issuesPresentation.toolbarPresentation}
      issueLinkState={issueLinkState}
      initialAssignees={initialAssignees}
      initialWorkspaces={initialWorkspaces.length > 0 ? initialWorkspaces : undefined}
      initialStatuses={initialStatuses}
      toolbarContext={toolbarContext}
      initialSearch={syncedSearch}
      searchProvidedByParent
      onSearchChange={handleSearchChange}
      onStatusFilterChange={handleStatusFilterChange}
      onPriorityFilterChange={handlePriorityFilterChange}
      onLabelFilterChange={handleLabelFilterChange}
      onProjectFilterChange={handleProjectFilterChange}
      onWorkspaceFilterChange={handleWorkspaceFilterChange}
      onExternalObjectFilterChange={handleExternalObjectFilterChange}
      onCreatorFilterChange={handleCreatorFilterChange}
      onAssigneeFilterChange={handleAssigneeFilterChange}
      onVisibilityFilterChange={handleVisibilityFilterChange}
      enableRoutineVisibilityFilter
      hasMoreIssues={hasMoreServerIssues}
      onLoadMoreIssues={loadMoreServerIssues}
      onUpdateIssue={(id, data) => updateIssue.mutate({ id, data })}
      searchFilters={participantAgentId || workspaceIdFilter ? { participantAgentId, workspaceId: workspaceIdFilter } : undefined}
    />
  );
}
