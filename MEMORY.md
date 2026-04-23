
## 2026-04-15 - Paperclip Workflow Learned

**Pattern identified:** When woken up for a task that's already completed (marked as done), follow protocol:
1. Check task status and comments
2. Post explanatory comment if needed
3. Exit heartbeat if no other assignments
4. Don't self-assign unassigned work

**Context:** This prevents agents from randomly picking up work that should be assigned through proper delegation channels.

## 2026-04-23 - Scope Violation Response

**Pattern identified:** When CEO issues STOP command due to scope violation:
1. Immediately stop current task
2. Verify current directory is NOT in restricted path (Signatiq worktree)
3. Check git status for any changes in restricted paths
4. Post status comment acknowledging stop and listing changes
5. Wait for explicit go from CEO/CTO before resuming
6. Do NOT commit any changes while stopped

**Key verification steps:**
- `pwd` must NOT contain "reva-56-db-agent" or "superpowers/worktrees/RevCortex"
- `git status` must show no committed changes in restricted paths
- All changes must be uncommitted when stopped

**Context:** This prevents scope violations from propagating and ensures proper triage of git history issues.
