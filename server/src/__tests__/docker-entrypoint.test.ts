import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { execFile } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

/**
 * Behavioral tests for scripts/docker-entrypoint.sh privilege handling
 * and env-precedence semantics.
 *
 * The entrypoint must support two deployment shapes with one image:
 *  - Docker Compose: container starts as root, remaps the node user to
 *    USER_UID/USER_GID and drops privileges via gosu.
 *  - Kubernetes restricted PodSecurity / OpenShift arbitrary UIDs: the
 *    container starts non-root, where neither the remap nor gosu can work,
 *    so the command must be exec'd directly (with a warning on mismatch).
 *
 * The system commands (id, usermod, groupmod, chown, gosu) are stubbed via
 * PATH so the branching logic runs unmodified on any host.
 *
 * REVA-21759 additions (was REVA-21732 findings):
 *  - The non-root startup must NOT loop forever on the stage-1 fallback.
 *    (Previous build re-execed with ENTRYPOINT_STAGE=node but the script
 *    read PAPERCLIP_ENTRYPOINT_STAGE - mismatch caused infinite re-exec.)
 *  - Process env must take precedence over the on-disk .env file.
 *    (Previous build used `set -a; . "$ENV_FILE"; set +a`, which
 *    auto-exports every variable from .env and silently overwrites
 *    the calling process env, contradicting the inline `override=false`
 *    comment.)
 */

const ENTRYPOINT = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..", "scripts", "docker-entrypoint.sh");

let stubDir: string;
let logFile: string;
let homeDir: string;

function writeStub(name: string, body: string) {
  const path = join(stubDir, name);
  writeFileSync(path, `#!/bin/sh\n${body}\n`, { mode: 0o755 });
}

function installIdStubs(ids: { uid: number; gid: number; nodeUid?: number; nodeGid?: number; supplementalGids?: number[] }) {
  writeStub(
    "id",
    [
      `if [ "$1" = "-u" ] && [ "$2" = "node" ]; then echo ${ids.nodeUid ?? 1000};`,
      `elif [ "$1" = "-g" ] && [ "$2" = "node" ]; then echo ${ids.nodeGid ?? 1000};`,
      `elif [ "$1" = "-u" ]; then echo ${ids.uid};`,
      `elif [ "$1" = "-g" ]; then echo ${ids.gid};`,
      `elif [ "$1" = "-G" ]; then echo ${(ids.supplementalGids ?? []).join(" ")};`,
      `else echo 0; fi`,
    ].join("\n"),
  );
}

function installPrivStubs() {
  for (const cmd of ["usermod", "groupmod", "chown"]) {
    writeStub(cmd, `echo "${cmd} $*" >> "${logFile}"`);
  }
  // setpriv preserves supplemental groups (unlike gosu which drops them).
  // The stub logs the call and then execs the rest of argv.
  writeStub("setpriv", `echo "setpriv $*" >> "${logFile}"\nshift\nshift\nshift\nshift\nshift\nshift\nshift\nexec "$@"`);
}

async function runEntrypoint(env: Record<string, string> = {}, cmd: string[] = ["echo", "ENTRYPOINT-CMD-RAN"]) {
  // Always point PAPERCLIP_HOME at the per-test temp dir so the .env
  // loader reads the test's own .env file rather than the host's
  // /paperclip/instances/default/.env.
  const fullEnv: Record<string, string> = {
    PATH: `${stubDir}:${process.env.PATH}`,
    PAPERCLIP_HOME: homeDir,
    ...env,
  };
  const result = await execFileAsync("sh", [ENTRYPOINT, ...cmd], {
    env: fullEnv,
    timeout: 10_000,
  });
  const calls = existsSync(logFile) ? readFileSync(logFile, "utf8") : "";
  return { stdout: result.stdout, stderr: result.stderr, calls };
}

function writeEnvFile(contents: string) {
  writeFileSync(join(homeDir, "instances", "default", ".env"), contents, { mode: 0o644 });
}

beforeEach(() => {
  stubDir = mkdtempSync(join(tmpdir(), "entrypoint-stubs-"));
  homeDir = mkdtempSync(join(tmpdir(), "entrypoint-home-"));
  // The entrypoint reads $PAPERCLIP_HOME/instances/<id>/.env.
  // Create the dir structure up front so the script doesn't skip the loader.
  const { mkdirSync } = require("node:fs") as typeof import("node:fs");
  mkdirSync(join(homeDir, "instances", "default", "services"), { recursive: true });
  logFile = join(stubDir, "calls.log");
});

afterEach(() => {
  rmSync(stubDir, { recursive: true, force: true });
  rmSync(homeDir, { recursive: true, force: true });
});

