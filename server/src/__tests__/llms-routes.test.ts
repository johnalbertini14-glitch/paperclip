import express from "express";
import request from "supertest";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { beforeEach, describe, expect, it, vi } from "vitest";

const mockAgentService = vi.hoisted(() => ({
  getById: vi.fn(),
}));

const mockListServerAdapters = vi.hoisted(() => vi.fn());
// Default implementation: a lazy noop proc so the mock never returns
// undefined when no mockImplementationOnce is active in a test.
// Each chat-completions test overrides with mockImplementationOnce as needed.
const mockSpawn = vi.hoisted(() => vi.fn());
function makeNoopProc() {
  return Object.assign(new EventEmitter(), {
    kill: vi.fn(),
    stdin: new PassThrough(),
    stdout: new PassThrough(),
    stderr: new PassThrough(),
  });
}

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
      setImmediate(() => {
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
      expect.arrayContaining(["exec", "--json", "--model", "gpt-5.4"]),
      expect.objectContaining({ cwd: expect.stringContaining("/paperclip/repos/paperclip") }),
    );
    expect(mockSpawn).toHaveBeenCalledWith(
      "codex",
      expect.arrayContaining(["--max-tokens", "64", "--temperature", "0"]),
      expect.any(Object),
    );
    expect(capturedPrompt).toContain("Return JSON only.");
    expect(capturedPrompt).toContain("Judge the run.");
  });

  it("rejects non-approved model with 400", async () => {
    const app = await createApp({
      type: "board",
      userId: "board-user",
      companyIds: ["company-1"],
      source: "local_implicit",
      isInstanceAdmin: true,
    });

    const res = await request(app).post("/api/chat/completions").send({
      model: "gpt-4",
      messages: [{ role: "user", content: "hello" }],
    });

    expect(res.status).toBe(400);
    expect(res.body.error).toContain("Model not supported");
    expect(res.body.detail).toContain("gpt-5.4");
  });

  it("forwards max_tokens, temperature, top_p, and stop to codex", async () => {
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
      setImmediate(() => {
        stdout.write('{"type":"item.completed","item":{"type":"agent_message","text":"done"}}\n');
        stdout.write('{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}\n');
        stdout.end();
        stderr.end();
        proc.emit("close", 0, null);
      });
      return proc;
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
      messages: [{ role: "user", content: "judge" }],
      max_tokens: 128,
      temperature: 0.7,
      top_p: 0.9,
      stop: "TERMINATE",
    });

    expect(res.status).toBe(200);
    expect(mockSpawn).toHaveBeenCalledWith(
      "codex",
      [
        "exec",
        "--json",
        "--model",
        "gpt-5.4",
        "--max-tokens",
        "128",
        "--temperature",
        "0.7",
        "--top-p",
        "0.9",
        "--stop",
        "TERMINATE",
        "-",
      ],
      expect.any(Object),
    );
  });

  it("registers a SIGKILL abort handler on the spawned process", async () => {
    // Clear prior call records so our assertions target this test's call only.
    mockSpawn.mockClear();

    const killMock = vi.fn();

    // Use Object.assign to create a real EventEmitter + kill property.
    // This preserves .on()/.emit() while also carrying the kill mock.
    const proc = Object.assign(new EventEmitter(), {
      kill: killMock,
      stdin: new PassThrough(),
      stdout: new PassThrough(),
      stderr: new PassThrough(),
    });

    mockSpawn.mockImplementationOnce(() => {
      // Emit close via microtask so listeners registered by runCodexChatCompletion
      // are in place before the event fires.  Also end the streams (like the
      // working "forwards controls" test does) so the "close" event fires
      // reliably from within the async route handler rather than after it returns.
      queueMicrotask(() => {
        proc.stdout.write('{"type":"item.completed","item":{"type":"agent_message","text":"done"}}\n');
        proc.stdout.write('{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}\n');
        proc.stdout.end();
        proc.stderr.end();
        proc.emit("close", 0, null);
      });
      return proc as unknown as import("node:child_process").ChildProcess;
    });

    const app = await createApp({
      type: "board",
      userId: "board-user",
      companyIds: ["company-1"],
      source: "local_implicit",
      isInstanceAdmin: true,
    });

    // Step 1: normal completion works
    const res = await request(app).post("/api/chat/completions").send({
      model: "gpt-5.4",
      messages: [{ role: "user", content: "hello" }],
    });
    expect(res.status).toBe(200, `Unexpected ${res.status}: ${JSON.stringify(res.body)}`);

    // Step 2: extract the AbortSignal passed to spawn and verify that
    // it is passed in the spawn options (not only registered as a listener after).
    // This is the primary abort mechanism — Node.js sends SIGKILL automatically
    // when the signal is aborted, without needing a manual kill call.
    const lastSpawnCall = mockSpawn.mock.calls.at(-1);
    const spawnOpts = lastSpawnCall?.[2] as { signal?: AbortSignal } | undefined;
    expect(spawnOpts?.signal).toBeDefined();

    spawnOpts!.signal!.dispatchEvent(new Event("abort"));
    expect(killMock).toHaveBeenCalledWith("SIGKILL");
  });

  it("passes the AbortSignal in spawn options so Node.js auto-kills on timeout", async () => {
    const killMock = vi.fn();
    const proc = Object.assign(new EventEmitter(), {
      kill: killMock,
      stdin: new PassThrough(),
      stdout: new PassThrough(),
      stderr: new PassThrough(),
    });

    mockSpawn.mockImplementationOnce(() => {
      queueMicrotask(() => proc.emit("close", 0, null));
      return proc as unknown as import("node:child_process").ChildProcess;
    });

    const app = await createApp({
      type: "board",
      userId: "board-user",
      companyIds: ["company-1"],
      source: "local_implicit",
      isInstanceAdmin: true,
    });

    await request(app).post("/api/chat/completions").send({
      model: "gpt-5.4",
      messages: [{ role: "user", content: "hello" }],
    });

    // Verify the signal appears in spawn's options object, not just as a post-hoc listener.
    const spawnOpts = mockSpawn.mock.calls.at(-1)?.[2] as { signal?: AbortSignal } | undefined;
    expect(spawnOpts).toBeDefined();
    expect(spawnOpts?.signal).toBeDefined();
    // The signal should be an AbortSignal instance so Node.js can monitor it.
    expect(spawnOpts?.signal).toBeInstanceOf(AbortSignal);
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

describe("llm routes — static docs", () => {
  it("serves agent configuration index and hermes gateway static docs", async () => {
    const app = await createApp({
      type: "board",
      userId: "board-user",
      companyIds: ["company-1"],
      source: "local_implicit",
      isInstanceAdmin: true,
    });

    const indexRes = await request(app).get("/api/llms/agent-configuration.txt");
    expect(indexRes.status).toBe(200);
    expect(indexRes.text).toContain(
      "- hermes_gateway: /llms/agent-configuration/hermes_gateway.txt",
    );

    const res = await request(app).get("/api/llms/agent-configuration/hermes_gateway.txt");

    expect(res.status).toBe(200);
    expect(res.text).toContain("Adapter: hermes_gateway");
    expect(res.text).toContain('adapterType": "hermes_gateway"');
    expect(res.text).toContain("API_SERVER_ENABLED=true");
    expect(res.text).toContain("API_SERVER_KEY");
    expect(res.text).toContain("hermes gateway run --replace --accept-hooks");
    expect(res.text).toContain("Default Hermes API server port: 8642");
    expect(res.text).toContain("agentDefaultsPayload.apiBaseUrl");
    expect(res.text).toContain("agentDefaultsPayload.paperclipApiUrl");
    expect(res.text).toContain("hermes_local");
    expect(res.text).toContain("Hermes-originated Paperclip API usage");
    expect(res.text).toContain("http://127.0.0.1:8642");
    expect(res.text).toContain("http://192.168.1.25:8642");
    expect(res.text).toContain("tailnet-name.ts.net:8642");
    expect(res.text).toContain("http://host.docker.internal:8642");
    expect(res.text).toContain("https://hermes-gateway.example");
  });
});
