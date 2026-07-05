import { randomUUID } from "node:crypto";
import { once } from "node:events";
import { spawn } from "node:child_process";
import { Router, type Request } from "express";
import type { Db } from "@paperclipai/db";
import { AGENT_ICON_NAMES } from "@paperclipai/shared";
import { z, ZodError } from "zod";
import { forbidden } from "../errors.js";
import { listServerAdapters } from "../adapters/index.js";
import { agentService } from "../services/agents.js";

function hasCreatePermission(agent: { role: string; permissions: Record<string, unknown> | null | undefined }) {
  if (!agent.permissions || typeof agent.permissions !== "object") return false;
  return Boolean((agent.permissions as Record<string, unknown>).canCreateAgents);
}

const chatCompletionMessageSchema = z.object({
  role: z.enum(["system", "user", "assistant", "tool"]),
  content: z.union([z.string(), z.array(z.unknown())]),
}).passthrough();

const chatCompletionRequestSchema = z.object({
  model: z.string().trim().min(1),
  messages: z.array(chatCompletionMessageSchema).min(1),
  max_tokens: z.number().int().positive().optional(),
  temperature: z.number().optional(),
  top_p: z.number().optional(),
  stop: z.union([z.string(), z.array(z.string())]).optional(),
}).passthrough();

function stringifyMessageContent(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) return JSON.stringify(content);
  if (content == null) return "";
  return String(content);
}

// Approved model lane — the false-done guard judge is the only intended caller.
const APPROVED_CHAT_MODEL = "gpt-5.4";

function buildCodexPrompt(messages: Array<{ role: string; content: unknown }>): string {
  const transcript = messages
    .map((message) => `${message.role.toUpperCase()}:\n${stringifyMessageContent(message.content)}`)
    .join("\n\n");
  return [
    "You are an OpenAI-compatible chat completion backend for Paperclip.",
    "Answer the latest user request directly.",
    "If the request asks for JSON, return only valid JSON.",
    "",
    transcript,
  ].join("\n");
}

interface ChatCompletionControls {
  max_tokens?: number;
  temperature?: number;
  top_p?: number;
  stop?: string | string[];
}

async function runCodexChatCompletion(input: {
  model: string;
  messages: Array<{ role: string; content: unknown }>;
  controls?: ChatCompletionControls;
  signal?: AbortSignal;
}): Promise<{ content: string; promptTokens: number; completionTokens: number }> {
  const here = new URL(".", import.meta.url);
  const repoRoot = new URL("../../../", here).pathname;

  const codexArgs = ["exec", "--json", "--model", input.model];
  if (input.controls?.max_tokens !== undefined) {
    codexArgs.push("--max-tokens", String(input.controls.max_tokens));
  }
  if (input.controls?.temperature !== undefined) {
    codexArgs.push("--temperature", String(input.controls.temperature));
  }
  if (input.controls?.top_p !== undefined) {
    codexArgs.push("--top-p", String(input.controls.top_p));
  }
  if (input.controls?.stop !== undefined) {
    const stops = Array.isArray(input.controls.stop) ? input.controls.stop : [input.controls.stop];
    for (const s of stops) {
      codexArgs.push("--stop", s);
    }
  }
  codexArgs.push("-");

  // Pass the AbortSignal so Node.js can auto-SIGKILL the child when the
  // signal is aborted.  Omit the key when no signal is provided so spawn
  // behaves as if the option were absent.
  const spawnOpts: {
    cwd: string;
    env: typeof process.env;
    stdio: ["pipe", "pipe", "pipe"];
    signal?: AbortSignal;
  } = {
    cwd: repoRoot,
    env: process.env,
    stdio: ["pipe", "pipe", "pipe"],
  };
  if (input.signal) {
    spawnOpts.signal = input.signal;
  }

  const proc = spawn("codex", codexArgs, spawnOpts);

  const stdoutChunks: string[] = [];
  const stderrChunks: string[] = [];
  const prompt = buildCodexPrompt(input.messages);

  proc.stdin.write(prompt);
  proc.stdin.end();

  proc.stdout.on("data", (chunk: Buffer) => {
    stdoutChunks.push(chunk.toString("utf8"));
  });
  proc.stderr.on("data", (chunk: Buffer) => {
    stderrChunks.push(chunk.toString("utf8"));
  });

  // Secondary SIGKILL cleanup for abort signals that fire after the process
  // has already exited — guards against the race where Promise.race resolves
  // and then the signal fires before we tear down.
  if (input.signal) {
    input.signal.addEventListener("abort", () => {
      proc.kill("SIGKILL");
    });
  }

  const closeArgs = await Promise.race([
    once(proc, "close"),
    once(proc, "error").then(([err]) => {
      throw err;
    }),
  ]) as [number | null, NodeJS.Signals | null];

  const exitCode = closeArgs[0];
  const stdout = stdoutChunks.join("");
  const stderr = stderrChunks.join("");
  if (exitCode !== 0) {
    throw new Error(
      stderr.trim() || `codex exec exited with code ${exitCode ?? "unknown"}`,
    );
  }

  let content = "";
  let promptTokens = 0;
  let completionTokens = 0;
  for (const rawLine of stdout.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line) continue;
    try {
      const event = JSON.parse(line) as { type?: string; item?: { type?: string; text?: unknown }; usage?: Record<string, unknown> };
      if (event.type === "item.completed" && event.item?.type === "agent_message" && typeof event.item.text === "string") {
        content = event.item.text.trim();
      } else if (event.type === "turn.completed" && event.usage) {
        const usage = event.usage;
        const inputTokens = Number(usage.input_tokens ?? 0);
        const outputTokens = Number(usage.output_tokens ?? 0);
        if (Number.isFinite(inputTokens)) promptTokens = Math.max(0, Math.floor(inputTokens));
        if (Number.isFinite(outputTokens)) completionTokens = Math.max(0, Math.floor(outputTokens));
      }
    } catch {
      if (!content) content = line;
    }
  }

  if (!content) {
    const fallback = stdout.trim();
    if (fallback) content = fallback.split(/\r?\n/).pop()!.trim();
  }
  if (!content) {
    throw new Error(stderr.trim() || "codex exec returned no assistant message");
  }

  return { content, promptTokens, completionTokens };
}

