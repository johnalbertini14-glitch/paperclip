import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import type { Agent, Issue } from "@paperclipai/shared";
import {
  ArrowRight,
  CheckSquare2,
  ChevronDown,
  CircleDot,
  Link2Off,
  Loader2,
  PauseCircle,
  Play,
  Plus,
  RefreshCw,
  Repeat2,
  Search,
  ShieldAlert,
} from "lucide-react";
import { Link } from "@/lib/router";
import { accessApi } from "../api/access";
import { activityApi } from "../api/activity";
import { attentionApi } from "../api/attention";
import { agentsApi } from "../api/agents";
import { approvalsApi } from "../api/approvals";
import { dashboardApi } from "../api/dashboard";
import { heartbeatsApi, type LiveRunForIssue } from "../api/heartbeats";
import { issuesApi } from "../api/issues";
import { projectsApi } from "../api/projects";
import { routinesApi } from "../api/routines";
import { ActivityRow } from "../components/ActivityRow";
import { ChartCard, IssueStatusChart, PriorityChart, RunActivityChart, SuccessRateChart } from "../components/ActivityCharts";
import { BoardAttentionSheet } from "../components/dashboard/BoardAttentionSheet";
import { EmptyState } from "../components/EmptyState";
import { PageSkeleton } from "../components/PageSkeleton";
import { PluginSlotOutlet } from "@/plugins/slots";
import { Button } from "../components/ui/button";
import { InlineBanner } from "../components/InlineBanner";
import { useBreadcrumbs } from "../context/BreadcrumbContext";
import { useCompany } from "../context/CompanyContext";
import { useDialogActions } from "../context/DialogContext";
import { useToastActions } from "../context/ToastContext";
import {
  buildBoardAttention,
  countStaleApprovals,
  meaningfulBoardActivity,
  nativeDecisionSourceKinds,
  nativeRecoverySourceKinds,
  type BoardAttentionItem,
  type BoardAttentionKind,
} from "../lib/dashboard-operations";
import { buildCompanyUserProfileMap } from "../lib/company-members";
import { queryKeys } from "../lib/queryKeys";
import { timeAgo } from "../lib/timeAgo";
import { cn } from "../lib/utils";

const ATTENTION_VISIBLE_LIMIT = 8;
const DASHBOARD_ACTIVITY_LIMIT = 10;
const ACTIVE_RUN_STATUSES = new Set(["queued", "running"]);

const attentionVisuals: Record<BoardAttentionKind, {
  label: string;
  icon: typeof CheckSquare2;
  iconClass: string;
}> = {
  decision: {
    label: "Board decision",
    icon: CheckSquare2,
    iconClass: "bg-amber-100 text-amber-700 dark:bg-amber-950/60 dark:text-amber-300",
  },
  recovery: {
    label: "Recovery required",
    icon: RefreshCw,
    iconClass: "bg-red-100 text-red-700 dark:bg-red-950/60 dark:text-red-300",
  },
  blocked: {
    label: "Blocked chain stalled",
    icon: Link2Off,
    iconClass: "bg-violet-100 text-violet-700 dark:bg-violet-950/60 dark:text-violet-300",
  },
  routine: {
    label: "Routine failure",
    icon: Repeat2,
    iconClass: "bg-sky-100 text-sky-700 dark:bg-sky-950/60 dark:text-sky-300",
  },
};

function messageForError(error: unknown): string {
  return error instanceof Error ? error.message : "The action could not be completed.";
}

function activityMaps(issues: Issue[], agents: Agent[], projects: { id: string; name: string }[]) {
  const entityNameMap = new Map<string, string>();
  const entityTitleMap = new Map<string, string>();
  for (const issue of issues) {
    entityNameMap.set(`issue:${issue.id}`, issue.identifier ?? issue.id.slice(0, 8));
    entityTitleMap.set(`issue:${issue.id}`, issue.title);
  }
  for (const agent of agents) entityNameMap.set(`agent:${agent.id}`, agent.name);
  for (const project of projects) entityNameMap.set(`project:${project.id}`, project.name);
  return { entityNameMap, entityTitleMap };
}

function openCommandPalette() {
  document.dispatchEvent(new KeyboardEvent("keydown", {
    key: "k",
    metaKey: true,
    bubbles: true,
    cancelable: true,
  }));
}

interface QuickActionProps {
  icon: typeof Plus;
  title: string;
  description: string;
  shortcut: string;
  primary?: boolean;
  tone?: "amber" | "red" | "violet";
  onClick: () => void;
}

function QuickAction({ icon: Icon, title, description, shortcut, primary, tone, onClick }: QuickActionProps) {
  const toneClass = tone === "amber"
    ? "bg-amber-100 text-amber-700 dark:bg-amber-950/60 dark:text-amber-300"
    : tone === "red"
      ? "bg-red-100 text-red-700 dark:bg-red-950/60 dark:text-red-300"
      : tone === "violet"
        ? "bg-violet-100 text-violet-700 dark:bg-violet-950/60 dark:text-violet-300"
        : "bg-emerald-100 text-emerald-800 dark:bg-emerald-950/60 dark:text-emerald-200";

  return (
    <button
      type="button"
      onClick={onClick}
      className={cn(
        "group grid min-h-[74px] min-w-[244px] snap-start grid-cols-[40px_minmax(0,1fr)_auto] items-center gap-3 rounded-xl border px-3 text-left shadow-sm transition hover:-translate-y-0.5 hover:shadow-md md:min-w-0",
        primary
          ? "border-emerald-800 bg-emerald-800 text-white hover:bg-emerald-700 dark:border-emerald-700 dark:bg-emerald-800"
          : "border-border bg-card hover:border-emerald-700/30",
      )}
    >
      <span className={cn("grid h-10 w-10 place-items-center rounded-lg", primary ? "bg-white/15 text-white" : toneClass)}>
        <Icon className="h-5 w-5" />
      </span>
      <span className="min-w-0">
        <strong className="block truncate text-sm">{title}</strong>
        <small className={cn("mt-0.5 block truncate text-xs", primary ? "text-emerald-50/75" : "text-muted-foreground")}>{description}</small>
      </span>
      <kbd className={cn(
        "grid min-h-6 min-w-6 place-items-center rounded border px-1.5 text-[10px] font-semibold",
        primary ? "border-white/20 bg-white/10 text-white" : "border-border bg-muted/50 text-muted-foreground",
      )}>{shortcut}</kbd>
    </button>
  );
}

