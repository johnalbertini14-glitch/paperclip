import express from "express";
import request from "supertest";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { beforeEach, describe, expect, it, vi } from "vitest";

const mockAgentService = vi.hoisted(() => ({
  getById: vi.fn(),
}));

const mockListServerAdapters = vi.hoisted(() => vi.fn());
const mockSpawn = vi.hoisted(() => vi.fn());

vi.mock("../services/agents.js", () => ({
  agentService: () => mockAgentService,
}));

vi.mock("../adapters/index.js", () => ({
  listServerAdapters: mockListServerAdapters,
}));

vi.mock("node:child_process", () => ({
  spawn: mockSpawn,
}));

function registerModuleMocks() {
  vi.doMock("../services/agents.js", () => ({
    agentService: () => mockAgentService,
  }));

  vi.doMock("../adapters/index.js", () => ({
    listServerAdapters: mockListServerAdapters,
  }));

  vi.doMock("node:child_process", () => ({
    spawn: mockSpawn,
  }));
}

async function createApp(actor: Record<string, unknown>) {
  const [{ llmRoutes }, { errorHandler }] = await Promise.all([
    vi.importActual<typeof import("../routes/llms.js")>("../routes/llms.js"),
    vi.importActual<typeof import("../middleware/index.js")>("../middleware/index.js"),
  ]);
  const app = express();
  app.use(express.json());
  app.use((req, _res, next) => {
    (req as any).actor = actor;
    next();
  });
  app.use("/api", llmRoutes({} as never));
  app.use(errorHandler);
  return app;
}

describe("llm routes", () => {
  beforeEach(() => {
    vi.resetModules();
    vi.doUnmock("../routes/llms.js");
    vi.doUnmock("../middleware/index.js");
    registerModuleMocks();
    vi.clearAllMocks();
    mockListServerAdapters.mockReturnValue([
      { type: "codex_local", agentConfigurationDoc: "# codex_local agent configuration" },
    ]);
  });

  it("serves OpenAI-compatible chat completions through the codex lane", async () => {
    const stdout = new PassThrough();
    const stderr = new PassThrough();
    const stdin = new PassThrough();
    const proc = new EventEmitter() as EventEmitter & {
      stdin: PassThrough;
      stdout: PassThrough;
      stderr: PassThrough;
      kill: ReturnType<typeof vi.fn>;
    };
    proc.stdin = stdin;
    proc.stdout = stdout;
    proc.stderr = stderr;
    proc.kill = vi.fn();

    mockSpawn.mockImplementationOnce(() => {
      queueMicrotask(() => {
        stdout.write('{"type":"thread.started","thread_id":"thread-1"}\n');
        stdout.write('{"type":"item.completed","item":{"type":"agent_message","text":"{\\"ok\\":true,\\"reason\\":\\"looks good\\",\\"missing\\":[]}"}}\n');
        stdout.write('{"type":"turn.completed","usage":{"input_tokens":12,"output_tokens":8}}\n');
        stdout.end();
        stderr.end();
        proc.emit("close", 0, null);
      });
      return proc;
    });

    let capturedPrompt = "";
    stdin.on("data", (chunk) => {
      capturedPrompt += chunk.toString("utf8");
    });

    const app = await createApp({
      type: "board",
      userId: "board-user",
      companyIds: ["company-1"],
      source: "local_implicit",
      isInstanceAdmin: true,
    });

    const res = await request(app).post("/api/chat/completions").send({
      model: "gpt-5.4",
      messages: [
        { role: "system", content: "Return JSON only." },
        { role: "user", content: "Judge the run." },
      ],
      max_tokens: 64,
      temperature: 0,
    });

    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({
      object: "chat.completion",
      model: "gpt-5.4",
      choices: [{ index: 0, message: { role: "assistant", content: '{"ok":true,"reason":"looks good","missing":[]}' } }],
      usage: { prompt_tokens: 12, completion_tokens: 8, total_tokens: 20 },
    });
    expect(mockSpawn).toHaveBeenCalledWith(
      "codex",
      ["exec", "--json", "--model", "gpt-5.4", "-"],
      expect.objectContaining({ cwd: expect.stringContaining("/paperclip/repos/paperclip") }),
    );
    expect(capturedPrompt).toContain("Return JSON only.");
    expect(capturedPrompt).toContain("Judge the run.");
  });

  it("documents timer heartbeats as opt-in for new hires", async () => {
    const app = await createApp({
      type: "board",
      userId: "board-user",
      companyIds: ["company-1"],
      source: "local_implicit",
      isInstanceAdmin: true,
    });

    const res = await request(app).get("/api/llms/agent-configuration.txt");

    expect(res.status).toBe(200);
    expect(res.text).toContain("Use the paperclip-create-agent skill for end-to-end hiring");
    expect(res.text).toContain("desiredSkills");
    expect(res.text).toContain("sourceIssueId/sourceIssueIds");
    expect(res.text).toContain("Timer heartbeats are opt-in for new hires.");
    expect(res.text).toContain("Leave runtimeConfig.heartbeat.enabled false");
  });
});
