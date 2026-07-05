import express from "express";
import request from "supertest";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ChatGatewayRateLimiter } from "../services/chat-gateway-rate-limit.js";
import { createChatGatewayRateLimiter } from "../services/chat-gateway-rate-limit.js";

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

async function createApp(
  actor: Record<string, unknown>,
  opts: { chatRateLimiter?: ChatGatewayRateLimiter } = {},
) {
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
  app.use("/api", llmRoutes({} as never, opts));
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
      ["exec", "--json", "--model", "gpt-5.4", "-"],
      expect.objectContaining({ cwd: expect.stringContaining("/paperclip/repos/paperclip") }),
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

  it("does not forward max_tokens, temperature, top_p, or stop as CLI flags (codex exec does not support them)", async () => {
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
    const spawnArgs = mockSpawn.mock.calls[0]?.[1] as string[];
    expect(spawnArgs).toEqual(["exec", "--json", "--model", "gpt-5.4", "-"]);
    // Assert that the unsupported flags are NOT present as a regression guard
    expect(spawnArgs).not.toContain("--max-tokens");
    expect(spawnArgs).not.toContain("--temperature");
    expect(spawnArgs).not.toContain("--top-p");
    expect(spawnArgs).not.toContain("--stop");
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

  it("rejects unauthenticated access with 403", async () => {
    const app = await createApp({
      type: "none",
    });

    const res = await request(app).post("/api/chat/completions").send({
      model: "gpt-5.4",
      messages: [{ role: "user", content: "hello" }],
    });

    expect(res.status).toBe(403);
    expect(res.body.error).toContain("Authenticated Paperclip access required");
  });

  it("rejects agent without canCreateAgents permission with 403", async () => {
    mockAgentService.getById.mockResolvedValueOnce({
      id: "agent-1",
      role: "researcher",
      permissions: { canCreateAgents: false },
    });

    const app = await createApp({
      type: "agent",
      agentId: "agent-1",
      role: "researcher",
      permissions: { canCreateAgents: false },
    });

    const res = await request(app).post("/api/chat/completions").send({
      model: "gpt-5.4",
      messages: [{ role: "user", content: "hello" }],
    });

    expect(res.status).toBe(403);
    expect(res.body.error).toContain("canCreateAgents permission");
  });

  it("rejects non-admin board actor with 403", async () => {
    const app = await createApp({
      type: "board",
      userId: "board-user",
      companyIds: ["company-1"],
      isInstanceAdmin: false,
    });

    const res = await request(app).post("/api/chat/completions").send({
      model: "gpt-5.4",
      messages: [{ role: "user", content: "hello" }],
    });

    expect(res.status).toBe(403);
    expect(res.body.error).toContain("Instance admin permission required");
  });

  it("rejects malformed JSON in request with 400", async () => {
    const app = await createApp({
      type: "board",
      userId: "board-user",
      companyIds: ["company-1"],
      source: "local_implicit",
      isInstanceAdmin: true,
    });

    const res = await request(app).post("/api/chat/completions").send({
      model: "gpt-5.4",
      messages: [{ role: "user", content: "hello" }],
      unknown_field: "should be rejected",
    });

    expect(res.status).toBe(400);
    expect(res.body.error).toContain("Invalid chat completion request");
  });

  it("surfaced error when codex exits with non-zero code", async () => {
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
        stderr.write("codex error: model not found\n");
        stdout.end();
        stderr.end();
        proc.emit("close", 1, null);
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
      messages: [{ role: "user", content: "hello" }],
    });

    expect(res.status).toBe(500);
    expect(res.body.error).toContain("codex error: model not found");
  });

  it("surfaces error when codex returns malformed JSON line", async () => {
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
        stdout.write("not-valid-json\n");
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
      messages: [{ role: "user", content: "hello" }],
    });

    expect(res.status).toBe(500);
    expect(res.body.error).toContain("codex output line is not valid JSON");
  });

  it("surfaces error when codex returns empty content", async () => {
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
      messages: [{ role: "user", content: "hello" }],
    });

    expect(res.status).toBe(500);
    expect(res.body.error).toContain("codex exec returned no assistant message");
  });

  it("surfaces error when codex spawn fails", async () => {
    mockSpawn.mockImplementationOnce(() => {
      throw new Error("codex executable not found");
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
      messages: [{ role: "user", content: "hello" }],
    });

    expect(res.status).toBe(500);
    expect(res.body.error).toContain("codex executable not found");
  });

  it("throttles repeated same-actor chat gateway calls with 429 and rate-limit headers", async () => {
    mockSpawn.mockImplementation(() => makeNoopProc());

    // 1 request per minute ceiling so the second call trips the limiter.
    const limiter = createChatGatewayRateLimiter({
      maxRequests: 1,
      windowMs: 60_000,
      now: () => 1_000,
    });

    const app = await createApp(
      {
        type: "board",
        userId: "board-user",
        companyIds: ["company-1"],
        source: "local_implicit",
        isInstanceAdmin: true,
      },
      { chatRateLimiter: limiter },
    );

    // Each chat call needs a spawn implementation that emits a usable
    // assistant message so the success path actually completes; otherwise
    // the 200 response never lands and we can't observe the headers.
    mockSpawn.mockImplementationOnce(() => {
      const stdout = new PassThrough();
      const stderr = new PassThrough();
      const stdin = new PassThrough();
      const proc = Object.assign(new EventEmitter(), {
        kill: vi.fn(),
        stdin,
        stdout,
        stderr,
      });
      queueMicrotask(() => {
        stdout.write(
          '{"type":"item.completed","item":{"type":"agent_message","text":"ok"}}\n',
        );
        stdout.write(
          '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}\n',
        );
        stdout.end();
        stderr.end();
        proc.emit("close", 0, null);
      });
      return proc as unknown as import("node:child_process").ChildProcess;
    });

    const first = await request(app).post("/api/chat/completions").send({
      model: "gpt-5.4",
      messages: [{ role: "user", content: "hello" }],
    });
    expect(first.status).toBe(200);
    expect(first.headers["x-ratelimit-limit"]).toBe("1");
    expect(first.headers["x-ratelimit-remaining"]).toBe("0");

    const limited = await request(app).post("/api/chat/completions").send({
      model: "gpt-5.4",
      messages: [{ role: "user", content: "hello" }],
    });
    expect(limited.status).toBe(429);
    expect(limited.body).toMatchObject({
      error: "Chat gateway rate limit exceeded",
      retryAfterSeconds: 60,
    });
    expect(limited.headers["retry-after"]).toBe("60");
    expect(limited.headers["x-ratelimit-remaining"]).toBe("0");

    // The second call must not have spawned a codex child — the limiter
    // runs before the schema parse and the codex spawn.
    expect(mockSpawn).toHaveBeenCalledTimes(1);
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