function agentModel(agent: Agent): string | null {
  const value = agent.adapterConfig?.model;
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : null;
}

export type PausedAgentBanner =
  | { kind: "imported"; pausedImportedAgentIds: string[] }
  | { kind: "all-paused" }
  | null;

// Upstream #12142 (kept on the v2026.916.0 base): import-paused agents get a
// specific banner; a company whose agents are all paused gets a generic one.
export function derivePausedAgentBanner(agents: Agent[] | undefined): PausedAgentBanner {
  if (!agents || agents.length === 0) return null;
  const importedPaused = agents.filter((agent) => agent.status === "paused" && agent.pauseReason === "import");
  if (importedPaused.length > 0) {
    return { kind: "imported", pausedImportedAgentIds: importedPaused.map((agent) => agent.id) };
  }
  if (agents.every((agent) => agent.status === "paused")) return { kind: "all-paused" };
  return null;
}

function ownerLabel(item: BoardAttentionItem, agents: Map<string, Agent>): string {
  const agentId = item.issue?.assigneeAgentId ?? item.approval?.requestedByAgentId ?? item.routine?.assigneeAgentId ?? null;
  return agentId ? agents.get(agentId)?.name ?? "Assigned agent" : item.issue?.blockedInboxAttention?.owner.label ?? "Board";
}

function activeRunForAgent(runs: LiveRunForIssue[], agentId: string): LiveRunForIssue | null {
  return runs.find((run) => run.agentId === agentId && ACTIVE_RUN_STATUSES.has(run.status)) ?? null;
}

export function dashboardAttentionPage(cursor: string | null, filter: "all" | BoardAttentionKind = "all") {
  return {
    limit: 50,
    ...(!cursor ? { dashboardCounts: true } : {}),
    ...(cursor ? { cursor } : {}),
    ...(filter === "all" ? { sourceKinds: [...nativeDecisionSourceKinds, ...nativeRecoverySourceKinds] } : {}),
    ...(filter === "decision" ? { sourceKinds: nativeDecisionSourceKinds } : {}),
    ...(filter === "recovery" ? { sourceKinds: nativeRecoverySourceKinds } : {}),
  };
}

export function dashboardBlockedPage(offset: number, filter: "all" | BoardAttentionKind = "all") {
  return { attention: "blocked" as const, ...(filter === "recovery" || filter === "blocked" || filter === "decision" ? { dashboardKind: filter } : {}), includeBlockedBy: true, includeBlockedInboxAttention: true, limit: 50, offset };
}

export function dashboardNextAttentionPage(loadedMatches: number, visibleLimit: number, hasAttentionCursor: boolean, hasBlockedPage: boolean, filter: "all" | BoardAttentionKind, hasRoutinePage = false, hasApprovalPage = false) {
  if (loadedMatches > visibleLimit) return "reveal";
  if (filter === "routine") return hasRoutinePage ? "routine" : null;
  if (filter === "decision" && hasApprovalPage) return "approval";
  // Native feed rows map to decisions or recoveries, never the Blocked tab.
  if (filter === "blocked") return hasBlockedPage ? "blocked" : null;
  if (hasAttentionCursor) return "attention";
  if (hasBlockedPage) return "blocked";
  if (filter === "all" && hasApprovalPage) return "approval";
  if (filter === "all" && hasRoutinePage) return "routine";
  return null;
}

