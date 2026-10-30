import { beforeEach, describe, expect, it, vi } from "vitest";

const mockApi = vi.hoisted(() => ({ get: vi.fn() }));
vi.mock("./client", () => ({ api: mockApi }));

import { approvalsApi } from "./approvals";
import { routinesApi } from "./routines";

describe("Dashboard paged approval and routine clients", () => {
  beforeEach(() => {
    mockApi.get.mockReset();
    mockApi.get.mockResolvedValue([]);
  });

  it("sends status, limit, offset and abort signal before approval paging", async () => {
    const signal = new AbortController().signal;
    await approvalsApi.list("company-1", "pending", { limit: 50, offset: 50 }, { signal });
    expect(mockApi.get).toHaveBeenCalledWith("/companies/company-1/approvals?status=pending&limit=50&offset=50", { signal });
  });

  it("counts pending approvals separately from paged and native decision items", async () => {
    const signal = new AbortController().signal;
    mockApi.get.mockResolvedValueOnce({ count: 51 });
    expect(await approvalsApi.count("company-1", "pending", { signal })).toEqual({ count: 51 });
    expect(mockApi.get).toHaveBeenCalledWith("/companies/company-1/approvals/count?status=pending", { signal });
  });

  it("sends limit, offset and abort signal before routine paging", async () => {
    const signal = new AbortController().signal;
    await routinesApi.list("company-1", { limit: 50, offset: 50 }, { signal });
    expect(mockApi.get).toHaveBeenCalledWith("/companies/company-1/routines?limit=50&offset=50", { signal });
  });

  it("sends the opt-in failed-latest selector before routine pagination", async () => {
    const signal = new AbortController().signal;
    await routinesApi.list("company-1", { failedLatest: true, limit: 50, offset: 50 }, { signal });
    expect(mockApi.get).toHaveBeenCalledWith("/companies/company-1/routines?limit=50&offset=50&failedLatest=true", { signal });
  });

  it("counts only latest-failed routines without requesting a list page", async () => {
    const signal = new AbortController().signal;
    mockApi.get.mockResolvedValueOnce({ count: 1 });
    expect(await routinesApi.count("company-1", { failedLatest: true }, { signal })).toEqual({ count: 1 });
    expect(mockApi.get).toHaveBeenCalledWith("/companies/company-1/routines/count?failedLatest=true", { signal });
  });

  it("preserves legacy unpaged requests", async () => {
    await approvalsApi.list("company-1", "pending");
    await routinesApi.list("company-1");
    expect(mockApi.get).toHaveBeenNthCalledWith(1, "/companies/company-1/approvals?status=pending", undefined);
    expect(mockApi.get).toHaveBeenNthCalledWith(2, "/companies/company-1/routines", undefined);
  });
});
