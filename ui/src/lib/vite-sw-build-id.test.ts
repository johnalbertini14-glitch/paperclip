import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  SERVICE_WORKER_BUILD_ID_PLACEHOLDER,
  deriveBuildIdFromEntryFileName,
  stampServiceWorkerBuildId,
  writeStampedServiceWorker,
} from "./vite-sw-build-id";

const swSource = () =>
  `const BUILD_ID = "${SERVICE_WORKER_BUILD_ID_PLACEHOLDER}";\n` +
  "const CACHE_NAME = `paperclip-${BUILD_ID}`;\n";

describe("stampServiceWorkerBuildId", () => {
  it("replaces the placeholder with the build id and leaves no placeholder", () => {
    const out = stampServiceWorkerBuildId(swSource(), "index-abc123");
    expect(out).toContain("index-abc123");
    expect(out).not.toContain(SERVICE_WORKER_BUILD_ID_PLACEHOLDER);
  });

  it("produces different worker bytes for different build ids", () => {
    // This is the whole point: a new bundle -> a new sw.js -> a new worker ->
    // parked tabs reload. Identical build ids must stay byte-identical so the
    // worker does not churn when the app did not change.
    const a = stampServiceWorkerBuildId(swSource(), "index-aaaaaa");
    const b = stampServiceWorkerBuildId(swSource(), "index-bbbbbb");
    const again = stampServiceWorkerBuildId(swSource(), "index-aaaaaa");
    expect(a).not.toEqual(b);
    expect(a).toEqual(again);
  });

  it("throws when the placeholder is missing so a drifted worker fails the build", () => {
    expect(() => stampServiceWorkerBuildId("const CACHE_NAME = 'paperclip';", "x")).toThrow(
      /placeholder/,
    );
  });

  it("throws on an empty build id rather than shipping a nameless cache", () => {
    expect(() => stampServiceWorkerBuildId(swSource(), "")).toThrow();
  });
});

describe("deriveBuildIdFromEntryFileName", () => {
  it("uses the content-hashed entry file name", () => {
    expect(deriveBuildIdFromEntryFileName("assets/index-BHbrFFmp.js")).toBe("index-BHbrFFmp");
  });

  it("sanitizes characters that are unsafe in a cache name", () => {
    expect(deriveBuildIdFromEntryFileName("assets/index @weird!.js")).toBe("index--weird-");
  });
});

describe("clean service-worker build", () => {
  it("stamps an absent dist worker and remains safe if closeBundle runs twice", () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "paperclip-sw-build-"));
    try {
      const publicDir = path.join(dir, "public");
      const outDir = path.join(dir, "dist");
      fs.mkdirSync(publicDir);
      fs.writeFileSync(path.join(publicDir, "sw.js"), swSource());
      writeStampedServiceWorker(publicDir, outDir, "sw.js", "index-abc123");
      const first = fs.readFileSync(path.join(outDir, "sw.js"), "utf8");
      writeStampedServiceWorker(publicDir, outDir, "sw.js", "index-abc123");
      expect(fs.readFileSync(path.join(outDir, "sw.js"), "utf8")).toBe(first);
      expect(first).toContain("index-abc123");
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("public/sw.js contract", () => {
  it("still contains the placeholder the plugin rewrites", () => {
    const swPath = path.resolve(
      path.dirname(fileURLToPath(import.meta.url)),
      "../../public/sw.js",
    );
    const source = fs.readFileSync(swPath, "utf8");
    expect(source).toContain(SERVICE_WORKER_BUILD_ID_PLACEHOLDER);
  });
});
