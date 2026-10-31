import { describe, expect, it, vi } from "vitest";
import { createAttentionRunProjectionMemo } from "../services/attention-run-projection.js";

const rows = [{ agentId: "a", runKey: "issue", createdAt: new Date(1) }];
function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

describe("attention run projection shared memo", () => {
  it("coalesces six identical callers; completed reads are immediately fresh", async () => {
    const memo = createAttentionRunProjectionMemo();
    const db = {};
    const gate = deferred<typeof rows>();
    const load = vi.fn(() => gate.promise);
    const requests = Array.from({ length: 6 }, () => memo(db, "company", "scope", load));
    expect(new Set(requests).size).toBe(1);
    await Promise.resolve();
    expect(load).toHaveBeenCalledTimes(1);
    gate.resolve(rows);
    expect(await Promise.all(requests)).toEqual(Array(6).fill(rows));
    expect(await memo(db, "company", "scope", load)).toBe(rows);
    expect(load).toHaveBeenCalledTimes(2);
  });

  it("serializes differing scopes in one company, without sharing results", async () => {
    const memo = createAttentionRunProjectionMemo();
    const db = {};
    const gate = deferred<typeof rows>();
    const second = vi.fn(async () => []);
    const first = memo(db, "company", "agent/key/date/null1", () => gate.promise);
    const next = memo(db, "company", "agent/key/date/null2", second);
    await Promise.resolve();
    expect(second).not.toHaveBeenCalled();
    gate.resolve(rows);
    expect(await first).toBe(rows);
    expect(await next).toEqual([]);
    expect(second).toHaveBeenCalledTimes(1);
  });

  it("isolates company and database identity without a global queue", async () => {
    const memo = createAttentionRunProjectionMemo();
    const db = {};
    const gate = deferred<typeof rows>();
    const first = memo(db, "one", "scope", () => gate.promise);
    expect(await memo(db, "two", "scope", async () => [])).toEqual([]);
    expect(await memo({}, "one", "scope", async () => [])).toEqual([]);
    gate.resolve(rows);
    expect(await first).toBe(rows);
  });

  it("does not cache errors or poison the serial queue", async () => {
    const memo = createAttentionRunProjectionMemo();
    const db = {};
    const error = new Error("scratch query failure");
    const failed = memo(db, "company", "scope", async () => { throw error; });
    const other = memo(db, "company", "other-scope", async () => rows);
    await expect(failed).rejects.toBe(error);
    expect(await other).toBe(rows);
    const retry = vi.fn(async () => []);
    expect(await memo(db, "company", "scope", retry)).toEqual([]);
    expect(retry).toHaveBeenCalledTimes(1);
  });

  it("does not extend freshness by the duration of a slow query", async () => {
    const memo = createAttentionRunProjectionMemo();
    const db = {};
    const gate = deferred<typeof rows>();
    const first = memo(db, "company", "scope", () => gate.promise);
    await Promise.resolve();
    gate.resolve(rows);
    await first;
    const fresh = vi.fn(async () => []);
    expect(await memo(db, "company", "scope", fresh)).toEqual([]);
    expect(fresh).toHaveBeenCalledTimes(1);
  });

  it("retains single-flight for a delayed in-flight query", async () => {
    const memo = createAttentionRunProjectionMemo();
    const db = {};
    const gate = deferred<typeof rows>();
    const first = memo(db, "company", "scope", () => gate.promise);
    await Promise.resolve();
    const load = vi.fn(async () => []);
    const second = memo(db, "company", "scope", load);
    expect(second).toBe(first);
    gate.resolve(rows);
    await second;
    expect(load).not.toHaveBeenCalled();
  });
});