describe("docker-entrypoint.sh - privilege handling", () => {
  it("keeps the root-start privilege-drop flow with default UID/GID (Docker Compose)", async () => {
    installIdStubs({ uid: 0, gid: 0 });
    installPrivStubs();

    const { stdout, calls } = await runEntrypoint();

    expect(stdout).toContain("ENTRYPOINT-CMD-RAN");
    expect(calls).toContain("setpriv --reuid node --regid node");
    expect(calls).not.toContain("usermod");
    expect(calls).not.toContain("chown");
  });

  it("remaps the node user and chowns the home dir before privilege drop when root requests a different UID/GID", async () => {
    installIdStubs({ uid: 0, gid: 0 });
    installPrivStubs();

    const { stdout, calls } = await runEntrypoint({ USER_UID: "1001", USER_GID: "1001" });

    expect(stdout).toContain("ENTRYPOINT-CMD-RAN");
    expect(calls).toContain("usermod -o -u 1001 node");
    expect(calls).toContain("groupmod -o -g 1001 node");
    expect(calls).toContain(`chown -R node:node ${homeDir}`);
    expect(calls).toContain("setpriv --reuid node --regid node");
  });

  it("execs directly and silently when already running as the requested user (restricted PodSecurity)", async () => {
    installIdStubs({ uid: 1000, gid: 1000 });

    const { stdout, stderr, calls } = await runEntrypoint();

    expect(stdout).toContain("ENTRYPOINT-CMD-RAN");
    // No remap call, no gosu - we exec the CMD directly. The
    // mismatch-warning branch is skipped because we're already
    // running as the requested UID/GID.
    expect(calls).toBe("");
    // The stage-1 skip-remap warning fires once (informational).
    expect(stderr).toContain("skipping remap");
    // But the *secondary* warning (running unprivileged, cannot
    // remap to requested) does NOT fire because uid:gid matches.
    expect(stderr).not.toContain("running unprivileged");
  });

  // REVA-21759 - regression test for the infinite-loop bug.
  it("does NOT loop when running as an arbitrary non-root UID (OpenShift-style)", async () => {
    installIdStubs({ uid: 1234, gid: 1234 });

    // The previous build re-execed itself with ENTRYPOINT_STAGE=node,
    // but the script read PAPERCLIP_ENTRYPOINT_STAGE - so the next
    // iteration fell back to the default (root) and looped forever.
    // The fixed build does NOT re-exec; it falls through to stage 2
    // in the same process. We assert that by counting how many times
    // the "skipping remap" warning fires: it must be exactly 1.
    const { stdout, stderr, calls } = await runEntrypoint({ PAPERCLIP_ENTRYPOINT_STAGE: "root" });

    expect(stdout).toContain("ENTRYPOINT-CMD-RAN");
    expect(calls).toBe("");
    // The skip-remap warning must appear exactly once (not in a loop).
    const skipMatches = stderr.match(/skipping remap/g) ?? [];
    expect(skipMatches.length).toBe(1);
    // And the secondary unprivileged warning still fires once.
    expect(stderr).toContain("running unprivileged as 1234:1234");
    expect(stderr).toContain("expected 1000:1000");
  });

  it("execs directly with a warning on a non-root GID mismatch", async () => {
    installIdStubs({ uid: 1000, gid: 1001 });

    const { stdout, stderr, calls } = await runEntrypoint();

    expect(stdout).toContain("ENTRYPOINT-CMD-RAN");
    expect(calls).toBe("");
    expect(stderr).toContain("running unprivileged as 1000:1001");
    expect(stderr).toContain("expected 1000:1000");
  });

  // REVA-24018 - supplemental group preservation regression test.
  // gosu drops supplemental groups when dropping privileges; setpriv
  // preserves them. We stub `id -G` to return a supplemental group
  // (988 = docker socket group) and assert that setpriv receives it
  // in its --groups argument rather than being called without one.
  it("preserves supplemental groups when dropping privileges (docker socket group)", async () => {
    installIdStubs({ uid: 0, gid: 0, supplementalGids: [988] });
    installPrivStubs();

    const { stdout, calls } = await runEntrypoint();

    expect(stdout).toContain("ENTRYPOINT-CMD-RAN");
    // The setpriv call must include --groups with the supplemental group.
    // This is the core regression test: gosu does not pass --groups,
    // so it drops supplemental groups. setpriv with --groups preserves them.
    expect(calls).toContain("setpriv --reuid node --regid node --groups");
    expect(calls).toContain("988");
    expect(calls).not.toContain("usermod");
    expect(calls).not.toContain("chown");
  });
});

