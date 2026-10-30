import { useCallback, useEffect, useMemo, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { accessApi } from "../api/access";
import { ApiError } from "../api/client";
import { inboxDismissalsApi } from "../api/inboxDismissals";
import { approvalsApi } from "../api/approvals";
import { authApi } from "../api/auth";
import { dashboardApi } from "../api/dashboard";
import { heartbeatsApi } from "../api/heartbeats";
import { issuesApi } from "../api/issues";
import { queryKeys } from "../lib/queryKeys";
import { usePublishSharedQueryData, useSharedPollingQuery } from "./useSharedPolling";
import type { Approval } from "@paperclipai/shared";
import {
  ACTIONABLE_APPROVAL_STATUSES,
  buildInboxDismissedAtByKey,
  computeInboxBadgeData,
  loadDismissedInboxAlerts,
  saveDismissedInboxAlerts,
  loadReadInboxItems,
  saveReadInboxItems,
  READ_ITEMS_KEY,
} from "../lib/inbox";

const INBOX_ISSUE_STATUSES = "backlog,todo,in_progress,in_review,blocked,done";
const INBOX_BADGE_HEARTBEAT_RUN_LIMIT = 200;
const INBOX_BADGE_HOT_PATH_STALE_MS = 30_000;
const INBOX_BADGE_APPROVAL_PAGE_SIZE = 50;

// The badge only counts actionable approvals, so page through those statuses
// instead of hydrating the company's full approval history on every tab.
async function listActionableApprovals(companyId: string, signal?: AbortSignal) {
  const rows = new Map<string, Approval>();
  for (const status of ACTIONABLE_APPROVAL_STATUSES) {
    for (let offset = 0; ; offset += INBOX_BADGE_APPROVAL_PAGE_SIZE) {
      const page = await approvalsApi.list(companyId, status, { limit: INBOX_BADGE_APPROVAL_PAGE_SIZE, offset }, { signal });
      for (const approval of page) rows.set(approval.id, approval);
      if (page.length < INBOX_BADGE_APPROVAL_PAGE_SIZE) break;
    }
  }
  return [...rows.values()];
}

export function useDismissedInboxAlerts() {
  const [dismissed, setDismissed] = useState<Set<string>>(loadDismissedInboxAlerts);

  useEffect(() => {
    const handleStorage = (event: StorageEvent) => {
      if (event.key !== "paperclip:inbox:dismissed") return;
      setDismissed(loadDismissedInboxAlerts());
    };
    window.addEventListener("storage", handleStorage);
    return () => window.removeEventListener("storage", handleStorage);
  }, []);

  const dismiss = (id: string) => {
    setDismissed((prev) => {
      const next = new Set(prev);
      next.add(id);
      saveDismissedInboxAlerts(next);
      return next;
    });
  };

  return { dismissed, dismiss };
}

export function useInboxDismissals(companyId: string | null | undefined) {
  const queryClient = useQueryClient();
  const queryKey = companyId
    ? queryKeys.inboxDismissals(companyId)
    : ["inbox-dismissals", "__disabled__"] as const;

  const { data: dismissals = [] } = useQuery({
    queryKey,
    queryFn: () => inboxDismissalsApi.list(companyId!),
    enabled: !!companyId,
  });

  const dismissMutation = useMutation({
    mutationFn: ({ itemKey }: { itemKey: string }) => inboxDismissalsApi.dismiss(companyId!, itemKey),
    onMutate: async ({ itemKey }) => {
      if (!companyId) return { previous: [] as typeof dismissals };
      await queryClient.cancelQueries({ queryKey });
      const previous = queryClient.getQueryData<typeof dismissals>(queryKey) ?? [];
      const now = new Date();
      queryClient.setQueryData(queryKey, [
        {
          id: `optimistic:${itemKey}`,
          companyId,
          userId: "me",
          itemKey,
          dismissedAt: now,
          createdAt: now,
          updatedAt: now,
        },
        ...previous.filter((dismissal) => dismissal.itemKey !== itemKey),
      ]);
      return { previous };
    },
    onError: (_error, _variables, context) => {
      if (!context) return;
      queryClient.setQueryData(queryKey, context.previous);
    },
    onSettled: () => {
      if (!companyId) return;
      invalidateDismissalConsumers();
    },
  });

  function invalidateDismissalConsumers() {
    if (!companyId) return;
    queryClient.invalidateQueries({ queryKey });
    queryClient.invalidateQueries({ queryKey: queryKeys.sidebarBadges(companyId) });
    // The attention feed derives its rows from server-side dismissals, so any
    // dismiss/snooze/restore must re-pull it to keep the queue and curtains in sync.
    queryClient.invalidateQueries({ queryKey: queryKeys.attention(companyId) });
  }

  const snoozeMutation = useMutation({
    mutationFn: ({ itemKey, snoozedUntil }: { itemKey: string; snoozedUntil: string }) =>
      inboxDismissalsApi.snooze(companyId!, itemKey, snoozedUntil),
    onSettled: invalidateDismissalConsumers,
  });

  const restoreMutation = useMutation({
    mutationFn: ({ itemKey }: { itemKey: string }) => inboxDismissalsApi.restore(companyId!, itemKey),
    onSettled: invalidateDismissalConsumers,
  });

  const dismissedAtByKey = useMemo(
    () => buildInboxDismissedAtByKey(dismissals),
    [dismissals],
  );

  // Stable identities (react-query keeps `mutate` referentially stable) so
  // consumers can hand these to memoized rows without breaking memoization.
  const dismissMutate = dismissMutation.mutate;
  const snoozeMutate = snoozeMutation.mutate;
  const restoreMutate = restoreMutation.mutate;
  const dismiss = useCallback((itemKey: string) => dismissMutate({ itemKey }), [dismissMutate]);
  const snooze = useCallback(
    (itemKey: string, snoozedUntil: string) => snoozeMutate({ itemKey, snoozedUntil }),
    [snoozeMutate],
  );
  const restore = useCallback((itemKey: string) => restoreMutate({ itemKey }), [restoreMutate]);

  return {
    dismissals,
    dismissedAtByKey,
    dismiss,
    snooze,
    restore,
    isPending: dismissMutation.isPending || snoozeMutation.isPending || restoreMutation.isPending,
  };
}

export function useReadInboxItems() {
  const [readItems, setReadItems] = useState<Set<string>>(loadReadInboxItems);

  useEffect(() => {
    const handleStorage = (event: StorageEvent) => {
      if (event.key !== READ_ITEMS_KEY) return;
      setReadItems(loadReadInboxItems());
    };
    window.addEventListener("storage", handleStorage);
    return () => window.removeEventListener("storage", handleStorage);
  }, []);

  const markRead = (id: string) => {
    setReadItems((prev) => {
      const next = new Set(prev);
      next.add(id);
      saveReadInboxItems(next);
      return next;
    });
  };

  const markUnread = (id: string) => {
    setReadItems((prev) => {
      const next = new Set(prev);
      next.delete(id);
      saveReadInboxItems(next);
      return next;
    });
  };

  return { readItems, markRead, markUnread };
}

export function useInboxBadge(companyId: string | null | undefined) {
  const { dismissed: dismissedAlerts } = useDismissedInboxAlerts();
  const { dismissedAtByKey } = useInboxDismissals(companyId);
  const { data: session } = useQuery({
    queryKey: queryKeys.auth.session,
    queryFn: () => authApi.getSession(),
  });

  const { data: approvals = [] } = useQuery({
    queryKey: [...queryKeys.approvals.list(companyId!), "badge-actionable"],
    queryFn: ({ signal }) => listActionableApprovals(companyId!, signal),
    enabled: !!companyId,
  });

  const { data: joinRequests = [] } = useQuery({
    queryKey: queryKeys.access.joinRequests(companyId!),
    queryFn: async () => {
      try {
        return await accessApi.listJoinRequests(companyId!, "pending_approval");
      } catch (err) {
        if (err instanceof ApiError && (err.status === 401 || err.status === 403)) {
          return [];
        }
        throw err;
      }
    },
    enabled: !!companyId,
    retry: false,
  });

  const dashboardQueryKey = queryKeys.dashboard(companyId!);
  const sharedDashboard = useSharedPollingQuery({
    companyId,
    resourceKey: "dashboard",
    queryKey: dashboardQueryKey,
    enabled: !!companyId,
  });
  const { data: dashboard, dataUpdatedAt: dashboardUpdatedAt } = useQuery({
    queryKey: dashboardQueryKey,
    queryFn: () => dashboardApi.summary(companyId!),
    enabled: !!companyId,
  });
  usePublishSharedQueryData(sharedDashboard, dashboard, dashboardUpdatedAt);

  // Count unread personal work on the server rather than hydrating 500 issues
  // on every tab. Keep scalar data outside issue-array caches; existing archive
  // and live-update sidebar invalidations refresh this company-scoped child key.
  const unreadCountQueryKey = [...queryKeys.sidebarBadges(companyId!), "unread-issues"];
  const sharedUnreadCount = useSharedPollingQuery({
    companyId,
    resourceKey: "inbox-badge:unread-count",
    queryKey: unreadCountQueryKey,
    enabled: !!companyId,
  });
  const { data: unreadCount, dataUpdatedAt: unreadCountUpdatedAt } = useQuery({
    queryKey: unreadCountQueryKey,
    queryFn: () => issuesApi.count(companyId!, {
      touchedByUserId: "me",
      inboxArchivedByUserId: "me",
      unreadForUserId: "me",
      status: INBOX_ISSUE_STATUSES,
    }),
    enabled: !!companyId,
    refetchOnWindowFocus: false,
    staleTime: INBOX_BADGE_HOT_PATH_STALE_MS,
  });
  usePublishSharedQueryData(sharedUnreadCount, unreadCount, unreadCountUpdatedAt);

  const currentUserId = session?.user.id ?? session?.session.userId ?? null;

  const { data: heartbeatRuns = [] } = useQuery({
    queryKey: [...queryKeys.heartbeats(companyId!), "limit", INBOX_BADGE_HEARTBEAT_RUN_LIMIT],
    queryFn: () => heartbeatsApi.list(companyId!, undefined, INBOX_BADGE_HEARTBEAT_RUN_LIMIT, { summary: true }),
    enabled: !!companyId,
    refetchOnWindowFocus: false,
    staleTime: INBOX_BADGE_HOT_PATH_STALE_MS,
  });

  return useMemo(() => {
    const badges = computeInboxBadgeData({
      approvals,
      joinRequests,
      dashboard,
      heartbeatRuns,
      mineIssues: [],
      dismissedAlerts,
      dismissedAtByKey,
      currentUserId,
    });
    const mineIssues = unreadCount?.count ?? 0;
    return { ...badges, mineIssues, inbox: badges.inbox + mineIssues };
  }, [approvals, joinRequests, dashboard, heartbeatRuns, unreadCount, dismissedAlerts, dismissedAtByKey, currentUserId]);
}