export function Dashboard() {
  const { selectedCompanyId, companies } = useCompany();
  const { openNewIssue, openOnboarding } = useDialogActions();
  const { setBreadcrumbs } = useBreadcrumbs();
  const { pushToast } = useToastActions();
  const queryClient = useQueryClient();
  const attentionRef = useRef<HTMLElement | null>(null);
  const [filter, setFilter] = useState<"all" | BoardAttentionKind>("all");
  const [visibleLimit, setVisibleLimit] = useState(ATTENTION_VISIBLE_LIMIT);
  const [selectedIssue, setSelectedIssue] = useState<Issue | null>(null);
  const [analyticsOpen, setAnalyticsOpen] = useState(false);

  useEffect(() => {
    setBreadcrumbs([{ label: "Board operations" }]);
  }, [setBreadcrumbs]);

  const companyId = selectedCompanyId ?? "";
  const summaryQuery = useQuery({
    queryKey: queryKeys.dashboard(companyId),
    queryFn: () => dashboardApi.summary(companyId),
    enabled: Boolean(companyId),
  });
  const agentsQuery = useQuery({
    queryKey: queryKeys.agents.list(companyId),
    queryFn: () => agentsApi.list(companyId),
    enabled: Boolean(companyId),
  });
  const blockedQuery = useInfiniteQuery({
    queryKey: [...queryKeys.issues.listBlockedAttention(companyId), { boardOperationsPages: true, filter }],
    queryFn: ({ pageParam, signal }) => issuesApi.list(companyId, dashboardBlockedPage(pageParam, filter), { signal }),
    initialPageParam: 0,
    getNextPageParam: (lastPage, pages) => lastPage.length === 50 ? pages.length * 50 : undefined,
    enabled: Boolean(companyId) && filter !== "routine",
  });
  const blockedCountQuery = useQuery({
    queryKey: [...queryKeys.issues.listBlockedAttention(companyId), "blocked-exact-count"],
    queryFn: ({ signal }) => issuesApi.count(companyId, { attention: "blocked", dashboardKind: "blocked" }, { signal }),
    enabled: Boolean(companyId) && filter === "blocked",
  });
  useEffect(() => {
    if (filter === "routine" && companyId) {
      void queryClient.cancelQueries({ queryKey: [...queryKeys.issues.listBlockedAttention(companyId), { boardOperationsPages: true, filter: "all" }], exact: true });
    }
  }, [companyId, filter, queryClient]);
  const approvalsQuery = useInfiniteQuery({
    queryKey: [...queryKeys.approvals.list(companyId, "pending"), { boardOperationsPages: true }],
    queryFn: ({ pageParam, signal }) => approvalsApi.list(companyId, "pending", { limit: 50, offset: pageParam }, { signal }),
    initialPageParam: 0,
    getNextPageParam: (lastPage, pages) => lastPage.length === 50 ? pages.length * 50 : undefined,
    enabled: Boolean(companyId) && (filter === "all" || filter === "decision"),
  });
  const pendingApprovalsCountQuery = useQuery({
    queryKey: [...queryKeys.approvals.list(companyId, "pending"), "exact-count"],
    queryFn: ({ signal }) => approvalsApi.count(companyId, "pending", { signal }),
    enabled: Boolean(companyId) && (filter === "all" || filter === "decision"),
  });
  const attentionQuery = useInfiniteQuery({
    queryKey: [...queryKeys.attention(companyId), { boardOperations: true, filter }],
    queryFn: ({ pageParam, signal }) => attentionApi.list(companyId, dashboardAttentionPage(pageParam, filter), { signal }),
    initialPageParam: null as string | null,
    getNextPageParam: (lastPage) => lastPage.nextCursor ?? undefined,
    enabled: Boolean(companyId) && (filter === "all" || filter === "decision" || filter === "recovery"),
  });
  const routinesQuery = useInfiniteQuery({
    queryKey: [...queryKeys.routines.list(companyId), { boardOperationsPages: true, failedLatest: filter === "routine" }],
    queryFn: ({ pageParam, signal }) => routinesApi.list(companyId, { limit: 50, offset: pageParam, ...(filter === "routine" ? { failedLatest: true } : {}) }, { signal }),
    initialPageParam: 0,
    getNextPageParam: (lastPage, pages) => lastPage.length === 50 ? pages.length * 50 : undefined,
    enabled: Boolean(companyId) && (filter === "all" || filter === "routine"),
  });
  const routineCountQuery = useQuery({
    queryKey: [...queryKeys.routines.list(companyId), "failed-latest-count"],
    queryFn: ({ signal }) => routinesApi.count(companyId, { failedLatest: true }, { signal }),
    enabled: Boolean(companyId) && (filter === "all" || filter === "routine"),
  });
  useEffect(() => {
    if (filter !== "all" && filter !== "routine" && companyId) {
      void queryClient.cancelQueries({ queryKey: queryKeys.routines.list(companyId) });
    }
  }, [companyId, filter, queryClient]);
  const liveRunsQuery = useQuery({
    queryKey: queryKeys.liveRuns(companyId),
    queryFn: () => heartbeatsApi.liveRunsForCompany(companyId, { minCount: 20, limit: 20 }),
    enabled: Boolean(companyId),
    refetchInterval: 10_000,
  });
  const activityQuery = useQuery({
    queryKey: [...queryKeys.activity(companyId), { limit: DASHBOARD_ACTIVITY_LIMIT, boardOperations: true }],
    queryFn: ({ signal }) => activityApi.list(companyId, { limit: DASHBOARD_ACTIVITY_LIMIT }, { signal }),
    enabled: Boolean(companyId),
  });
  const pulseAgents = useMemo(() => (agentsQuery.data ?? [])
    .map((agent) => ({ agent, run: activeRunForAgent(liveRunsQuery.data ?? [], agent.id) }))
    .sort((left, right) => {
      const leftScore = (left.run ? 100 : 0) + (left.agent.status === "error" ? 60 : 0);
      const rightScore = (right.run ? 100 : 0) + (right.agent.status === "error" ? 60 : 0);
      return rightScore - leftScore;
    })
    .slice(0, 4), [agentsQuery.data, liveRunsQuery.data]);
  const meaningfulActivity = useMemo(() => meaningfulBoardActivity(activityQuery.data ?? [], 4), [activityQuery.data]);
  const contextIssueIds = useMemo(() => [...new Set([
    ...pulseAgents.flatMap(({ run }) => run?.issueId ? [run.issueId] : []),
    ...meaningfulActivity.flatMap((event) => event.entityType === "issue" && event.entityId ? [event.entityId] : []),
  ])], [pulseAgents, meaningfulActivity]);
  const contextIssuesQuery = useQuery({
    queryKey: ["dashboard", "board-operations", "context-issue-ids", companyId, contextIssueIds],
    queryFn: async ({ signal }) => {
      const results = await Promise.allSettled(contextIssueIds.map((id) => issuesApi.get(id, { signal })));
      if (signal.aborted) throw new DOMException("Dashboard issue request aborted", "AbortError");
      return results.flatMap((result) => result.status === "fulfilled" ? [result.value] : []);
    },
    enabled: Boolean(companyId) && contextIssueIds.length > 0,
  });
  const projectsQuery = useQuery({
    queryKey: queryKeys.projects.list(companyId),
    queryFn: () => projectsApi.list(companyId),
    enabled: Boolean(companyId) && Boolean(activityQuery.data?.length),
  });
  const membersQuery = useQuery({
    queryKey: queryKeys.access.companyUserDirectory(companyId),
    queryFn: () => accessApi.listUserDirectory(companyId),
    enabled: Boolean(companyId) && Boolean(activityQuery.data?.length),
  });

  const agents = agentsQuery.data ?? [];
  const issues = contextIssuesQuery.data ?? [];
  const approvals = approvalsQuery.data?.pages.flat() ?? [];
  const routines = routinesQuery.data?.pages.flat() ?? [];
  const liveRuns = liveRunsQuery.data ?? [];
  const agentMap = useMemo(() => new Map(agents.map((agent) => [agent.id, agent])), [agents]);
  const issueMap = useMemo(() => new Map(issues.map((issue) => [issue.id, issue])), [issues]);
  const attentionItems = useMemo(() => buildBoardAttention({
    approvals,
    blockedIssues: blockedQuery.data?.pages.flat() ?? [],
    routines,
    attention: attentionQuery.data?.pages.flatMap((page) => page.items),
  }), [approvals, blockedQuery.data?.pages, routines, attentionQuery.data?.pages]);
  const attentionCounts = useMemo(() => ({
    all: attentionItems.length,
    decision: attentionItems.filter((item) => item.kind === "decision").length,
    recovery: attentionItems.filter((item) => item.kind === "recovery").length,
    blocked: attentionItems.filter((item) => item.kind === "blocked").length,
    routine: attentionItems.filter((item) => item.kind === "routine").length,
  }), [attentionItems]);
  const routineTotal = filter === "routine" ? routineCountQuery.data?.count : undefined;
  const blockedTotal = filter === "blocked" ? blockedCountQuery.data?.count : undefined;
  const composite = attentionQuery.data?.pages[0]?.dashboardCounts;
  const exactCounts = composite && pendingApprovalsCountQuery.data && routineCountQuery.data
    ? {
      decision: composite.decision + pendingApprovalsCountQuery.data.count,
      recovery: composite.recovery,
      blocked: composite.blocked,
      routine: routineCountQuery.data.count,
    }
    : null;
  const selectedTotal = filter === "blocked" ? blockedTotal
    : filter === "routine" ? routineTotal
      : filter === "decision" && composite && pendingApprovalsCountQuery.data
        ? composite.decision + pendingApprovalsCountQuery.data.count
        : filter === "recovery" ? composite?.recovery
          : filter === "all" && exactCounts
            ? exactCounts.decision + exactCounts.recovery + exactCounts.blocked + exactCounts.routine
            : undefined;
  const visibleAttention = useMemo(() => attentionItems
    .filter((item) => filter === "all" || item.kind === filter)
    .slice(0, visibleLimit), [attentionItems, filter, visibleLimit]);
  const nextAttentionPage = dashboardNextAttentionPage(
    attentionItems.filter((item) => filter === "all" || item.kind === filter).length,
    visibleLimit, Boolean(attentionQuery.hasNextPage), Boolean(blockedQuery.hasNextPage), filter, Boolean(routinesQuery.hasNextPage), Boolean(approvalsQuery.hasNextPage),
  );
  const staleApprovalCount = useMemo(() => countStaleApprovals(approvals), [approvals]);
  const userProfileMap = useMemo(() => buildCompanyUserProfileMap(membersQuery.data?.users), [membersQuery.data?.users]);
  const { entityNameMap, entityTitleMap } = useMemo(
    () => activityMaps(issues, agents, projectsQuery.data ?? []),
    [issues, agents, projectsQuery.data],
  );
  const failedRoutines = useMemo(() => attentionItems.filter((item) => item.kind === "routine").slice(0, 3), [attentionItems]);
  const agentPulse = useMemo(() => pulseAgents
    .map(({ agent, run }) => {
      const currentIssue = run?.issueId ? issueMap.get(run.issueId) ?? null : null;
      return { agent, run, currentIssue };
    }), [pulseAgents, issueMap]);

  const selectFilter = useCallback((nextFilter: "all" | BoardAttentionKind) => {
    setFilter(nextFilter);
    setVisibleLimit(ATTENTION_VISIBLE_LIMIT);
    window.setTimeout(() => attentionRef.current?.scrollIntoView({ behavior: "smooth", block: "start" }), 0);
  }, []);

  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      const target = event.target;
      const typing = target instanceof HTMLInputElement
        || target instanceof HTMLTextAreaElement
        || target instanceof HTMLSelectElement
        || (target instanceof HTMLElement && target.isContentEditable);
      if (typing || event.metaKey || event.ctrlKey || event.altKey) return;
      const key = event.key.toLowerCase();
      if (key === "n") openNewIssue({ status: "todo" });
      if (key === "a") selectFilter("decision");
      if (key === "r") selectFilter("recovery");
      if (key === "u") selectFilter("blocked");
    }
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [openNewIssue, selectFilter]);

  const routineRunMutation = useMutation({
    mutationFn: (routineId: string) => routinesApi.run(routineId),
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: queryKeys.routines.list(companyId) });
      pushToast({ title: "Routine queued", body: "A new run has been requested.", tone: "success" });
    },
    onError: (error) => pushToast({ title: "Routine failed to start", body: messageForError(error), tone: "error" }),
  });
  const retryMutation = useMutation({
    mutationFn: (issueId: string) => issuesApi.retryScheduledRetryNow(issueId),
    onSuccess: async (result) => {
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: queryKeys.issues.listBlockedAttention(companyId) }),
        queryClient.invalidateQueries({ queryKey: ["dashboard", "board-operations", "context-issue-ids", companyId] }),
      ]);
      pushToast({ title: "Recovery checked", body: result.message, tone: result.outcome === "gate_suppressed" ? "warn" : "success" });
    },
    onError: (error) => pushToast({ title: "Retry failed", body: messageForError(error), tone: "error" }),
  });

  function attentionAction(item: BoardAttentionItem) {
    if (item.issue?.scheduledRetry) {
      retryMutation.mutate(item.issue.id);
      return;
    }
    if (item.issue) {
      setSelectedIssue(item.issue);
      return;
    }
    if (item.routine) routineRunMutation.mutate(item.routine.id);
  }

  if (!selectedCompanyId) {
    if (companies.length === 0) {
      return (
        <EmptyState
          icon={CircleDot}
          message="Welcome to Paperclip. Set up your first company and agent to get started."
          action="Get Started"
          onAction={openOnboarding}
        />
      );
    }
    return <EmptyState icon={CircleDot} message="Create or select a company to view Board operations." />;
  }

  if (summaryQuery.isLoading || agentsQuery.isLoading) return <PageSkeleton variant="dashboard" />;

  const summary = summaryQuery.data;
  const loadError = summaryQuery.error ?? agentsQuery.error ?? contextIssuesQuery.error ?? blockedQuery.error ?? approvalsQuery.error ?? routinesQuery.error;
  const runningCount = summary?.agents.running ?? liveRuns.filter((run) => ACTIVE_RUN_STATUSES.has(run.status)).length;
  const blockedCount = summary?.tasks.blocked ?? issues.filter((issue) => issue.status === "blocked").length;
  const pausedBanner = derivePausedAgentBanner(agentsQuery.data);
  const dateLabel = new Intl.DateTimeFormat(undefined, { weekday: "long", month: "long", day: "numeric" }).format(new Date());

  return (
    <div className="mx-auto w-full max-w-[1500px] space-y-7 pb-12">
      {loadError ? (
        <div className="rounded-lg border border-destructive/25 bg-destructive/5 px-4 py-3 text-sm text-destructive">
          {messageForError(loadError)}
        </div>
      ) : null}

      {pausedBanner ? (
        <InlineBanner
          tone="warning"
          icon={PauseCircle}
          title={pausedBanner.kind === "imported"
            ? `${pausedBanner.pausedImportedAgentIds.length} imported agent${pausedBanner.pausedImportedAgentIds.length === 1 ? " is" : "s are"} paused and will not run.`
            : "All agents in this organization are paused — nothing will run."}
          actions={<Button variant="ghost" size="sm" asChild><Link to="/agents/all">Review agents</Link></Button>}
        >
          Resume at least one agent to let assigned tasks start.
        </InlineBanner>
      ) : null}

      <header className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <p className="text-[11px] font-semibold uppercase tracking-[0.12em] text-muted-foreground">{dateLabel}</p>
          <h1 className="mt-1 text-3xl font-semibold tracking-tight text-foreground">Board operations</h1>
        </div>
        <button
          type="button"
          onClick={openCommandPalette}
          className="flex min-h-11 w-full items-center gap-3 rounded-xl border bg-card px-3 text-left text-sm text-muted-foreground shadow-sm transition hover:border-emerald-700/30 hover:text-foreground sm:w-[min(430px,44vw)]"
        >
          <Search className="h-4 w-4" />
          <span className="min-w-0 flex-1 truncate">Search or run a command</span>
          <kbd className="rounded border bg-muted/60 px-1.5 py-0.5 text-[10px] font-semibold">⌘ K</kbd>
        </button>
      </header>

      <section className="flex flex-col gap-4 rounded-2xl border border-emerald-800/20 bg-emerald-50/70 px-4 py-4 dark:bg-emerald-950/25 sm:flex-row sm:items-center sm:justify-between sm:px-5">
        <div className="flex min-w-0 items-start gap-3">
          <span className="mt-1 h-3 w-3 shrink-0 rounded-full bg-emerald-700 shadow-[0_0_0_5px_rgba(4,120,87,0.13)]" />
          <div className="min-w-0">
            <strong className="block text-sm">
              {attentionItems.length > 0
                ? `${attentionItems.length} loaded item${attentionItems.length === 1 ? "" : "s"} ${attentionItems.length === 1 ? "needs" : "need"} Board attention.`
                : "No Board attention items in the loaded queue."}
            </strong>
            <p className="mt-0.5 text-xs leading-5 text-muted-foreground">
              System noise is filtered. Only decisions, stopped work, recovery, and failed automation appear here.
            </p>
          </div>
        </div>
        <div className="flex max-w-full gap-2 overflow-x-auto pb-1 sm:justify-end sm:pb-0">
          <span className="whitespace-nowrap rounded-lg border bg-background/75 px-2.5 py-1.5 text-xs"><b>{runningCount}</b> running</span>
          <span className="whitespace-nowrap rounded-lg border bg-background/75 px-2.5 py-1.5 text-xs"><b>{blockedCount}</b> blocked</span>
          <span className="whitespace-nowrap rounded-lg border bg-background/75 px-2.5 py-1.5 text-xs"><b>{staleApprovalCount}</b> stale approvals loaded</span>
          {pendingApprovalsCountQuery.data ? <span className="whitespace-nowrap rounded-lg border bg-background/75 px-2.5 py-1.5 text-xs"><b>{pendingApprovalsCountQuery.data.count}</b> pending approvals total</span> : null}
        </div>
      </section>

      {summary && summary.budgets.activeIncidents > 0 ? (
        <section className="flex items-start justify-between gap-3 rounded-xl border border-red-500/25 bg-red-50/75 px-4 py-3 dark:bg-red-950/25">
          <div className="flex items-start gap-2.5">
            <ShieldAlert className="mt-0.5 h-4 w-4 shrink-0 text-red-700 dark:text-red-300" />
            <div>
              <p className="text-sm font-medium">{summary.budgets.activeIncidents} active budget incident{summary.budgets.activeIncidents === 1 ? "" : "s"}</p>
              <p className="text-xs text-muted-foreground">{summary.budgets.pausedAgents} agents and {summary.budgets.pausedProjects} projects paused</p>
            </div>
          </div>
          <Link to="/costs" className="text-xs font-semibold text-red-700 hover:underline dark:text-red-300">Open budgets</Link>
        </section>
      ) : null}

      <section aria-labelledby="quick-actions-title">
        <div className="mb-3 flex items-end justify-between gap-4">
          <div>
            <p className="text-[10px] font-bold uppercase tracking-[0.15em] text-emerald-700 dark:text-emerald-300">Act</p>
            <h2 id="quick-actions-title" className="mt-0.5 text-2xl font-semibold tracking-tight">Quick actions</h2>
          </div>
          <span className="hidden text-xs text-muted-foreground sm:block">Shortcuts work without leaving the dashboard</span>
        </div>
        <div className="flex snap-x gap-2 overflow-x-auto pb-2 md:grid md:grid-cols-2 xl:grid-cols-4 md:overflow-visible md:pb-0">
          <QuickAction icon={Plus} title="Create and assign" description="Start work with an owner" shortcut="N" primary onClick={() => openNewIssue({ status: "todo" })} />
          <QuickAction icon={CheckSquare2} title="Review decisions" description={`${attentionCounts.decision} in the loaded queue`} shortcut="A" tone="amber" onClick={() => selectFilter("decision")} />
          <QuickAction icon={RefreshCw} title="Recover stalled work" description="Retry failed or timed-out work" shortcut="R" tone="red" onClick={() => selectFilter("recovery")} />
          <QuickAction icon={Link2Off} title="Reassign or unblock" description="Clear ownership and dependency jams" shortcut="U" tone="violet" onClick={() => selectFilter("blocked")} />
        </div>
      </section>

      <div className="grid items-start gap-4 xl:grid-cols-[minmax(0,1.65fr)_minmax(300px,.72fr)]">
        <section ref={attentionRef} className="min-w-0 overflow-hidden rounded-2xl border bg-card shadow-sm" aria-labelledby="attention-title">
          <div className="flex flex-col gap-4 border-b px-4 py-5 sm:px-5 lg:flex-row lg:items-end lg:justify-between">
            <div>
              <p className="text-[10px] font-bold uppercase tracking-[0.15em] text-emerald-700 dark:text-emerald-300">Decide</p>
              <h2 id="attention-title" className="mt-0.5 text-2xl font-semibold tracking-tight">Needs Board attention</h2>
              <p className="mt-1 text-xs text-muted-foreground">Ranked by consequence, urgency, and how much work is waiting behind it.</p>
            </div>
            <div className="flex max-w-full gap-1 overflow-x-auto rounded-xl bg-muted/55 p-1" role="group" aria-label="Attention queue filters">
              {(["all", "decision", "recovery", "blocked", "routine"] as const).map((kind) => (
                <button
                  key={kind}
                  type="button"
                  onClick={() => selectFilter(kind)}
                  className={cn(
                    "min-h-10 whitespace-nowrap rounded-lg px-3 text-xs font-semibold capitalize transition sm:min-h-8",
                    filter === kind ? "bg-background text-foreground shadow-sm" : "text-muted-foreground hover:text-foreground",
                  )}
                  aria-pressed={filter === kind}
                >
                  {kind === "all" ? "All" : kind === "decision" ? "Decisions" : kind === "routine" ? "Automation" : kind}
                  <span className="ml-1 text-[10px] opacity-70" aria-label={kind === filter && selectedTotal !== undefined ? `${selectedTotal} total` : `${attentionCounts[kind]} loaded`}>{kind === filter && selectedTotal !== undefined ? selectedTotal : attentionCounts[kind]}</span>
                </button>
              ))}
            </div>
          </div>

          {staleApprovalCount > 0 ? (
            <div className="mx-3 mt-3 grid grid-cols-[22px_minmax(0,1fr)] items-center gap-3 rounded-xl border border-amber-500/35 bg-amber-50 px-3 py-3 text-amber-950 dark:bg-amber-950/30 dark:text-amber-100 sm:mx-4 sm:grid-cols-[22px_minmax(0,1fr)_auto]">
              <ShieldAlert className="h-5 w-5 text-amber-700 dark:text-amber-300" />
              <div className="min-w-0">
                <strong className="block text-sm">{staleApprovalCount} governance decision{staleApprovalCount === 1 ? " is" : "s are"} stale</strong>
                <span className="block text-xs opacity-75">Grouped here instead of occupying the full dashboard.</span>
              </div>
              <Button asChild variant="outline" size="sm" className="col-start-2 min-h-10 w-max border-amber-500/40 bg-white/55 sm:col-start-auto">
                <Link to="/approvals">Review queue</Link>
              </Button>
            </div>
          ) : null}

          <div className="px-3 pb-2 pt-2 sm:px-4">
            {visibleAttention.length === 0 ? (
              <div className="grid min-h-48 place-items-center px-4 text-center">
                <div>
                  <CircleDot className="mx-auto h-7 w-7 text-emerald-700 dark:text-emerald-300" />
                  <p className="mt-2 text-sm font-medium">{nextAttentionPage
                    ? `More ${filter === "decision" ? "decisions" : filter === "all" ? "items" : `${filter} items`} may be on the next page.`
                    : ((filter === "all" || filter === "decision" || filter === "recovery") && attentionQuery.isPending)
                      || (filter !== "routine" && blockedQuery.isPending)
                      || ((filter === "all" || filter === "decision") && approvalsQuery.isPending)
                      || ((filter === "all" || filter === "routine") && routinesQuery.isPending)
                      || (filter === "routine" && routineCountQuery.isPending)
                      || (filter === "blocked" && blockedCountQuery.isPending)
                      ? "Loading Board attention…"
                      : ((filter === "all" || filter === "decision" || filter === "recovery") && attentionQuery.isError)
                        || (filter !== "routine" && blockedQuery.isError)
                        || ((filter === "all" || filter === "decision") && approvalsQuery.isError)
                        || ((filter === "all" || filter === "routine") && routinesQuery.isError)
                        || (filter === "routine" && routineCountQuery.isError)
                        || (filter === "blocked" && blockedCountQuery.isError)
                        ? "Could not load the complete attention queue."
                        : selectedTotal !== undefined && selectedTotal > 0
                          ? `${selectedTotal} ${filter === "all" ? "" : `${filter} `}item${selectedTotal === 1 ? "" : "s"} ${selectedTotal === 1 ? "exists" : "exist"} outside the loaded page.`
                          : `No ${filter === "all" ? "" : `${filter} `}items in the loaded queue.`}</p>
                  <p className="mt-1 text-xs text-muted-foreground">{nextAttentionPage ? "Load more to check the remaining queue." : "The queue updates as work, approvals, and routines change."}</p>
                </div>
              </div>
            ) : visibleAttention.map((item, index) => {
              const visual = attentionVisuals[item.kind];
              const Icon = visual.icon;
              const itemOwner = ownerLabel(item, agentMap);
              return (
                <article key={item.id} className="grid min-w-0 grid-cols-[38px_minmax(0,1fr)] gap-3 border-b px-1 py-4 last:border-b-0 sm:grid-cols-[28px_38px_minmax(0,1fr)_auto] sm:px-0">
                  <span className="hidden pt-2 text-xs tabular-nums text-muted-foreground sm:block">{String(index + 1).padStart(2, "0")}</span>
                  <span className={cn("grid h-9 w-9 place-items-center rounded-xl", visual.iconClass)}><Icon className="h-4 w-4" /></span>
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-2 text-[10px] font-bold uppercase tracking-[0.08em] text-muted-foreground">
                      <span>{visual.label}</span>
                      <span className={cn(
                        "border-l pl-2",
                        item.severity === "critical" || item.severity === "high" ? "text-red-600 dark:text-red-300" : "text-amber-700 dark:text-amber-300",
                      )}>{timeAgo(item.occurredAt)}</span>
                    </div>
                    <h3 className="mt-1 text-sm font-semibold leading-5">{item.title}</h3>
                    <p className="mt-1 line-clamp-2 text-xs leading-5 text-muted-foreground">{item.description}</p>
                    <div className="mt-2 flex flex-wrap items-center gap-2 text-[11px] text-muted-foreground">
                      <span className="font-medium text-foreground/75">{itemOwner}</span>
                      {item.issue?.blockedBy?.length ? <span>· {item.issue.blockedBy.length} blocker{item.issue.blockedBy.length === 1 ? "" : "s"}</span> : null}
                      {(item.issue?.identifier ?? item.identifier) ? <span>· {item.issue?.identifier ?? item.identifier}</span> : null}
                    </div>
                  </div>
                  <div className="col-start-2 flex items-center gap-2 pt-1 sm:col-start-auto sm:pt-6">
                    {item.href && !item.issue && !item.routine ? (
                      <Button asChild variant="outline" size="sm" className="min-h-10">
                        <Link to={item.href}>{item.actionLabel}</Link>
                      </Button>
                    ) : item.approval ? (
                      <Button asChild variant="outline" size="sm" className="min-h-10">
                        <Link to={`/approvals/${item.approval.id}`}>Review</Link>
                      </Button>
                    ) : (
                      <Button
                        type="button"
                        variant="outline"
                        size="sm"
                        className="min-h-10"
                        onClick={() => attentionAction(item)}
                        disabled={Boolean(
                          (item.routine && routineRunMutation.isPending && routineRunMutation.variables === item.routine.id)
                          || (item.issue?.scheduledRetry && retryMutation.isPending && retryMutation.variables === item.issue.id)
                        )}
                      >
                        {(item.routine && routineRunMutation.isPending && routineRunMutation.variables === item.routine.id)
                          || (item.issue?.scheduledRetry && retryMutation.isPending && retryMutation.variables === item.issue.id)
                          ? <Loader2 className="h-4 w-4 animate-spin" />
                          : null}
                        {item.actionLabel}
                      </Button>
                    )}
                    {item.issue ? (
                      <Button type="button" variant="ghost" size="icon" className="h-10 w-10" aria-label={`Open ${item.issue.identifier ?? item.issue.title} context`} onClick={() => setSelectedIssue(item.issue)}>
                        <ArrowRight className="h-4 w-4" />
                      </Button>
                    ) : item.routine ? (
                      <Button asChild variant="ghost" size="icon" className="h-10 w-10">
                        <Link to={`/routines/${item.routine.id}`} aria-label={`Open ${item.routine.title}`}><ArrowRight className="h-4 w-4" /></Link>
                      </Button>
                    ) : null}
                  </div>
                </article>
              );
            })}
          </div>
          {nextAttentionPage ? (
            <Button type="button" variant="ghost" className="w-full min-h-12 border-t" disabled={attentionQuery.isFetchingNextPage || blockedQuery.isFetchingNextPage || routinesQuery.isFetchingNextPage || approvalsQuery.isFetchingNextPage} onClick={() => {
              if (nextAttentionPage === "attention") void attentionQuery.fetchNextPage();
              else if (nextAttentionPage === "blocked") void blockedQuery.fetchNextPage();
              else if (nextAttentionPage === "routine") void routinesQuery.fetchNextPage();
              else if (nextAttentionPage === "approval") void approvalsQuery.fetchNextPage();
              setVisibleLimit((current) => current + ATTENTION_VISIBLE_LIMIT);
            }}>
              {attentionQuery.isFetchingNextPage || blockedQuery.isFetchingNextPage || routinesQuery.isFetchingNextPage || approvalsQuery.isFetchingNextPage ? "Loading more attention…" : "Load more attention"}
            </Button>
          ) : null}
          {attentionQuery.isFetchNextPageError || blockedQuery.isFetchNextPageError || routinesQuery.isFetchNextPageError || approvalsQuery.isFetchNextPageError ? (
            <p role="alert" className="p-3 text-xs text-destructive">Could not load more attention. Retry above.</p>
          ) : null}
          {attentionItems.length > ATTENTION_VISIBLE_LIMIT ? (
            <Link to="/inbox/blocked" className="flex min-h-12 items-center justify-center gap-2 border-t bg-muted/25 text-xs font-semibold text-muted-foreground hover:text-foreground">
              Open the full attention inbox <ArrowRight className="h-4 w-4" />
            </Link>
          ) : null}
        </section>

        <aside className="grid min-w-0 gap-4 md:grid-cols-2 xl:grid-cols-1" aria-label="Compact company health">
          <section className="rounded-2xl border bg-card p-4 shadow-sm">
            <div className="flex items-start justify-between gap-3">
              <div>
                <p className="text-[10px] font-bold uppercase tracking-[0.15em] text-emerald-700 dark:text-emerald-300">Monitor</p>
                <h2 className="mt-0.5 text-xl font-semibold tracking-tight">Agent pulse</h2>
              </div>
              <Link to="/agents/all" className="min-h-10 py-2 text-xs font-semibold text-emerald-700 hover:underline dark:text-emerald-300">All agents</Link>
            </div>
            <div className="mt-4 flex items-baseline justify-between gap-3 border-y py-3">
              <strong className="text-2xl">{runningCount} running</strong>
              <span className="text-xs text-muted-foreground">{agents.filter((agent) => agent.status === "error").length} need attention</span>
            </div>
            <div className="divide-y">
              {agentPulse.map(({ agent, run, currentIssue }) => (
                <Link key={agent.id} to={`/agents/${agent.urlKey}`} className="grid min-h-14 grid-cols-[32px_minmax(0,1fr)_auto] items-center gap-2 py-2 text-sm hover:bg-muted/25">
                  <span className="grid h-8 w-8 place-items-center rounded-full bg-muted text-[10px] font-bold">{agent.name.split(/\s+/).map((part) => part[0]).join("").slice(0, 2)}</span>
                  <span className="min-w-0">
                    <strong className="block truncate text-xs">{agent.name}</strong>
                    <small className="block truncate text-[10px] text-muted-foreground">
                      {run?.currentStatusMessage ?? currentIssue?.title ?? agent.status}
                    </small>
                    {agentModel(agent) ? (
                      <small className="block truncate text-[10px] text-muted-foreground/70">{agentModel(agent)}</small>
                    ) : null}
                  </span>
                  <span className={cn(
                    "rounded-full px-2 py-1 text-[9px] font-bold",
                    run ? "bg-emerald-100 text-emerald-800 dark:bg-emerald-950/50 dark:text-emerald-200"
                      : agent.status === "error" ? "bg-red-100 text-red-700 dark:bg-red-950/50 dark:text-red-200"
                        : "bg-muted text-muted-foreground",
                  )}>{run ? "Working" : agent.status === "error" ? "Attention" : agent.status}</span>
                </Link>
              ))}
            </div>
          </section>

          <section className="rounded-2xl border bg-card p-4 shadow-sm">
            <div className="flex items-start justify-between gap-3">
              <div>
                <p className="text-[10px] font-bold uppercase tracking-[0.15em] text-emerald-700 dark:text-emerald-300">Automate</p>
                <h2 className="mt-0.5 text-xl font-semibold tracking-tight">Failures requiring action</h2>
              </div>
              <span className="rounded-full bg-red-100 px-2 py-1 text-[10px] font-bold text-red-700 dark:bg-red-950/50 dark:text-red-200">{attentionCounts.routine} loaded</span>
            </div>
            <div className="mt-3 divide-y">
              {failedRoutines.length === 0 ? (
                <div className="py-6 text-center text-xs text-muted-foreground">No routine failures require intervention.</div>
              ) : failedRoutines.map((item) => (
                <div key={item.id} className="flex min-h-14 items-center justify-between gap-3 py-2">
                  <div className="min-w-0">
                    <strong className="block truncate text-xs">{item.title}</strong>
                    <small className="block truncate text-[10px] text-muted-foreground">{item.description}</small>
                  </div>
                  <Button
                    type="button"
                    variant="ghost"
                    size="icon"
                    className="h-10 w-10 shrink-0"
                    aria-label={`Run ${item.title} now`}
                    onClick={() => item.routine && routineRunMutation.mutate(item.routine.id)}
                    disabled={Boolean(item.routine && routineRunMutation.isPending && routineRunMutation.variables === item.routine.id)}
                  >
                    {item.routine && routineRunMutation.isPending && routineRunMutation.variables === item.routine.id
                      ? <Loader2 className="h-4 w-4 animate-spin" />
                      : <Play className="h-4 w-4" />}
                  </Button>
                </div>
              ))}
            </div>
          </section>

          <section className="rounded-2xl border bg-card p-4 shadow-sm md:col-span-2 xl:col-span-1">
            <div className="flex items-start justify-between gap-3">
              <div>
                <p className="text-[10px] font-bold uppercase tracking-[0.15em] text-emerald-700 dark:text-emerald-300">Understand</p>
                <h2 className="mt-0.5 text-xl font-semibold tracking-tight">Since your last check</h2>
              </div>
              <span className="rounded-lg border bg-muted/45 px-2 py-1 text-[9px] font-semibold text-muted-foreground">Noise filtered</span>
            </div>
            <div className="mt-3 divide-y overflow-hidden rounded-lg border">
              {meaningfulActivity.length === 0 ? (
                <div className="p-4 text-xs text-muted-foreground">No recent operational changes.</div>
              ) : meaningfulActivity.map((event) => (
                <ActivityRow
                  key={event.id}
                  event={event}
                  agentMap={agentMap}
                  userProfileMap={userProfileMap}
                  entityNameMap={entityNameMap}
                  entityTitleMap={entityTitleMap}
                  className="px-3 py-2.5"
                />
              ))}
            </div>
          </section>
        </aside>
      </div>

      <PluginSlotOutlet
        slotTypes={["dashboardWidget"]}
        context={{ companyId }}
        className="grid gap-4 md:grid-cols-2"
        itemClassName="rounded-xl border bg-card p-4 shadow-sm"
      />

      {summary ? (
        <section className="overflow-hidden rounded-2xl border bg-card shadow-sm">
          <button
            type="button"
            onClick={() => setAnalyticsOpen((open) => !open)}
            className="flex min-h-20 w-full items-center justify-between gap-4 px-4 py-4 text-left sm:px-5"
            aria-expanded={analyticsOpen}
            aria-controls="dashboard-operational-trends"
          >
            <span>
              <span className="block text-[10px] font-bold uppercase tracking-[0.15em] text-emerald-700 dark:text-emerald-300">Analyze</span>
              <strong className="mt-0.5 block text-lg">Operational trends</strong>
              <small className="mt-0.5 block text-xs text-muted-foreground">Hidden by default. Task charts show the latest loaded page, not company totals.</small>
            </span>
            <span className="flex items-center gap-2 text-xs font-semibold text-muted-foreground">
              <span className="hidden sm:inline">{analyticsOpen ? "Hide" : "Show"} analytics</span>
              <ChevronDown className={cn("h-5 w-5 transition-transform", analyticsOpen && "rotate-180")} />
            </span>
          </button>
          {analyticsOpen ? (
            <div id="dashboard-operational-trends" className="grid gap-4 border-t p-4 sm:grid-cols-2 xl:grid-cols-4">
              <ChartCard title="Run Activity" subtitle="Last 14 days"><RunActivityChart activity={summary.runActivity} /></ChartCard>
              <ChartCard title="Tasks by Priority" subtitle="Open work"><PriorityChart issues={issues} /></ChartCard>
              <ChartCard title="Tasks by Status" subtitle="Open work"><IssueStatusChart issues={issues} /></ChartCard>
              <ChartCard title="Success Rate" subtitle="Last 14 days"><SuccessRateChart activity={summary.runActivity} /></ChartCard>
            </div>
          ) : null}
        </section>
      ) : null}

      <BoardAttentionSheet
        companyId={companyId}
        issue={selectedIssue}
        agents={agents}
        open={selectedIssue !== null}
        onOpenChange={(open) => { if (!open) setSelectedIssue(null); }}
      />
    </div>
  );
}