export function llmRoutes(db: Db) {
  const router = Router();
  const agentsSvc = agentService(db);

  async function assertCanRead(req: Request) {
    if (req.actor.type === "board") return;
    if (req.actor.type !== "agent" || !req.actor.agentId) {
      throw forbidden("Board or permitted agent authentication required");
    }
    const actorAgent = await agentsSvc.getById(req.actor.agentId);
    if (!actorAgent || !hasCreatePermission(actorAgent)) {
      throw forbidden("Missing permission to read agent configuration reflection");
    }
  }

  function assertCanUseChatGateway(req: Request) {
    if (req.actor.type === "none") {
      throw forbidden("Authenticated Paperclip access required");
    }
  }

  router.post("/chat/completions", async (req, res, next) => {
    try {
      assertCanUseChatGateway(req);
      const body = chatCompletionRequestSchema.parse(req.body);

      // Constrain to the approved lane only — widen only with explicit review.
      if (body.model !== APPROVED_CHAT_MODEL) {
        res.status(400).json({
          error: `Model not supported`,
          detail: `Only '${APPROVED_CHAT_MODEL}' is supported on this endpoint.`,
        });
        return;
      }

      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 60_000);

      const completion = await runCodexChatCompletion({
        model: body.model,
        messages: body.messages,
        controls: {
          max_tokens: body.max_tokens,
          temperature: body.temperature,
          top_p: body.top_p,
          stop: body.stop,
        },
        signal: controller.signal,
      });

      clearTimeout(timer);

      res.json({
        id: `chatcmpl-${randomUUID()}`,
        object: "chat.completion",
        created: Math.floor(Date.now() / 1000),
        model: body.model,
        choices: [
          {
            index: 0,
            message: { role: "assistant", content: completion.content },
            finish_reason: "stop",
          },
        ],
        usage: {
          prompt_tokens: completion.promptTokens,
          completion_tokens: completion.completionTokens,
          total_tokens: completion.promptTokens + completion.completionTokens,
        },
      });
    } catch (err) {
      if (err instanceof ZodError) {
        res.status(400).json({
          error: "Invalid chat completion request",
          details: err.issues.map((issue) => issue.message),
        });
        return;
      }
      next(err);
    }
  });

  router.get("/llms/agent-configuration.txt", async (req, res) => {
    await assertCanRead(req);
    const adapters = listServerAdapters().sort((a, b) => a.type.localeCompare(b.type));
    const lines = [
      "# Paperclip Agent Configuration Index",
      "",
      "Installed adapters:",
      ...adapters.map((adapter) => `- ${adapter.type}: /llms/agent-configuration/${adapter.type}.txt`),
      "",
      "Related API endpoints:",
      "- GET /api/companies/:companyId/agent-configurations",
      "- GET /api/agents/:id/configuration",
      "- POST /api/companies/:companyId/agent-hires",
      "",
      "Agent identity references:",
      "- GET /llms/agent-icons.txt",
      "",
      "Notes:",
      "- Sensitive values are redacted in configuration read APIs.",
      "- New hires may be created in pending_approval state depending on company settings.",
      "- Use the paperclip-create-agent skill for end-to-end hiring: adapter reflection, config comparison, instruction source selection, icon choice, desiredSkills, sourceIssueId/sourceIssueIds, and approval follow-up.",
      "- Timer heartbeats are opt-in for new hires. Leave runtimeConfig.heartbeat.enabled false unless the role truly needs scheduled work or the user explicitly asked for it.",
      "",
    ];
    res.type("text/plain").send(lines.join("\n"));
  });

  router.get("/llms/agent-icons.txt", async (req, res) => {
    await assertCanRead(req);
    const lines = [
      "# Paperclip Agent Icon Names",
      "",
      "Set the `icon` field on hire/create payloads to one of:",
      ...AGENT_ICON_NAMES.map((name) => `- ${name}`),
      "",
      "Example:",
      '{ "name": "SearchOps", "role": "researcher", "icon": "search" }',
      "",
    ];
    res.type("text/plain").send(lines.join("\n"));
  });

  router.get("/llms/agent-configuration/:adapterType.txt", async (req, res) => {
    await assertCanRead(req);
    const adapterType = req.params.adapterType as string;
    const adapter = listServerAdapters().find((entry) => entry.type === adapterType);
    if (!adapter) {
      res.status(404).type("text/plain").send(`Unknown adapter type: ${adapterType}`);
      return;
    }
    res
      .type("text/plain")
      .send(
        adapter.agentConfigurationDoc ??
          `# ${adapterType} agent configuration\n\nNo adapter-specific documentation registered.`,
      );
  });

  return router;
}
