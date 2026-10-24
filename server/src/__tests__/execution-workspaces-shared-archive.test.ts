import { execFile } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { promisify } from "node:util";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { eq } from "drizzle-orm";
import {
  activityLog,
  agents,
  companies,
  createDb,
  executionWorkspaces,
  heartbeatRuns,
  issueComments,
  issueRecoveryActions,
  issueReferenceMentions,
  issueWorkProducts,
  issues,
  projectWorkspaces,
  projects,
  workspaceRuntimeServices,
} from "@paperclipai/db";
import {
  getEmbeddedPostgresTestSupport,
  startEmbeddedPostgresTestDatabase,
} from "./helpers/embedded-postgres.js";
import { executionWorkspaceService } from "../services/execution-workspaces.ts";
import { cleanupExecutionWorkspaceArtifacts } from "../services/workspace-runtime.ts";

const execFileAsync = promisify(execFile);

const embeddedPostgresSupport = await getEmbeddedPostgresTestSupport();
const describeEmbeddedPostgres = embeddedPostgresSupport.supported ? describe : describe.skip;

if (!embeddedPostgresSupport.supported) {
  console.warn(
    `Skipping embedded Postgres shared-workspace archive tests on this host: ${embeddedPostgresSupport.reason ?? "unsupported environment"}`,
  );
}

async function runGit(cwd: string, args: string[]) {
  await execFileAsync("git", ["-C", cwd, ...args], { cwd });
}

async function createTempRepo() {
  const repoRoot = await fs.mkdtemp(path.join(os.tmpdir(), "paperclip-wsfix-"));
  await runGit(repoRoot, ["init"]);
  await runGit(repoRoot, ["config", "user.name", "Paperclip Test"]);
  await runGit(repoRoot, ["config", "user.email", "test@paperclip.local"]);
  await fs.writeFile(path.join(repoRoot, "README.md"), "# Test repo\n", "utf8");
  await runGit(repoRoot, ["add", "README.md"]);
  await runGit(repoRoot, ["commit", "-m", "Initial commit"]);
  await runGit(repoRoot, ["branch", "-M", "main"]);
  return repoRoot;
}

