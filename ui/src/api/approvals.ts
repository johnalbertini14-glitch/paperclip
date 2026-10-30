import type { Approval, ApprovalComment, Issue } from "@paperclipai/shared";
import { api } from "./client";

export const approvalsApi = {
  count: (companyId: string, status: string, options?: { signal?: AbortSignal }) =>
    api.get<{ count: number }>(`/companies/${companyId}/approvals/count?status=${encodeURIComponent(status)}`, options),
  list: (companyId: string, status?: string, page?: { limit?: number; offset?: number }, options?: { signal?: AbortSignal }) => {
    const params = new URLSearchParams();
    if (status) params.set("status", status);
    if (page?.limit !== undefined) params.set("limit", String(page.limit));
    if (page?.offset !== undefined) params.set("offset", String(page.offset));
    const query = params.toString();
    return api.get<Approval[]>(
      `/companies/${companyId}/approvals${query ? `?${query}` : ""}`, options,
    );
  },
  create: (companyId: string, data: Record<string, unknown>) =>
    api.post<Approval>(`/companies/${companyId}/approvals`, data),
  get: (id: string) => api.get<Approval>(`/approvals/${id}`),
  approve: (id: string, decisionNote?: string) =>
    api.post<Approval>(`/approvals/${id}/approve`, { decisionNote }),
  reject: (id: string, decisionNote?: string) =>
    api.post<Approval>(`/approvals/${id}/reject`, { decisionNote }),
  requestRevision: (id: string, decisionNote?: string) =>
    api.post<Approval>(`/approvals/${id}/request-revision`, { decisionNote }),
  resubmit: (id: string, payload?: Record<string, unknown>) =>
    api.post<Approval>(`/approvals/${id}/resubmit`, { payload }),
  listComments: (id: string) => api.get<ApprovalComment[]>(`/approvals/${id}/comments`),
  addComment: (id: string, body: string) =>
    api.post<ApprovalComment>(`/approvals/${id}/comments`, { body }),
  listIssues: (id: string) => api.get<Issue[]>(`/approvals/${id}/issues`),
};
