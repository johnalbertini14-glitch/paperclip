import { useEffect, useMemo, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import type {
  Agent,
  Issue,
  IssueBlockedInboxIssueRef,
  IssueRelationIssueSummary,
} from "@paperclipai/shared";
import { ArrowRight, ChevronLeft, Loader2, MessageSquareText, RefreshCw, UserRoundCog } from "lucide-react";
import { Link } from "@/lib/router";
import { agentsApi } from "../../api/agents";
import { issuesApi } from "../../api/issues";
import { useSidebar } from "../../context/SidebarContext";
import { useToastActions } from "../../context/ToastContext";
import { queryKeys } from "../../lib/queryKeys";
import { timeAgo } from "../../lib/timeAgo";
import { Button } from "../ui/button";
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetFooter,
  SheetHeader,
  SheetTitle,
} from "../ui/sheet";
import { Textarea } from "../ui/textarea";

interface BoardAttentionSheetProps {
  companyId: string;
  issue: Issue | null;
  agents: Agent[];
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

interface IssuePathEntry {
  id: string;
  identifier: string | null;
  title: string;
}

function pathEntry(issue: Issue | IssueRelationIssueSummary | IssueBlockedInboxIssueRef): IssuePathEntry {
  return {
    id: issue.id,
    identifier: issue.identifier,
    title: issue.title,
  };
}

function messageForError(error: unknown): string {
  return error instanceof Error ? error.message : "The action could not be completed.";
}

export function BoardAttentionSheet({
  companyId,
  issue,
  agents,
  open,
  onOpenChange,
}: BoardAttentionSheetProps) {
  const { isMobile } = useSidebar();
  const { pushToast } = useToastActions();
  const queryClient = useQueryClient();
  const [instruction, setInstruction] = useState("");
  const [issuePath, setIssuePath] = useState<IssuePathEntry[]>([]);
  const activeIssue = issuePath.at(-1) ?? (issue ? pathEntry(issue) : null);
  const issueRef = activeIssue?.identifier ?? activeIssue?.id ?? "";

  useEffect(() => {
    setInstruction("");
    setIssuePath(open && issue ? [pathEntry(issue)] : []);
  }, [open, issue?.id]);

  const detailQuery = useQuery({
    queryKey: queryKeys.issues.detail(issueRef),
    queryFn: () => issuesApi.get(issueRef),
    enabled: open && issueRef.length > 0,
  });
  const commentsQuery = useQuery({
    queryKey: queryKeys.issues.commentsList(activeIssue?.id ?? ""),
    queryFn: () => issuesApi.listComments(activeIssue!.id, { order: "asc" }),
    enabled: open && Boolean(activeIssue?.id),
  });

  const currentIssue = detailQuery.data ?? (activeIssue?.id === issue?.id ? issue : null);
  const agentMap = useMemo(() => new Map(agents.map((agent) => [agent.id, agent])), [agents]);
  const assignee = currentIssue?.assigneeAgentId
    ? agentMap.get(currentIssue.assigneeAgentId) ?? null
    : null;

  async function invalidateIssue() {
    if (!currentIssue) return;
    await Promise.all([
      queryClient.invalidateQueries({ queryKey: queryKeys.issues.detail(issueRef) }),
      queryClient.invalidateQueries({ queryKey: queryKeys.issues.commentsList(currentIssue.id) }),
      queryClient.invalidateQueries({ queryKey: queryKeys.issues.listBlockedAttention(companyId) }),
      queryClient.invalidateQueries({ queryKey: queryKeys.issues.list(companyId) }),
    ]);
  }

  const commentMutation = useMutation({
    mutationFn: async () => {
      if (!currentIssue) throw new Error("No issue is selected.");
      const body = instruction.trim();
      if (!body) throw new Error("Write an instruction before sending it.");
      return issuesApi.addComment(currentIssue.id, body);
    },
    onSuccess: async () => {
      setInstruction("");
      await invalidateIssue();
      pushToast({ title: "Instruction sent", body: "The full issue thread now includes your direction.", tone: "success" });
    },
    onError: (error) => pushToast({ title: "Instruction failed", body: messageForError(error), tone: "error" }),
  });

  const retryMutation = useMutation({
    mutationFn: async () => {
      if (!currentIssue) throw new Error("No issue is selected.");
      return issuesApi.retryScheduledRetryNow(currentIssue.id);
    },
    onSuccess: async (result) => {
      await invalidateIssue();
      pushToast({
        title: result.outcome === "promoted" ? "Recovery promoted" : "Recovery checked",
        body: result.message,
        tone: result.outcome === "gate_suppressed" ? "warn" : "success",
      });
    },
    onError: (error) => pushToast({ title: "Retry failed", body: messageForError(error), tone: "error" }),
  });

  const wakeMutation = useMutation({
    mutationFn: async () => {
      if (!currentIssue?.assigneeAgentId) throw new Error("Assign an agent before waking an owner.");
      return agentsApi.wakeup(currentIssue.assigneeAgentId, {
        source: "on_demand",
        triggerDetail: "manual",
        reason: `Board recovery request for ${currentIssue.identifier ?? currentIssue.id}`,
        payload: { issueId: currentIssue.id },
        idempotencyKey: `dashboard-recovery:${currentIssue.id}:${currentIssue.updatedAt}`,
      }, companyId);
    },
    onSuccess: () => {
      pushToast({ title: "Owner wake queued", body: assignee?.name ?? "The assigned agent will resume this issue.", tone: "success" });
    },
    onError: (error) => pushToast({ title: "Wake failed", body: messageForError(error), tone: "error" }),
  });

  const comments = commentsQuery.data ?? [];
  const blockers = currentIssue?.blockedBy ?? [];
  const attentionPath = currentIssue?.blockedInboxAttention
    ? [
        currentIssue.blockedInboxAttention.sourceIssue,
        currentIssue.blockedInboxAttention.leafIssue,
        currentIssue.blockedInboxAttention.recoveryIssue,
      ].filter((candidate): candidate is IssueBlockedInboxIssueRef => Boolean(
        candidate
        && candidate.id !== currentIssue.id
        && !blockers.some((blocker) => blocker.id === candidate.id),
      ))
    : [];

  function followIssue(nextIssue: IssueRelationIssueSummary | IssueBlockedInboxIssueRef) {
    setInstruction("");
    setIssuePath((currentPath) => {
      const existingIndex = currentPath.findIndex((entry) => entry.id === nextIssue.id);
      if (existingIndex >= 0) return currentPath.slice(0, existingIndex + 1);
      return [...currentPath, pathEntry(nextIssue)];
    });
  }

  function returnToPathIndex(index: number) {
    setInstruction("");
    setIssuePath((currentPath) => currentPath.slice(0, index + 1));
  }

  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent
        side={isMobile ? "bottom" : "right"}
        className={isMobile
          ? "max-h-[92dvh] w-full rounded-t-2xl border-x border-t p-0"
          : "w-full p-0 sm:max-w-xl"}
      >
        <SheetHeader className="border-b px-5 py-5 pr-12">
          {issuePath.length > 1 ? (
            <div className="mb-1 flex min-w-0 items-center gap-2 text-xs">
              <button
                type="button"
                onClick={() => returnToPathIndex(issuePath.length - 2)}
                className="inline-flex shrink-0 items-center gap-1 font-semibold text-emerald-700 hover:underline dark:text-emerald-300"
              >
                <ChevronLeft className="h-3.5 w-3.5" /> Back
              </button>
              <div className="flex min-w-0 items-center gap-1 overflow-x-auto text-muted-foreground">
                {issuePath.map((entry, index) => (
                  <span key={entry.id} className="inline-flex shrink-0 items-center gap-1">
                    {index > 0 ? <span aria-hidden="true">/</span> : null}
                    <button
                      type="button"
                      onClick={() => returnToPathIndex(index)}
                      className={index === issuePath.length - 1 ? "font-semibold text-foreground" : "hover:text-foreground hover:underline"}
                    >
                      {entry.identifier ?? entry.title}
                    </button>
                  </span>
                ))}
              </div>
            </div>
          ) : null}
          <div className="text-[11px] font-semibold uppercase tracking-[0.12em] text-emerald-700 dark:text-emerald-300">
            {currentIssue?.identifier ?? "Issue context"}
          </div>
          <SheetTitle className="text-xl leading-tight">{currentIssue?.title ?? "Loading issue…"}</SheetTitle>
          <SheetDescription>
            Review the whole blocker path and full conversation before acting.
          </SheetDescription>
        </SheetHeader>

        <div className="min-h-0 flex-1 overflow-y-auto">
          {detailQuery.isLoading ? (
            <div className="flex min-h-52 items-center justify-center text-muted-foreground">
              <Loader2 className="mr-2 h-4 w-4 animate-spin" /> Loading issue context
            </div>
          ) : detailQuery.error ? (
            <div className="m-5 rounded-lg border border-destructive/25 bg-destructive/5 p-4 text-sm text-destructive">
              {messageForError(detailQuery.error)}
            </div>
          ) : currentIssue ? (
            <>
              <section className="grid grid-cols-3 gap-px border-b bg-border">
                <div className="bg-background px-4 py-3">
                  <span className="block text-[10px] uppercase tracking-wide text-muted-foreground">Status</span>
                  <strong className="mt-1 block text-xs capitalize">{currentIssue.status.replaceAll("_", " ")}</strong>
                </div>
                <div className="bg-background px-4 py-3">
                  <span className="block text-[10px] uppercase tracking-wide text-muted-foreground">Owner</span>
                  <strong className="mt-1 block truncate text-xs">{assignee?.name ?? "Unassigned"}</strong>
                </div>
                <div className="bg-background px-4 py-3">
                  <span className="block text-[10px] uppercase tracking-wide text-muted-foreground">Updated</span>
                  <strong className="mt-1 block text-xs">{timeAgo(currentIssue.updatedAt)}</strong>
                </div>
              </section>

              <section className="border-b px-5 py-5">
                <h3 className="text-xs font-semibold uppercase tracking-[0.1em] text-muted-foreground">What is stopping work</h3>
                <p className="mt-3 whitespace-pre-wrap text-sm leading-6 text-foreground/85">
                  {currentIssue.activeRecoveryAction?.nextAction
                    ?? currentIssue.blockedInboxAttention?.action.detail
                    ?? currentIssue.blockedInboxAttention?.action.label
                    ?? currentIssue.description
                    ?? "No blocker explanation has been recorded yet."}
                </p>
                {blockers.length > 0 ? (
                  <div className="mt-4 text-xs">
                    <span className="font-medium text-muted-foreground">Follow blocker path</span>
                    <div className="mt-2 flex flex-wrap gap-2">
                      {blockers.map((blocker) => (
                        <button
                          key={blocker.id}
                          type="button"
                          onClick={() => followIssue(blocker)}
                          className="rounded-md border bg-muted/35 px-2 py-1 text-left font-medium hover:border-emerald-700/30 hover:bg-muted"
                        >
                          {blocker.identifier ?? blocker.id.slice(0, 8)} · {blocker.title}
                        </button>
                      ))}
                    </div>
                  </div>
                ) : null}
                {attentionPath.length > 0 ? (
                  <div className="mt-4 text-xs">
                    <span className="font-medium text-muted-foreground">Related attention path</span>
                    <div className="mt-2 flex flex-wrap gap-2">
                      {attentionPath.map((relatedIssue) => (
                        <button
                          key={relatedIssue.id}
                          type="button"
                          onClick={() => followIssue(relatedIssue)}
                          className="rounded-md border bg-muted/35 px-2 py-1 text-left font-medium hover:border-emerald-700/30 hover:bg-muted"
                        >
                          {relatedIssue.identifier ?? relatedIssue.id.slice(0, 8)} · {relatedIssue.title}
                        </button>
                      ))}
                    </div>
                  </div>
                ) : null}
              </section>

              <section className="border-b px-5 py-5">
                <div className="flex items-center justify-between gap-3">
                  <h3 className="flex items-center gap-2 text-xs font-semibold uppercase tracking-[0.1em] text-muted-foreground">
                    <MessageSquareText className="h-4 w-4" /> Issue conversation
                  </h3>
                  <Link
                    to={`/issues/${currentIssue.identifier ?? currentIssue.id}`}
                    className="inline-flex items-center gap-1 text-xs font-semibold text-emerald-700 hover:underline dark:text-emerald-300"
                  >
                    Open full issue <ArrowRight className="h-3.5 w-3.5" />
                  </Link>
                </div>
                <div className="mt-3 divide-y rounded-lg border">
                  {commentsQuery.isLoading ? (
                    <div className="p-4 text-sm text-muted-foreground">Loading conversation…</div>
                  ) : comments.length === 0 ? (
                    <div className="p-4 text-sm text-muted-foreground">No comments yet.</div>
                  ) : comments.map((comment) => {
                    const author = comment.authorAgentId
                      ? agentMap.get(comment.authorAgentId)?.name ?? "Agent"
                      : "Board";
                    return (
                      <article key={comment.id} className="px-4 py-3">
                        <div className="flex items-center justify-between gap-3 text-xs">
                          <strong>{author}</strong>
                          <time className="text-muted-foreground">{timeAgo(comment.createdAt)}</time>
                        </div>
                        <p className="mt-1 whitespace-pre-wrap break-words text-sm leading-5 text-foreground/80">{comment.body}</p>
                      </article>
                    );
                  })}
                </div>
              </section>

              <section className="px-5 py-5">
                <label htmlFor="dashboard-board-instruction" className="text-xs font-semibold uppercase tracking-[0.1em] text-muted-foreground">
                  Direct the owner
                </label>
                <Textarea
                  id="dashboard-board-instruction"
                  value={instruction}
                  onChange={(event) => setInstruction(event.target.value)}
                  placeholder="Write a decision, clarification, or recovery instruction…"
                  className="mt-3 min-h-24 resize-y"
                />
                <div className="mt-2 flex items-center justify-between gap-3">
                  <span className="text-xs text-muted-foreground">Posts to the full issue thread.</span>
                  <Button
                    size="sm"
                    onClick={() => commentMutation.mutate()}
                    disabled={commentMutation.isPending || instruction.trim().length === 0}
                  >
                    {commentMutation.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
                    Send instruction
                  </Button>
                </div>
              </section>
            </>
          ) : null}
        </div>

        {currentIssue ? (
          <SheetFooter className="grid grid-cols-2 border-t bg-background p-4 sm:grid-cols-3">
            <Button asChild variant="outline">
              <Link to={`/issues/${currentIssue.identifier ?? currentIssue.id}`}>
                <UserRoundCog className="h-4 w-4" /> Reassign
              </Link>
            </Button>
            {currentIssue.scheduledRetry ? (
              <Button
                onClick={() => retryMutation.mutate()}
                disabled={retryMutation.isPending}
                className="sm:col-span-2"
              >
                {retryMutation.isPending ? <Loader2 className="h-4 w-4 animate-spin" /> : <RefreshCw className="h-4 w-4" />}
                Retry now
              </Button>
            ) : (
              <Button
                onClick={() => wakeMutation.mutate()}
                disabled={!currentIssue.assigneeAgentId || wakeMutation.isPending}
                className="sm:col-span-2"
              >
                {wakeMutation.isPending ? <Loader2 className="h-4 w-4 animate-spin" /> : <RefreshCw className="h-4 w-4" />}
                Wake owner
              </Button>
            )}
          </SheetFooter>
        ) : null}
      </SheetContent>
    </Sheet>
  );
}
