import { randomUUID } from "node:crypto";
import { afterEach, describe, expect, it, vi } from "vitest";
import { withAgentStartLock } from "../services/agent-start-lock.ts";

describe("heartbeat agent start lock", () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it("fails closed when the previous start lock is stale", async () => {
    vi.useFakeTimers();

    const agentId = randomUUID();
    const firstStart = vi.fn(() => new Promise<void>(() => undefined));
    const secondStart = vi.fn(async () => "started");

    void withAgentStartLock(agentId, firstStart);
    await Promise.resolve();
    expect(firstStart).toHaveBeenCalledTimes(1);

    const secondStartResult = withAgentStartLock(agentId, secondStart);
    await Promise.resolve();
    expect(secondStart).not.toHaveBeenCalled();

    const secondStartRejection = expect(secondStartResult).rejects.toThrow("Agent start lock timed out");
    await vi.advanceTimersByTimeAsync(30_000);

    await secondStartRejection;
    expect(secondStart).not.toHaveBeenCalled();

    await expect(withAgentStartLock(agentId, secondStart)).rejects.toThrow("Agent start lock timed out");
    expect(secondStart).not.toHaveBeenCalled();
  });

  it("serializes starts after the previous lock releases", async () => {
    const agentId = randomUUID();
    let releaseFirst!: () => void;
    const firstStart = vi.fn(() => new Promise<void>((resolve) => {
      releaseFirst = resolve;
    }));
    const secondStart = vi.fn(async () => "started");

    const firstStartResult = withAgentStartLock(agentId, firstStart);
    await Promise.resolve();
    const secondStartResult = withAgentStartLock(agentId, secondStart);
    await Promise.resolve();
    expect(secondStart).not.toHaveBeenCalled();

    releaseFirst();

    await expect(firstStartResult).resolves.toBeUndefined();
    await expect(secondStartResult).resolves.toBe("started");
    expect(secondStart).toHaveBeenCalledTimes(1);
  });
});
