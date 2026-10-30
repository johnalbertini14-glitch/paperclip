import { describe, expect, it } from "vitest";
import type { Issue } from "@paperclipai/shared";
import {
  ISSUES_ROW_PRESENTATION,
  ISSUES_TOOLBAR_PRESENTATION,
  buildIssuesSearchUrl,
  getNextIssuesPageOffset,
  mergeIssuePagesStable,
  resolveIssuesPresentation,
} from "./Issues";

function createIssue(id: string, title: string): Issue {
  return { id, title } as Issue;
}

describe("buildIssuesSearchUrl", () => {
  it("preserves trailing spaces in the synced search param", () => {
    expect(buildIssuesSearchUrl("http://localhost:3100/issues?q=bug", "bug ")).toBe("/issues?q=bug+");
  });

  it("removes the search param when the input is cleared", () => {
    expect(buildIssuesSearchUrl("http://localhost:3100/issues?q=bug#details", "")).toBe("/issues#details");
  });

  it("returns null when the URL already matches the current search", () => {
    expect(buildIssuesSearchUrl("http://localhost:3100/issues?q=bug+", "bug ")).toBeNull();
  });
});

describe("issues page pagination helpers", () => {
  it("opts the Tasks route into the canonical shared task-row presentation", () => {
    expect(ISSUES_ROW_PRESENTATION).toBe("task");
  });

  it("opts the Tasks route into the shared collection toolbar", () => {
    expect(ISSUES_TOOLBAR_PRESENTATION).toBe("collection");
  });

  it("restores the retained legacy list and toolbar when Streamlined UI is off", () => {
    expect(resolveIssuesPresentation(false)).toEqual({
      rowPresentation: "legacy",
      toolbarPresentation: "legacy",
    });
    expect(resolveIssuesPresentation(true)).toEqual({
      rowPresentation: "task",
      toolbarPresentation: "collection",
    });
  });

  it("advances to the next offset for a full 50-row Tasks page", () => {
    expect(getNextIssuesPageOffset(50, 0)).toBe(50);
    expect(getNextIssuesPageOffset(50, 50)).toBe(100);
  });

  it("stops requesting issue pages when the current page is partial", () => {
    expect(getNextIssuesPageOffset(49, 0)).toBeUndefined();
  });

  it("dedupes overlapping pages without moving the original issue position", () => {
    const first = createIssue("issue-1", "Original first");
    const second = createIssue("issue-2", "Second");
    const duplicateFirst = createIssue("issue-1", "Duplicate first");
    const third = createIssue("issue-3", "Third");

    expect(mergeIssuePagesStable([[first, second], [duplicateFirst, third]])).toEqual([
      first,
      second,
      third,
    ]);
  });
});
