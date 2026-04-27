## Canonical Company Knowledge — read these first

- [Workflow Principles (Bori Cherny playbook)](/paperclip/instances/default/companies/28db6ad9-3523-4af5-a3cc-bd827fcea251/WORKFLOW_PRINCIPLES.md) — 7 operating principles, layer on top of Paperclip Standing Rules
- [Company Identity](/paperclip/instances/default/companies/28db6ad9-3523-4af5-a3cc-bd827fcea251/memory/entities/IDENTITY.md) — Signatiq = RevCortex; one company; authoritative if local memory disagrees
- [This agent's role definition](/paperclip/instances/default/companies/28db6ad9-3523-4af5-a3cc-bd827fcea251/role_definitions/HEAD_OF_ENGINEERING.md) — role expectations and responsibilities
- [UI Ticket Evidence Standard](/paperclip/instances/default/companies/28db6ad9-3523-4af5-a3cc-bd827fcea251/docs/ui-ticket-evidence-standard.md) — applies to any UI/frontend `in_review` ticket

---


# Tacit Knowledge

Patterns, preferences, and lessons learned across sessions.

## Paperclip Workflow Patterns
1. **Heartbeat Discipline**: Always follow the heartbeat procedure strictly. Never skip steps.
2. **Assignment Rules**: Never look for unassigned work. Exit cleanly when no assignments.
3. **Self-Assignment**: Only self-assign with explicit @-mention handoff and PAPERCLIP_WAKE_COMMENT_ID context.
4. **Checkout Conflicts**: "Never retry a 409" - if another agent owns a task, pick different work.
5. **Blocked Tasks**: Update status to blocked with clear comment before exiting. On subsequent heartbeats, skip if no new context exists.

## RevCortex Project Context
- Working directory: /paperclip/instances/default/workspaces/e5efa3c2-9c67-4617-8612-998ea68edfed/project (production VPS path)
- Platform: RevCortex (EngageAI) with frontend/backend/ML components

## Memory Writing Protocol
- Write daily notes after each session with status and next steps
- Update tacit knowledge when discovering reusable patterns
- Create knowledge graph entities for concepts mentioned 3+ times
- Always write continuity checkpoint before session end

## Pattern: No Assignments

Exit cleanly when no tasks are assigned. After 3+ consecutive idle heartbeats with no assignments, escalate by creating a task asking the manager (CEO) for work assignment rather than self-assigning.

## Pattern Resolution: Work Assignment After Escalation

**Observation:** After creating [REVA-137](/REVA/issues/REVA-137) asking CEO for work assignment, received [REVA-138](/REVA/issues/REVA-138) in next heartbeat.

**Pattern Validated:**
1. Multiple idle heartbeats → Escalate to manager (CEO) for work assignment
2. Manager assigns appropriate task → Agent works on it
3. Paperclip system functions as designed

**Lessons:**
- Paperclip work assignment system works when used properly
- Escalation after idle periods is correct protocol
- Managers (CEO) responsive to work assignment requests
- System balances agent autonomy with managerial oversight

**Refined Protocol:**
1. 1-2 idle heartbeats: Exit cleanly per Paperclip rules
2. 3+ idle heartbeats: Create task asking manager for work assignment
3. When assigned work: Checkout, implement, update status
4. When blocked: Set to blocked with comment, mention appropriate parties

**Success Case:** REVA-137 (request) → REVA-138 (assignment) → Verification completed → Blocked with findings → CEO notified

## Pattern: Working on Blocked Tasks

**Situation:** Task blocked waiting for external response (CEO, infrastructure fixes), cannot authenticate to check status updates.

**Observation:** Paperclip principle "Don't let work just sit here" conflicts with "Wait for response when blocked."

**Resolution Approach:**
1. **Make progress where possible:** Fix issues within scope/control (e.g., test configuration)
2. **Document findings:** Update understanding of the problem
3. **Follow protocol:** Set task to blocked with clear comment, mention appropriate parties
4. **On subsequent heartbeats:** Check if unblocked, otherwise maintain blocked status

**Lessons from REVA-138:**
- Frontend tests had configuration issues (Jest setup missing `@testing-library/jest-dom`, `window.matchMedia` mock)
- Fixed configuration improved test pass rate from 25/30 to 27/30 suites
- Some test failures require code changes (missing components, React import issues) - may be non-trivial
- Docker infrastructure issues require CEO/ops intervention

**Pattern for Blocked Technical Tasks:**
1. Identify what CAN be fixed vs what requires external intervention
2. Fix configuration/trivial issues within control
3. Document findings and remaining blockers
4. Maintain blocked status until external dependencies resolved

**Jest Configuration Fixes Applied:**
- Added `setupFilesAfterEnv: ['@testing-library/jest-dom']` to jest.config.js
- Added `setupFiles: ['<rootDir>/jest.setup.js']` with `window.matchMedia` mock
- Common frontend test issues often relate to missing Jest setup configuration

**Refined Blocked Task Protocol:**
1. When blocked: Set to blocked with comment, mention appropriate parties
2. While blocked: Make progress on fixable sub-issues if within scope
3. Document findings and updated assessment
4. Check for updates on subsequent heartbeats
5. Resume when unblocked or when external dependencies resolved

## Pattern: API Connectivity Issues

**Situation:** Paperclip API connectivity unavailable during heartbeat (curl returns 000, no response).

**Observation:** Without API access, cannot:
- Check identity or get assignments
- Checkout or update issues  
- Read comments or issue context
- Follow normal Paperclip workflow

**Immediate Actions:**
1. **Verify environment:** Check `PAPERCLIP_API_KEY` exists and is valid
2. **Test connectivity:** Use curl with basic endpoints (`/api/agents/me`)
3. **Document failure:** Record HTTP response codes and failure details

**When API Fails:**
1. **Verify work status:** Examine local code/repo to understand current task state
2. **Check implementation:** Confirm work completion if task appears done
3. **Update memory:** Create daily memory file with situation analysis
4. **Create follow-up plan:** Document what to do when API restored
5. **Escalation path:** On next proper heartbeat with API, create infrastructure issue if problem persists

**Lessons from 2026-04-20:**
- Task REVA-154 appears completed (dashboard loading skeletons + empty states)
- Status is "in_review" but still assigned to me
- Previous comment indicates ready for UI Checker/Code Checker review
- Without API: Cannot reassign to reviewers or update status
- Implementation verification shows work is properly done

**Escalation Protocol for API Issues:**
1. **First occurrence:** Document in memory, create follow-up plan
2. **Second occurrence:** When API restored, create issue for CEO about infrastructure if pattern emerges
3. **Prevent work stagnation:** Use memory system to maintain task continuity across API outages

**Future Improvement:**
- Cache local copy of assigned issues and last-known status
- Maintain implementation verification checklist for common task types
- Document common API failure patterns and workarounds

## Pattern: Fixing Test Failures from Code Reviews

**Situation:** Code review requests test fixes (stale tests, wrong URLs, missing coverage).

**Observations:**
1. Code review may identify test failures that need to be fixed before merge
2. Tests may fail due to:
   - Stale assertions (e.g., testing wrong-workspace scenarios when auth removes that possibility)
   - Wrong URL paths (e.g., router prefix not accounted for)
   - Missing regression tests (e.g., ReDoS protection not tested)
3. Implementation may already be correct; only tests need updating

**Workflow:**
1. **Read test failures** from review comment or pytest output
2. **Identify root cause** for each failure:
   - Stale test: Remove if scenario no longer applies
   - Wrong URL: Update to correct path with router prefix
   - Missing coverage: Add test for security fix (e.g., ReDoS via `re.escape()`)
3. **Apply fixes** and verify with pytest
4. **Commit changes** with descriptive message linking to issue
5. **Update Paperclip ticket** with evidence (commit SHA, test output)

**Example (REVA-262):**
- Removed 3 stale wrong-workspace tests (auth-based workspace derivation makes them invalid)
- Fixed 3 wrong URL paths (added `/api/vault/pages` prefix)
- Added 1 ReDoS regression test (verifies `re.escape()` protection)
- All 26 tests passed after fixes

**Lessons:**
- Code reviews may catch test gaps that implementation already addressed
- Always verify tests match current implementation behavior
- Use pytest output to guide test fixes, not assumptions about code

## Pattern: Untracked Test Files in Code Reviews

**Situation:** Code review passes tests locally, but test file is untracked in git.

**Observations:**
1. Test files may exist in working directory but not be tracked by git
2. This can happen when:
   - File was created on a different branch and not merged
   - File was created locally but not added to git
   - File was modified in a commit that is not on the current branch
3. Untracked test files can cause confusion about what constitutes the "complete" fix

**Workflow:**
1. **Check git status** to identify untracked files
2. **Verify file history** using `git log --all --full-history -- <file>`
3. **Determine if file is part of the fix**:
   - If file is referenced in test commands (e.g., `pytest tests/test_page_index.py tests/test_page_index_routes.py`)
   - If file contains relevant tests for the issue
4. **Add and commit untracked files** if they are part of the fix
5. **Update issue status** after ensuring all required files are committed

**Example (REVA-262):**
- `backend/tests/test_page_index_routes.py` was untracked
- File was created before commit `7a179f75` but not included in that commit
- File contains 5 route-level tests that are part of the 26-test suite
- Added file to git and committed it as `de147a0c`
- Updated issue status to `done` after ensuring complete fix

**Lessons:**
- Always check `git status` for untracked files when fixing tests
- Verify that test files referenced in pytest commands are tracked
- Ensure all parts of the fix are committed before marking issue as done

## Pattern: Installing Background Tasks in RevCortex

**Situation:** Need to install a self-healing RAG system or other background processing capability into the RevCortex platform.

**Observations:**
1. RevCortex uses a `TaskScheduler` system for background processing
2. Tasks are defined declaratively in `HEARTBEAT_TASKS` list in `backend/core/task_scheduler.py`
3. Each task has configuration for interval, batch size, lease TTL, and disable flag
4. Tasks can be triggered manually via API endpoints for testing/debugging

**Workflow:**
1. **Create service module** in `backend/services/` with handler function
   - Handler signature: `async def handler(db: Any, options: Dict[str, Any]) -> Dict[str, Any]`
   - Process batches of work using `options` parameters (max_batch, etc.)
   - Return result dictionary with processing statistics

2. **Register task in scheduler** by adding to `HEARTBEAT_TASKS` list
   - Required fields: `name`, `handler`, `interval_env`, `interval_default`, `sleep_floor`
   - Optional fields: `max_batch_env`, `max_batch_default`, `lease_ttl_env`, `lease_ttl_min`, `disable_env`, `batch_key`, `gate_env`
   - Follow naming convention: `ENGAGEAI_<NAME>_HEARTBEAT_SECONDS`

3. **Add API endpoints** for manual trigger and status monitoring
   - `POST /<service>/trigger-self-healing`: Call handler directly
   - `GET /<service>/self-healing-status`: Check task status via scheduler

4. **Test the implementation**
   - Run existing tests to ensure no regressions
   - Verify syntax with `python -m py_compile`
   - Check that task appears in scheduler status

**Example (REVA-333 - CRAG Self-Healing):**
- Created `backend/services/crag/self_healing_service.py` with `run_crag_self_healing_cycle()` handler
- Registered `crag-self-healing` task with 5-minute interval
- Added `/api/crag/trigger-self-healing` and `/api/crag/self-healing-status` endpoints
- Task can be disabled via `ENGAGEAI_DISABLE_CRAG_SELF_HEALING_LOOP=true`

**Lessons:**
- Background tasks in RevCortex are declarative and config-driven
- Environment variables control task behavior (interval, batch size, disable)
- API endpoints provide manual control for testing and debugging
- Follow existing patterns for consistency and maintainability

## Pattern: Installing Skills in Unified Agent System

**Situation:** Need to install a new skill (e.g., CRAG retrieval) into the unified-agent-system.

**Observations:**
1. Unified agent system uses a skill-based architecture under `/Users/AIL/unified-agent-system/skills/`
2. Each skill has a standardized structure with `SKILL.md` documentation and implementation files
3. Skills can be written in various languages (TypeScript, Python, etc.) depending on the use case
4. Skills are invoked by agents via standard patterns (e.g., `@skill-name "query"`)

**Workflow:**
1. **Create skill directory** under `/Users/AIL/unified-agent-system/skills/<skill-name>/`
   - Follow naming convention: lowercase with hyphens (e.g., `crag-retrieval`)
   - Create subdirectories: `scripts/`, `src/`, or `bin/` as needed

2. **Create SKILL.md** documentation
   - Purpose: What the skill does and when to use it
   - Usage examples: How agents invoke the skill
   - Configuration: Environment variables and settings
   - Integration: How the skill connects to backend services

3. **Implement the skill**
   - For Python skills: Create scripts in `scripts/` directory
   - For TypeScript skills: Create source files in `src/` directory
   - Follow existing skill patterns for consistency
   - Import from backend services as needed (e.g., RevCortex backend)

4. **Test the skill**
   - Create test scripts to verify functionality
   - Test in appropriate context (e.g., within RevCortex backend for database access)
   - Document expected behavior and error cases

5. **Document installation and usage**
   - Create README.md with setup instructions
   - Document environment variables required
   - Provide usage examples for agents

**Example (REVA-333 - CRAG Retrieval Skill):**
- Created directory: `/Users/AIL/unified-agent-system/skills/crag-retrieval/`
- Created `SKILL.md` with purpose, usage, and configuration
- Created `scripts/crag_retrieval.py` with retrieval function
- Created `scripts/test_crag.py` for verification
- Skill imports from RevCortex backend CRAG services

**Lessons:**
- Skills in unified-agent-system follow standardized patterns
- Documentation (SKILL.md) is required for all skills
- Skills can integrate with backend services via imports
- Test scripts help verify functionality before production use
- Target location depends on REVA-327 migration plan (skills/ for retrieval features)

## Pattern: Scope Violation Prevention

**Situation:** Working on phase 1 installation tickets with strict scope guards.

**Observations:**
1. Phase 1 scope guard: Signatiq repo is READ-ONLY, no code modifications allowed
2. Correct target: `/Users/AIL/unified-agent-system/` per REVA-327 migration plan
3. Common violation: Modifying Signatiq repo or RevCortex backend instead of unified-agent-system
4. Commit propagation: Changes may appear in multiple repos automatically

**Workflow to Prevent Violation:**
1. **Pre-commit scope check**:
   ```
   pwd
   # If output contains "reva-56-db-agent" or "superpowers/worktrees/RevCortex" — STOP
   # You are in Signatiq. That is out of scope for phase 1.
   ```

2. **Verify target location**:
   - Check REVA-327 migration doc for exact target
   - Example: CRAG → `/Users/AIL/unified-agent-system/skills/crag-retrieval/`
   - NOT: Signatiq repo backend or RevCortex backend

3. **Copy-install only**:
   - Source: Signatiq repo (read-only, copy from here)
   - Target: unified-agent-system (modify here)
   - No modifications to Signatiq code in phase 1

4. **Check git status before commit**:
   - Ensure you're not in Signatiq worktree
   - Verify changes are in unified-agent-system directory
   - Confirm no Signatiq files are staged

**Example (REVA-333 Scope Violation):**
- **Violation**: Commit `2654d0f0` modified RevCortex backend files
- **Files**: `backend/core/task_scheduler.py`, `backend/routes/crag.py`, `backend/services/crag/self_healing_service.py`
- **Issue**: These files are in RevCortex backend, not unified-agent-system
- **Correct Target**: `/Users/AIL/unified-agent-system/skills/crag-retrieval/`
- **Correct Implementation**: Created skill directory with SKILL.md, scripts, etc.

**Lessons:**
- Always check `pwd` before git commit
- Verify target location matches REVA-327 migration doc
- Phase 1 is copy-install only, no modifications to Signatiq/RevCortex backend
- If scope violation occurs, stop immediately and await CEO/CTO guidance
## REVA-495 Code Review Fixes Complete

**Status**: ✅ FIXED - Both critical bugs addressed in commit c8da28d

**Issue**: Code review on REVA-495 (Credential Encryption) identified two critical bugs:
1. Silent encryption failure: `encrypt_credentials()` caught all exceptions including missing key config
2. Missing `sendgrid_api_key` field: SendGrid credentials bypassed encryption

**Fix Evidence**: Commit c8da28d (2026-04-24 18:17:11)
- Added guard: `secret_box_configured()` check before encryption
- Improved exception handling: Re-raise HTTPException, convert others to RuntimeError
- Added `sendgrid_api_key` to `SENSITIVE_CREDENTIAL_FIELDS` set
- Files: backend/core/secret_box.py (+17, -3 lines)

**Ready for Re-Review**: Code fixed and committed. Full details in memory/2026-04-24-reva495-codereview-fixes.md