describe("docker-entrypoint.sh - env precedence", () => {
  // REVA-21759 - regression test for the override=false bug.
  // The previous build used `set -a; . "$ENV_FILE"; set +a`, which
  // exports every variable from .env and silently overwrites the
  // calling process env. We assert process env wins here.
  it("process env wins over .env when both define the same key", async () => {
    installIdStubs({ uid: 1000, gid: 1000 });
    writeEnvFile("PAPERCLIP_TEST_KEY=from_file\n");

    const { stdout } = await runEntrypoint(
      { PAPERCLIP_ENTRYPOINT_STAGE: "node", PAPERCLIP_TEST_KEY: "from_env" },
      ["sh", "-c", "echo PAPERCLIP_TEST_KEY=$PAPERCLIP_TEST_KEY"],
    );

    expect(stdout).toContain("PAPERCLIP_TEST_KEY=from_env");
    expect(stdout).not.toContain("PAPERCLIP_TEST_KEY=from_file");
  });

  it(".env provides the value when process env does not define the key", async () => {
    installIdStubs({ uid: 1000, gid: 1000 });
    writeEnvFile("PAPERCLIP_TEST_KEY=from_file\n");

    const { stdout } = await runEntrypoint(
      { PAPERCLIP_ENTRYPOINT_STAGE: "node" },
      ["sh", "-c", "echo PAPERCLIP_TEST_KEY=$PAPERCLIP_TEST_KEY"],
    );

    expect(stdout).toContain("PAPERCLIP_TEST_KEY=from_file");
  });

  it("comments and quoted values in .env are handled correctly", async () => {
    installIdStubs({ uid: 1000, gid: 1000 });
    writeEnvFile(
      [
        "# this is a comment",
        "PAPERCLIP_PLAIN=plain_value",
        'PAPERCLIP_DQUOTED="double quoted value"',
        "PAPERCLIP_SQUOTED='single quoted value'",
        "",
      ].join("\n"),
    );

    const { stdout } = await runEntrypoint(
      { PAPERCLIP_ENTRYPOINT_STAGE: "node" },
      [
        "sh",
        "-c",
        "echo PLAIN=$PAPERCLIP_PLAIN; echo DQUOTED=$PAPERCLIP_DQUOTED; echo SQUOTED=$PAPERCLIP_SQUOTED",
      ],
    );

    expect(stdout).toContain("PLAIN=plain_value");
    expect(stdout).toContain("DQUOTED=double quoted value");
    expect(stdout).toContain("SQUOTED=single quoted value");
  });

  // REVA-22194 - regression test for the digit-prefixed-key crash.
  // The previous build's case-statement filter only checked the *rest*
  // of the key against [A-Za-z0-9_], so a key like `1BAD=value`
  // passed the filter. The subsequent `eval "[ -z \"\${${_key}+x}\" ]"`
  // then died with `Bad substitution` because POSIX variable names
  // must begin with a letter or underscore. The fix adds a
  // leading-character gate so invalid POSIX identifiers are skipped
  // silently while neighbouring valid keys still load.
  it("skips digit-prefixed keys instead of crashing the eval", async () => {
    installIdStubs({ uid: 1000, gid: 1000 });
    writeEnvFile("1BAD=value\nPAPERCLIP_VALID=ok\n");

    const { stdout, stderr } = await runEntrypoint(
      { PAPERCLIP_ENTRYPOINT_STAGE: "node" },
      ["sh", "-c", "echo VALID=[${PAPERCLIP_VALID-}]"],
    );

    expect(stdout).toContain("VALID=[ok]");
    expect(stderr).not.toContain("Bad substitution");
  });

  it("skips hyphenated keys (regression lock for the existing charset gate)", async () => {
    installIdStubs({ uid: 1000, gid: 1000 });
    writeEnvFile("HAS-HYPHEN=value\nPAPERCLIP_VALID=ok\n");

    const { stdout, stderr } = await runEntrypoint(
      { PAPERCLIP_ENTRYPOINT_STAGE: "node" },
      ["sh", "-c", "echo VALID=[${PAPERCLIP_VALID-}]"],
    );

    expect(stdout).toContain("VALID=[ok]");
    expect(stderr).not.toContain("Bad substitution");
  });

  it("still loads keys with a leading underscore (POSIX-valid identifiers)", async () => {
    installIdStubs({ uid: 1000, gid: 1000 });
    writeEnvFile("PAPERCLIP_UNDERSCORE_FIRST=ok\n");

    const { stdout } = await runEntrypoint(
      { PAPERCLIP_ENTRYPOINT_STAGE: "node" },
      ["sh", "-c", "echo U=[${PAPERCLIP_UNDERSCORE_FIRST-}]"],
    );

    expect(stdout).toContain("U=[ok]");
  });
});