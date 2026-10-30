import { beforeEach, describe, expect, it, vi } from "vitest";

const mockApi = vi.hoisted(() => ({ get: vi.fn() }));

vi.mock("./client", () => ({ api: mockApi }));

import { attentionApi } from "./attention";

describe("attentionApi.list", () => {
  beforeEach(() => {
    mockApi.get.mockReset();
    mockApi.get.mockResolvedValue({ items: [] });
  });

  it("encodes feed filters, decide sorting, and cursor pagination", async () => {
    await attentionApi.list("company-1", {
      includeDismissed: true,
      archived: true,
      activitySince: "2026-08-01T00:00:00.000Z",
      activityUntil: "2026-08-01T23:59:59.999Z",
      queue: "release review",
      sourceKind: "approval",
      sort: "decide",
      cursor: "next/page",
      limit: 25,
    });

    expect(mockApi.get).toHaveBeenCalledWith(
      "/companies/company-1/attention?includeDismissed=true&archived=true&activitySince=2026-08-01T00%3A00%3A00.000Z&activityUntil=2026-08-01T23%3A59%3A59.999Z&queue=release+review&sourceKind=approval&sort=decide&cursor=next%2Fpage&limit=25",
      undefined,
    );
  });

  it("requests a complete filtered snapshot for complete-set actions", async () => {
    await attentionApi.list("company-1", { queue: "release review", all: true });

    expect(mockApi.get).toHaveBeenCalledWith(
      "/companies/company-1/attention?all=true&queue=release+review",
      undefined,
    );
  });

  it("encodes a multi-kind native feed before cursor paging", async () => {
    await attentionApi.list("company-1", { sourceKinds: ["decision", "review"], limit: 50, cursor: "next/page" });
    expect(mockApi.get).toHaveBeenCalledWith(
      "/companies/company-1/attention?sourceKinds=decision%2Creview&cursor=next%2Fpage&limit=50",
      undefined,
    );
  });

  it("forwards a caller abort signal to the native feed request", async () => {
    const signal = new AbortController().signal;
    await attentionApi.list("company-1", { sourceKinds: ["review"], limit: 50 }, { signal });
    expect(mockApi.get).toHaveBeenCalledWith(
      "/companies/company-1/attention?sourceKinds=review&limit=50",
      { signal },
    );
  });

  it("omits the query delimiter when no options are supplied", async () => {
    await attentionApi.list("company-1");

    expect(mockApi.get).toHaveBeenCalledWith("/companies/company-1/attention", undefined);
  });
});
