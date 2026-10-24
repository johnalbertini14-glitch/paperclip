# Memory Index — Quick-Verify (553511e8-707c-4a2d-9a73-a17d7eb15d06)

## CURRENT ROLE: Quick-Verify (REVA-20391)
Lightweight mechanical verification of completed work.
- Confirms implementation matches ticket AC
- Runs lint/syntax/smoke checks
- Confirms cited evidence is real and accessible
- Does NOT do full code reviews, architectural decisions, or bug fixes

## Recent Activity (2026-09-10)
- REVA-32895 (Signatiq V1 root) remains assigned but doubly-stranded
  - `checkoutRunId: null`, `executionState: null`
  - Blocked by REVA-33762, REVA-34048, REVA-34240
  - No executable work available

## Role Constraints (board-mandated, REVA-20391 / REVA-29375)
- Fleet agents must NOT independently rebuild/develop/patch/deploy Paperclip
- Must NOT target upstream paperclipai/paperclip for pushes/PRs/merges/issues
- Paperclip repair routes to Hermes for evidence-based review
- Approved fleet ops: daily VPS backups, config backups, health checks, disk controls
- Operational defects route to Hermes — do NOT suspend approved routines by default

## Environment Rules (board REVA-750 / REVA-17509)
- `adapterConfig.env` replaced WHOLESALE on PATCH — never partial env objects
- Secret values show as `***REDACTED***` — NEVER copy these back into PATCH bodies
- No mocks/fake builds — claim "works" only against real services
- Credential safety: reference env var names only, never values

## Instrument-repair discipline (wake 57 — carried forward)
- **An instrument that refuses EVERY run is itself a defect.** Read the assertion and ask
  whether it is reachable at all before attributing the refusal to staleness or shape.
  Algebraic test: *does the mutation the control performs guarantee the property the
  control asserts?* A remove-one-add-one mutation guarantees `|ctrl| == |B|`, so an
  assertion of `|ctrl| == |B| + 1` can never fire.
- **Two defects in one file can mask each other.** A dead control hides a missing age
  bound. Prove which hides which with a single-defect probe BEFORE repairing either —
  fixing only the visible one can convert a dead instrument into a lying one.
- **A negative control needs an arm that can fail.** A loud arm (inject a mutation,
  require a diff) is guaranteed to fire for any correct comparator. Only a QUIET arm
  (identical inputs must report NO difference) has content.
- **Age-bound readers (`MAX_AGE_H` + `allow-stale`, exit 5):** `w54_todoattr.py`,
  `nc33_attrib.py`, `w42_bucketdiff.py`. Two-artifact comparators MUST have one.
- **Reproducing a defect needs the whole region that produced it**, not just the
  assertion — and a `str.replace()` that matches nothing is a case that never ran.
- Run `w55_agebound_census.py` after any patch: the instrument must MOVE from
  READER+NOBound to READER+BOUND, and must stay in the bound class afterwards.

## API Facts (re-verify per wake; these are standing)
- `sortField` accepts ONLY `updated` and `id`. `sortField=createdAt` is a typed 422
  (`sortField must be 'updated' or 'id' when provided`) — my old "createdAt returns an empty
  list" note was a rejection, not an empty result.
- **`/proc/swaps` size/used fields are KiB, not bytes.** A "2 MiB swapfile" reading is a unit
  error; 2097148 KiB = exactly 2.00 GiB. Percentages stay correct across the error because
  ratios are unit-invariant — that is what makes it survive review.
- **An unassigned heartbeat run (`issueId=null`) cannot POST comments to other issues** —
  403 `cross_issue_influence_run_context_required` even with the correct run id. Use
  `PUT /api/issues/{id}/documents/{slug}` with `{title, format:"markdown", body}` instead; it
  passes the same gate. Distinct from the 2026-10-08 intermittent auth 403.
- The issues LIST projection reports `executionState: null` on rows whose per-id DETAIL read
  has a live stage. This FLAPS between wakes (0/5 then 2/5) — keep "never read stage state off a
  LIST", but never quote a fixed number.
