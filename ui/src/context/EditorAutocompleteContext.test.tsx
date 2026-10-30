// @vitest-environment jsdom
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { EditorAutocompleteProvider, useEditorAutocomplete } from "./EditorAutocompleteContext";

const mocks = vi.hoisted(() => ({ routines: vi.fn(), skills: vi.fn() }));
vi.mock("../api/routines", () => ({ routinesApi: { list: mocks.routines } }));
vi.mock("../api/companySkills", () => ({ companySkillsApi: { list: mocks.skills } }));
vi.mock("./CompanyContext", () => ({ useCompany: () => ({ selectedCompanyId: "company-a" }) }));

(globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
let commands: ReturnType<typeof useEditorAutocomplete>["slashCommands"] = [];
function Editor() { commands = useEditorAutocomplete().slashCommands; return null; }

describe("Editor autocomplete loads only while an editor is mounted", () => {
  let client: QueryClient, root: Root, container: HTMLDivElement;
  async function render(withEditor: boolean) {
    await act(async () => {
      root.render(<QueryClientProvider client={client}><EditorAutocompleteProvider>{withEditor ? <Editor /> : null}</EditorAutocompleteProvider></QueryClientProvider>);
    });
    await act(async () => { await new Promise((resolve) => setTimeout(resolve, 20)); });
  }
  beforeEach(() => {
    mocks.routines.mockReset().mockResolvedValue([{ id: "r1", title: "Nightly", status: "active" }]);
    mocks.skills.mockReset().mockResolvedValue([]);
    commands = [];
    client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    container = document.createElement("div"); document.body.appendChild(container); root = createRoot(container);
  });
  afterEach(async () => { await act(async () => root.unmount()); client.clear(); container.remove(); });

  it("does not list routines or skills for pages without an editor", async () => {
    await render(false);
    expect(mocks.routines).not.toHaveBeenCalled();
    expect(mocks.skills).not.toHaveBeenCalled();
  });

  it("loads routine slash commands once an editor mounts", async () => {
    await render(false);
    await render(true);
    expect(mocks.routines).toHaveBeenCalledWith("company-a");
    expect(commands.map((command) => command.id)).toContain("routine:r1");
  });
});
