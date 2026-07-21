import { logger } from "../middleware/logger.js";

const AGENT_START_LOCK_STALE_MS = 30_000;
const startLocksByAgent = new Map<string, { promise: Promise<void>; startedAtMs: number }>();

class AgentStartLockTimeoutError extends Error {
  constructor(agentId: string) {
    super(`Agent start lock timed out for ${agentId}`);
    this.name = "AgentStartLockTimeoutError";
  }
}

async function waitForAgentStartLock(
  agentId: string,
  lock: { promise: Promise<void>; startedAtMs: number },
): Promise<boolean> {
  const elapsedMs = Date.now() - lock.startedAtMs;
  const remainingMs = AGENT_START_LOCK_STALE_MS - elapsedMs;
  if (remainingMs <= 0) {
    logger.warn({ agentId, staleMs: elapsedMs }, "agent start lock stale; skipping queued-run start");
    return false;
  }

  let released = false;
  let timeout: ReturnType<typeof setTimeout> | null = null;
  await Promise.race([
    lock.promise.then(() => {
      released = true;
    }),
    new Promise<void>((resolve) => {
      timeout = setTimeout(resolve, remainingMs);
    }),
  ]);
  if (timeout) clearTimeout(timeout);

  if (!released) {
    logger.warn({ agentId, staleMs: AGENT_START_LOCK_STALE_MS }, "agent start lock timed out; skipping queued-run start");
    return false;
  }
  return true;
}

export async function withAgentStartLock<T>(agentId: string, fn: () => Promise<T>): Promise<T> {
  const previous = startLocksByAgent.get(agentId);
  if (previous) {
    const released = await waitForAgentStartLock(agentId, previous);
    if (!released) throw new AgentStartLockTimeoutError(agentId);

    if (startLocksByAgent.get(agentId)?.promise === previous.promise) {
      startLocksByAgent.delete(agentId);
    }
    return withAgentStartLock(agentId, fn);
  }

  const run = Promise.resolve().then(fn);
  const marker = run.then(
    () => undefined,
    () => undefined,
  );
  startLocksByAgent.set(agentId, { promise: marker, startedAtMs: Date.now() });
  try {
    return await run;
  } finally {
    if (startLocksByAgent.get(agentId)?.promise === marker) {
      startLocksByAgent.delete(agentId);
    }
  }
}
