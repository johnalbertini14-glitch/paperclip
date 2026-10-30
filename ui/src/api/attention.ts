import type { AttentionFeed, AttentionFeedQuery } from "@paperclipai/shared";
import { api } from "./client";

export const attentionApi = {
  /**
   * Fetch the ranked Decisions attention feed for a company. The server
   * unions every attention source (approvals, interactions, recovery, reviews,
   * failures, budget…) into one ranked queue with the §0 contract.
   */
  list: (companyId: string, options: AttentionFeedQuery = {}, requestOptions?: { signal?: AbortSignal }) => {
    const params = new URLSearchParams();
    if (options.includeDismissed) params.set("includeDismissed", "true");
    if (options.archived) params.set("archived", "true");
    if (options.all) params.set("all", "true");
    if (options.activitySince) params.set("activitySince", options.activitySince);
    if (options.activityUntil) params.set("activityUntil", options.activityUntil);
    if (options.queue) params.set("queue", options.queue);
    if (options.sourceKind) params.set("sourceKind", options.sourceKind);
    if (options.sourceKinds?.length) params.set("sourceKinds", options.sourceKinds.join(","));
    if (options.sort) params.set("sort", options.sort);
    if (options.cursor) params.set("cursor", options.cursor);
    if (options.limit !== undefined) params.set("limit", String(options.limit));
    if (options.dashboardCounts) params.set("dashboardCounts", "true");
    const query = params.toString();
    return api.get<AttentionFeed>(`/companies/${companyId}/attention${query ? `?${query}` : ""}`, requestOptions);
  },
};