// WSARCH-1935: a shared_workspace session that points at project workspace
// infrastructure is archive-record-only. Its cwd is not a Git repository, so
// git inspection cannot succeed. The route itself says archiving only removes
// the session record, so the failed Git probe must not block the archive.
describeEmbeddedPostgres("shared workspace archive readiness", () => {
  let db!: ReturnType<typeof createDb>;
  let svc!: ReturnType<typeof executionWorkspaceService>;
  let tempDb: Awaited<ReturnType<typeof startEmbeddedPostgresTestDatabase>> | null = null;
  const tempDirs = new Set<string>();

  beforeAll(async () => {
    tempDb = await startEmbeddedPostgresTestDatabase("paperclip-wsfix-shared-archive-");
    db = createDb(tempDb.connectionString);
    svc = executionWorkspaceService(db, {
      resolvePullRequestDetails: async () => ({ state: "unknown", headRef: null, headSha: null }),
      workspaceReaperCooldownDays: 0,
    });
  }, 20_000);

  afterEach(async () => {
    await db.delete(workspaceRuntimeServices);
    await db.delete(activityLog);
    await db.delete(issueRecoveryActions);
    await db.delete(issueWorkProducts);
    await db.delete(issueReferenceMentions);
    await db.delete(issueComments);
    await db.delete(issues);
    await db.delete(executionWorkspaces);
    await db.delete(projectWorkspaces);
    await db.delete(projects);
    await db.delete(heartbeatRuns);
    await db.delete(agents);
    await db.delete(companies);
    for (const dir of tempDirs) {
      await fs.rm(dir, { recursive: true, force: true });
    }
    tempDirs.clear();
  });

  afterAll(async () => {
    await tempDb?.cleanup();
  });

  async function seedSharedNonGitSession(options: {
    createdByRuntime?: boolean;
  } = {}) {
    const companyId = randomUUID();
    const projectId = randomUUID();
    const projectWorkspaceId = randomUUID();
    const executionWorkspaceId = randomUUID();
    const nonGitPath = await fs.mkdtemp(path.join(os.tmpdir(), "paperclip-project-primary-"));
    tempDirs.add(nonGitPath);

    await db.insert(companies).values({
      id: companyId,
      name: "Paperclip",
      issuePrefix: "PAP",
      requireBoardApprovalForNewAgents: false,
    });
    await db.insert(projects).values({
      id: projectId,
      companyId,
      name: "Shared archive cohort",
      status: "in_progress",
      executionWorkspacePolicy: { enabled: true },
    });
    await db.insert(projectWorkspaces).values({
      id: projectWorkspaceId,
      companyId,
      projectId,
      name: "Primary",
      sourceType: "local_path",
      isPrimary: true,
      cwd: nonGitPath,
    });
    await db.insert(executionWorkspaces).values({
      id: executionWorkspaceId,
      companyId,
      projectId,
      projectWorkspaceId,
      mode: "shared_workspace",
      strategyType: "project_primary",
      name: "Shared workspace session",
      status: "active",
      providerType: "local_fs",
      cwd: nonGitPath,
      metadata: {
        source: "project_primary",
        createdByRuntime: options.createdByRuntime ?? false,
      },
    });

    return { companyId, projectId, projectWorkspaceId, executionWorkspaceId, nonGitPath };
  }

  // RED today: returns state "blocked" with the git-status blocker.
  it("keeps an archive-record-only shared session ready when its cwd is not a Git repository", async () => {
    const seeded = await seedSharedNonGitSession();

    // Prove the cwd really is not a Git repository, so the test exercises the
    // exact WSARCH-1935 path rather than a transient Git failure.
    await expect(
      execFileAsync("git", ["-C", seeded.nonGitPath, "rev-parse", "--show-toplevel"]),
    ).rejects.toThrow(/not a git repository/);

    const readiness = await svc.getCloseReadiness(seeded.executionWorkspaceId);

    expect(readiness).toMatchObject({
      workspaceId: seeded.executionWorkspaceId,
      state: "ready_with_warnings",
      isSharedWorkspace: true,
      isProjectPrimaryWorkspace: true,
      isDestructiveCloseAllowed: true,
    });
    expect(readiness?.blockingReasons).toEqual([]);
    expect(readiness?.warnings).toContain(
      "This shared workspace session points at project workspace infrastructure. Archiving it only removes the session record.",
    );
  }, 20_000);

  // Boundary guard: a real Git worktree keeps the existing fail-closed guard.
  it("still blocks a real Git worktree whose git status cannot be verified", async () => {
    const companyId = randomUUID();
    const projectId = randomUUID();
    const executionWorkspaceId = randomUUID();
    const repoRoot = await createTempRepo();
    tempDirs.add(repoRoot);
    const worktreePath = path.join(path.dirname(repoRoot), `paperclip-wsfix-worktree-${randomUUID()}`);
    tempDirs.add(worktreePath);
    await runGit(repoRoot, ["branch", `wsfix-${randomUUID().slice(0, 8)}`]);
    const branchName = (await execFileAsync("git", ["-C", repoRoot, "branch", "--format=%(refname:short)"]))
      .stdout.trim().split("\n").filter(Boolean).at(-1)!;
    await runGit(repoRoot, ["worktree", "add", worktreePath, branchName]);

    await db.insert(companies).values({
      id: companyId,
      name: "Paperclip",
      issuePrefix: "PAP",
      requireBoardApprovalForNewAgents: false,
    });
    await db.insert(projects).values({
      id: projectId,
      companyId,
      name: "Git worktree guard",
      status: "in_progress",
    });
    await db.insert(executionWorkspaces).values({
      id: executionWorkspaceId,
      companyId,
      projectId,
      mode: "isolated_workspace",
      strategyType: "git_worktree",
      name: "Real worktree",
      status: "active",
      cwd: worktreePath,
      providerRef: worktreePath,
      providerType: "git_worktree",
      repoUrl: "https://github.com/paperclipai/paperclip.git",
      baseRef: "main",
      branchName,
    });

    const scheduler = await import("../services/workspace-git-operation-scheduler.ts");
    const originalRun = scheduler.workspaceGitOperationScheduler.run.bind(
      scheduler.workspaceGitOperationScheduler,
    );
    const statusSpy = (await import("vitest")).vi
      .spyOn(scheduler.workspaceGitOperationScheduler, "run")
      .mockRejectedValue(new Error("scan queue unavailable"));

    try {
      const readiness = await svc.getCloseReadiness(executionWorkspaceId);

      expect(readiness).toMatchObject({
        state: "blocked",
        isDestructiveCloseAllowed: false,
        blockingReasons: [
          "Paperclip could not verify the workspace git status. Retry before destructive cleanup.",
        ],
      });
      await expect(fs.access(worktreePath)).resolves.toBeUndefined();
    } finally {
      statusSpy.mockRestore();
      void originalRun;
    }
  }, 20_000);

  // RED today: cleanup leaves the directory and returns cleaned=false, which
  // the archive path records as cleanup_failed.
  it("archives an operator-owned project_primary row without deleting its checkout directory", async () => {
    const seeded = await seedSharedNonGitSession({ createdByRuntime: false });

    const cleanup = await cleanupExecutionWorkspaceArtifacts({
      workspace: {
        id: seeded.executionWorkspaceId,
        cwd: seeded.nonGitPath,
        providerType: "local_fs",
        providerRef: null,
        branchName: null,
        repoUrl: null,
        baseRef: null,
        projectId: seeded.projectId,
        projectWorkspaceId: seeded.projectWorkspaceId,
        sourceIssueId: null,
        metadata: { source: "project_primary", createdByRuntime: false },
      },
      projectWorkspace: { cwd: seeded.nonGitPath, cleanupCommand: null },
    });

    expect(cleanup.cleaned).toBe(true);
    // The ownership boundary holds: the operator-owned checkout survives.
    await expect(fs.access(seeded.nonGitPath)).resolves.toBeUndefined();
    const entries = await fs.readdir(seeded.nonGitPath);
    expect(entries).toEqual([]);
  }, 20_000);

  // Ownership boundary guard: a runtime-created directory is still removed.
  it("still removes a runtime-created local_fs directory", async () => {
    const seeded = await seedSharedNonGitSession({ createdByRuntime: true });

    const cleanup = await cleanupExecutionWorkspaceArtifacts({
      workspace: {
        id: seeded.executionWorkspaceId,
        cwd: seeded.nonGitPath,
        providerType: "local_fs",
        providerRef: null,
        branchName: null,
        repoUrl: null,
        baseRef: null,
        projectId: seeded.projectId,
        projectWorkspaceId: seeded.projectWorkspaceId,
        sourceIssueId: null,
        metadata: { source: "project_primary", createdByRuntime: true },
      },
      projectWorkspace: { cwd: null, cleanupCommand: null },
    });

    expect(cleanup.cleaned).toBe(true);
    await expect(fs.access(seeded.nonGitPath)).rejects.toThrow();
  }, 20_000);
});