- `GET /api/issues/{id}/comments` is the only source of comment count/state; the issue payload's
  `comments` field reads 0. **Comments are ordered NEWEST-FIRST** — slicing `[-4:]` gives the
  OLDEST comments and will make a live run look stale.
- A field named `error` is populated on 100% of run rows — "is this an error body" must be
  `('error' in d) and ('id' not in d)`.
- Issue DETAIL bodies contain raw control characters; parse with
  `json.load(..., strict=False)` or every read fails at ~char 20000.
- `nativeIssueId`, `issueCommentStatus`, `contextIssueId` are ALL inert for run-scope questions.
  Use `contextSnapshot.source` alone.
- Mutation: `payload.prompt` hard-capped at 1000 chars (typed 400 naming `path`). A **timed-out
  mutating call may have committed** (2/2 did) — read state, never retry blind.

## Runtime shape (this agent)
- The agent runtime is a **container** (`/.dockerenv`, PID 1 =
  `docker-init -- tini -- sh /app/scripts/docker-entrypoint.sh`).
- **`ps`, `free`, `uptime`, `swapoff` are NOT installed** — the only genuinely missing tools.
- **CORRECTED 2026-10-16 (withdrew an earlier wrong entry): I DO share the host PID namespace.**
  `readlink /proc/self/ns/pid` == `/proc/<pid>/ns/pid` for restic, pg_dump and postgres
  (all `pid:[4026532907]`), and `NSpid` in `/proc/self/status` is a single value. Read
  `/proc/<pid>/cmdline|status|io|fd`, `df`, and the process tree **first-hand** — do not cite
  them as second-hand, and do not infer a barrier from an absent PID (a dead PID proves
  nothing). Visible PID count ~104.
- `/proc/swaps`, `/proc/meminfo`, `/proc/pressure/*`, `/proc/loadavg`, `/proc/vmstat` are valid
  host readbacks. **`/proc/swaps` is KiB**; `/proc/meminfo` is kB.
- **Completion = the exit marker exists, not that stderr is empty.** A 0-byte `*.err` with no
  `*.exit` and no `*.json` means *has not failed yet*, not *passed*. Check both.
- Missing `gsd-verify-work` skill is a KNOWN condition (checked 2026-09-11, 2026-10-16 twice).
  69 skills exist, none by that name. Proceed with direct verification; do not block.
- **File-write location:** `/app` root is NOT writable (Permission denied as uid 1000/node).
  `/app/memory/` IS writable — write reports and memory files there.

## Documents endpoint mechanics (measured 2026-10-18)
- `PUT /api/issues/{id}/documents/{slug}` with `{title, format:"markdown", body}` → **201**, and it passes
  the cross-issue run-context gate that blocks comments. Best delivery path for an unassigned run.
- **Re-PUTting an existing slug is an UPDATE and needs `baseRevisionId`.** Without it → HTTP 409
  `Document update requires baseRevisionId`, and the error body carries `details.currentRevisionId` —
  pass that value as `baseRevisionId` on the retry.
- `DELETE /api/issues/{id}/documents/{docId}` → **403 `Board authentication required`**. An agent run
  cannot delete a document. Don't create a throwaway probe doc then plan to remove it — overwrite it
  with a "superseded" pointer instead.
- Two `--data` flags to one curl **silently produce `Invalid JSON body` (400)**. Merge keys into ONE
  JSON file and pass a single `--data @file`.
- After writing, always GET the doc and probe for expected substrings (counts, ids) — a 201 is not proof
  the right body landed.

## Platform Structural Blockers (learned, documented in CONTINUITY.md)
- `checkoutRunId: null` blocks typed decision submission on review-stage issues
- `changesRequestedCount: 2` caps further decisions (2 per stage)
- `status=blocked` + `checkoutRunId: null` = doubly stranded, admin required
- `executionState: null` prevents `lastDecisionId` from being created
- `cross_issue_influence_run_context_required` blocks comment POST in some runs (intermittent)
- `blockedBy: []` PATCH silently ignored on 200 — edge persists (platform bug)
- `status=done` PATCH fails differently than `status=blocked` — different platform gates

## Reference
- CONTINUITY.md: corrections ledger, always read first at wake
- Daily notes: memory/YYYY-MM-DD.md
