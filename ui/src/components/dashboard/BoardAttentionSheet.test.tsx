// @vitest-environment jsdom

import { act, type ComponentProps, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { Agent, Issue } from "@paperclipai/shared";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { BoardAttentionSheet } from "./BoardAttentionSheet";

const getIssueMock = vi.hoisted(() => vi.fn());
const listCommentsMock = vi.hoisted(() => vi.fn());

vi.mock("@/lib/router", () => ({
  Link: ({ to, children, ...props }: { to: string; children: ReactNode }) => <a href={to} {...props}>{children}</a>,
}));
vi.mock("../../api/issues", () => ({
  issuesApi: {
    get: getIssueMock,
    listComments: listCommentsMock,
    addComment: vi.fn(),
    retryScheduledRetryNow: vi.fn(),
  },
}));
vi.mock("../../api/agents", () => ({ agentsApi: { wakeup: vi.fn() } }));
vi.mock("../../context/SidebarContext", () => ({ useSidebar: () => ({ isMobile: false }) }));
vi.mock("../../context/ToastContext", () => ({ useToastActions: () => ({ pushToast: vi.fn() }) }));
vi.mock("../ui/sheet", () => ({
  Sheet: ({ open, children }: { open: boolean; children: ReactNode }) => open ? <div>{children}</div> : null,
  SheetContent: ({ children, ...props }: ComponentProps<"div">) => <div role="dialog" {...props}>{children}</div>,
  SheetDescription: ({ children, ...props }: ComponentProps<"p">) => <p {...props}>{children}</p>,
  SheetFooter: ({ children, ...props }: ComponentProps<"footer">) => <footer {...props}>{children}</footer>,
  SheetHeader: ({ children, ...props }: ComponentProps<"header">) => <header {...props}>{children}</header>,
  SheetTitle: ({ children, ...props }: ComponentProps<"h2">) => <h2 {...props}>{children}</h2>,
}));

// eslint-disable-next-line @typescript-eslint/no-explicit-any
(globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;

const blocker = {
  id: "blocker-1",
  identifier: "PC-2",
  title: "Complete the assigned dependency",
  status: "todo",
  priority: "high",
  assigneeAgentId: "agent-1",
  assigneeUserId: null,
};

const rootIssue = {
  id: "issue-1",
  companyId: "company-1",
  identifier: "PC-1",
  title: "Parent issue waiting on dependency",
  description: "The child must finish first.",
  status: "blocked",
  priority: "high",
  assigneeAgentId: "agent-1",
  updatedAt: new Date("2026-07-17T12:00:00.000Z"),
  blockedBy: [blocker],
} as unknown as Issue;

const blockerIssue = {
  ...rootIssue,
  id: blocker.id,
  identifier: blocker.identifier,
  title: blocker.title,
  status: blocker.status,
  blockedBy: [],
} as unknown as Issue;

const agent = { id: "agent-1", name: "Code Worker" } as Agent;

let container: HTMLDivElement;
let root: Root;

async function waitForText(text: string) {
  for (let attempt = 0; attempt < 40; attempt += 1) {
    if (container.textContent?.includes(text)) return;
    await act(async () => new Promise((resolve) => window.setTimeout(resolve, 5)));
  }
  throw new Error(`Timed out waiting for ${text}`);
}

async function waitForHeading(text: string) {
  for (let attempt = 0; attempt < 40; attempt += 1) {
    if (container.querySelector("h2")?.textContent === text) return;
    await act(async () => new Promise((resolve) => window.setTimeout(resolve, 5)));
  }
  throw new Error(`Timed out waiting for heading ${text}`);
}

beforeEach(async () => {
  vi.clearAllMocks();
  getIssueMock.mockImplementation(async (reference: string) => reference === "PC-2" ? blockerIssue : rootIssue);
  listCommentsMock.mockResolvedValue([]);
  container = document.createElement("div");
  document.body.appendChild(container);
  root = createRoot(container);
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: 0 } } });
  await act(async () => {
    root.render(
      <QueryClientProvider client={queryClient}>
        <BoardAttentionSheet
          companyId="company-1"
          issue={rootIssue}
          agents={[agent]}
          open
          onOpenChange={vi.fn()}
        />
      </QueryClientProvider>,
    );
  });
  await waitForText("Follow blocker path");
});

afterEach(async () => {
  await act(async () => root.unmount());
  container.remove();
});

describe("BoardAttentionSheet blocker path", () => {
  it("follows a blocker inline and returns to the prior issue", async () => {
    const blockerButton = [...container.querySelectorAll("button")]
      .find((button) => button.textContent?.includes("PC-2"));
    expect(blockerButton).toBeTruthy();

    await act(async () => blockerButton?.click());
    await waitForHeading(blockerIssue.title);

    const pathButtons = [...container.querySelectorAll("header button")]
      .map((button) => button.textContent?.trim());
    expect(pathButtons).toEqual(expect.arrayContaining(["PC-1", "PC-2"]));
    expect(getIssueMock).toHaveBeenCalledWith("PC-2");

    const backButton = [...container.querySelectorAll("button")]
      .find((button) => button.textContent?.trim() === "Back");
    expect(backButton).toBeTruthy();
    await act(async () => backButton?.click());
    await waitForHeading(rootIssue.title);
    expect([...container.querySelectorAll("header button")].some((button) => button.textContent?.trim() === "PC-2")).toBe(false);
  });
});
