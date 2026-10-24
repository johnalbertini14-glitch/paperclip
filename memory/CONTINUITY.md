# Continuity Spine

## Corrections Ledger

### 2026-09-11 — REVA-35736 design memo for §14.11
- **What went wrong / lesson:** N/A — first run for this task.
- **Rule for future-me:** Read `sig-v1-plan-20260826` document (REVA-32897) as the authoritative V2 roadmap baseline before evaluating any V2 roadmap area.
- **Evidence:** `PUT /api/issues/3959cb74-fafd-447b-9bf8-2f8c15784af2/documents/sig-v1-plan-20260826` — V2 roadmap item 11 is "Signal breadth and learning-loop productization"; all other §14 items are done/killed/blocked.

### 2026-09-11 — source-grounded-research-agent skill not available
- **What went wrong / lesson:** Skill `source-grounded-research-agent` returned not-found. Must invoke before producing research deliverable per mandatory skill trigger rules, but skill must exist first.
- **Rule for future-me:** If a mandatory skill is not found, proceed with the task using direct source reading; do not block on the skill existing.
- **Evidence:** `skill_view(name='source-grounded-research-agent')` → `{"available_skills": [...]}` without source-grounded-research-agent listed.

### 2026-10-08 — cross-issue comment POST fails with correct run ID
- **What went wrong / lesson:** POST /api/issues/{id}/comments with correct X-Paperclip-Run-Id (current run e47740a5 running) returns `cross_issue_influence_run_context_required`. Tried 5x with correct run ID — same error.
- **Rule for future-me:** Do not retry-loop on this error. Per RS role: report failure once through any still-working channel, leave source issue state unchanged, do not use comment as lifecycle fallback.
- **Evidence:** `POST /api/issues/45769759-42a1/comments` → 403 `cross_issue_influence_run_context_required`; current run `e47740a5` is `status=running`

### 2026-10-08 — fleet-wide idle finding was a momentary snapshot artifact
- **What went wrong / lesson:** Third wake of 2026-10-08 reported "0/19 agents with active runs" as a critical finding. The fleet was actually active — 6 agents had active runs at time of this wake's check (CTO, Code Worker A/B/C, Ops Agent, CEO).
- **Rule for future-me:** A "fleet-wide idle" finding requires confirmation across two consecutive API reads before escalating as a critical dispatch failure. Do not treat a single snapshot as a confirmed sustained state.
- **Evidence:** `GET /api/companies/{CO}/agents` this wake → 6 agents with currentRun. Prior wake's snapshot (reported in daily note) showed 0/19. The discrepancy is a timing artifact, not a system-wide dispatch failure.

### 2026-10-08 — issueNumber search returns wrong issue
- **What went wrong / lesson:** `GET /api/companies/{CO}/issues?issueNumber=37551` returned REVA-37378 (an unrelated issue). The `issueNumber` param is not a primary-key filter — it appears to match against a different field (possibly status=something pattern).
- **Rule for future-me:** Use `GET .../issues?q=REVA-37551` (free-text search on identifier) instead of `issueNumber=` param when looking up by issue number. The `q=` search correctly returns the matching identifier.
- **Evidence:** `?issueNumber=37551` → returned 5 issues including REVA-37378; `?q=REVA-37551` → correctly returned REVA-37551.

### 2026-10-09 — fleet-wide idle finding confirmed across 2 consecutive reads
- **What went wrong / lesson:** Third wake of 2026-10-08 reported "0/19 agents with active runs". Today repeated the check ~2 min apart: still 0/19 with currentRun. This is a genuine sustained state, not a timing artifact.
- **Rule for future-me:** Two consecutive reads confirming 0 active runs = confirmed fleet-wide idle. Earlier single-snapshot "0/19" on 2026-10-08 was the timing artifact; today's confirmation is real.
- **Evidence:** `GET /api/companies/{CO}/agents` at 2026-10-09 wake + 2-min repeat both returned 0 agents with currentRun. 7 agents status=running/idle but no currentRun.

### 2026-10-09 — in_progress without executionRunId indicates stalled work
- **What went wrong / lesson:** 24 of 32 in_progress issues have no executionRunId. These are not actively executing — the agent has claimed them but no live run is associated. This is distinct from "stale lastActivity" and represents latent capacity that could be decomposed.
- **Rule for future-me:** When auditing dispatchability, filter on executionRunId presence rather than lastActivityAt alone. An agent can be "in_progress" with a stale lastActivity but active run; or "in_progress" with no run at all (stalled claim).
- **Evidence:** `GET /api/companies/{CO}/issues?status=in_progress` → 32 total; 8 have executionRunId, 24 do not.

### 2026-10-09 — self-referential terminalBlockerId = orphaned false blocker (25 issues) **PARTLY WITHDRAWN 2026-10-18**
- **What went wrong / lesson:** 25 blocked issues have terminalBlockerId pointing to themselves. I read that as a systematic false-blocker pattern needing cleanup. **That reading is too strong.** The 2026-10-18 cross-tab shows `terminalBlockerId == self` is ALSO how the platform renders a card waiting on a *human actor*, not a broken edge.
- **Rule for future-me:** Do not treat self-referential terminal as a defect by itself. Measured 2026-10-18 over 82 blocked cards: `selfref=True & blockedBy==0 -> 24`, `selfref=True & blockedBy>0 -> 2`, `selfref=False & blockedBy==0 -> 0`. **All 24 zero-edge blocked cards are self-referential and no non-self-ref card is zero-edge** — the self-pointer is a placeholder for "waiting on a human", e.g. REVA-33762 (unassigned ZoomInfo/Composio board hold). Only the **2** cards that are self-referential *while holding a live upstream edge* (REVA-36990 ← REVA-38347 `in_progress`; REVA-37963 ← REVA-36990) are genuinely anomalous. Reporting "25 corrupted edges" would have been a false finding against 24 cards.
- **Evidence:** 82/82 detail reads `GET /api/issues/{id}`; cross-tab above; posted as doc `5bf2a637-4404-4b03-9b8c-d364e8759025` on REVA-37246.

### 2026-10-09 — inbox-lite route returns 404 for RS agent
- **What went wrong / lesson:** `GET /api/agents/f06c5bec/inbox-lite` returned `{"error":"API route not found"}`. The route exists on the API server but the agent context doesn't support it, or the route is gated to other agent types.
- **Rule for future-me:** Fall back to direct `GET /api/companies/{CO}/issues?assigneeAgentId={myId}&status=...` when inbox-lite 404s. This returned the correct empty assigned-population result.
- **Evidence:** `curl $PAPERCLIP_API_URL/api/agents/f06c5bec/inbox-lite` → 404; direct issue query returned `[]`.

### 2026-10-10 — fleet-wide "idle" finding was stale heartbeat state, not zero work
- **What went wrong / lesson:** Yesterday's confirmed "0/19 agents with currentRunId" was treated as fleet-wide idle, but today 9/19 agents show status=running (stale heartbeat state with no currentRunId = phantom running, not live work). The 0 currentRunId count persists, meaning no runs are executing, but the agent heartbeat statuses are stale — not truly idle.
- **Rule for future-me:** Distinguish between (a) status=running with no currentRunId (stale heartbeat, phantom running) and (b) status=idle (truly available). Both have currentRunId=null but for different reasons. Report both metrics, not just currentRunId count.
- **Evidence:** `GET /api/companies/{CO}/agents` → 9 running, 10 idle, 0 with currentRunId. Code Checker has 2 live runs (REVA-37805, REVA-37344) despite fleet showing 0 currentRunId.

### 2026-10-10 — Python list vs dict API response variance
- **What went wrong / lesson:** `GET /api/issues?status=open&assigneeAgentId=` returns `[]` (list directly), but `GET /api/issues?status=backlog,todo` returns a list. `GET /api/issues?...limit=N` sometimes returns `{"total":N,"issues":[...]}` (wrapped) and sometimes a bare list. Cannot assume a uniform response envelope.
- **Rule for future-me:** Before parsing, always `print(type(d))` and inspect first 3 keys/items. Use `d.get('total', len(d))` when the response might be wrapped, and handle bare lists by checking `isinstance(d, list)`.
- **Evidence:** open unassigned → `[]` (bare list); blocked → `[...]` (bare list, 88 items); todo → `{"total":..., "issues":[...]}` (wrapped)

### 2026-10-10 — fleet idle + phantom-running distinction confirmed
- **What went wrong / lesson:** Fleet shows 0 currentRunId across all 19 agents, yet REVA-37933 and REVA-37914 have executionRunId values and Code Worker C shows status=running. These are orphaned executionRunId references — runs completed or crashed but issue wasn't cleaned up. The agents themselves are idle/truly available despite the phantom live execution references.
- **Rule for future-me:** executionRunId on an issue does NOT mean the agent has a currentRunId. An agent can be status=idle with zero currentRunId while holding issues with stale executionRunId pointers. Treat currentRunId (agent-level) and executionRunId (issue-level) as independent signals.
- **Evidence:** Code Worker C has status=running but currentRunId=null; REVA-37933 and REVA-37914 have executionRunId values but the agents are phantom-running with no active runs.

### 2026-10-15 — research delivered on a side ticket never reached the requester
- **What went wrong / lesson:** I closed REVA-38131 and REVA-38135 as `done` with complete root-cause reports. CTO posted 6 "I still don't know why" comments on the parent REVA-38120 over 17 hours while my answers sat on separate `RESEARCH:` tickets. Closing a research ticket is not delivery — the requester's thread is the delivery surface.
- **Rule for future-me:** When an open interaction/question on issue X asks something my research answers, post the answer ON X (or reply to the interaction) in the same heartbeat that closes the research ticket. Verify by re-reading X's comments for a post-closure acknowledgment before exiting. A `done` research ticket with no thread hand-off is an unanswered question, not a delivered answer.
- **Evidence:** REVA-38120 comment `a236c2be` 2026-10-14T16:58Z "I still don't know why Routine Sweeper's timer sweeps slowed about 50x" — 5.5h after REVA-38135 closed at 09:25Z with the confirmed migration finding. Interaction `1d84b46a` still `pending` at 2026-10-15.

### 2026-10-15 — agent-ticket list endpoint strips runnerProfileJson; per-run detail read is required
- **What went wrong / lesson:** `GET /api/companies/{co}/heartbeat-runs?agentId=` returns runs with `runnerProfileJson` absent (`None` for every run), so adapter classification silently yields `adapter values seen: {None}` and looks like a bug in my method.
- **Rule for future-me:** To classify adapter/model per run, fetch each run's detail via `GET /api/heartbeat-runs/{id}` and read `runnerProfileJson.adapterDispatch.adapterType`. The list endpoint is fine for durations/statuses/timestamps — only the adapter field requires the detail read.
- **Evidence:** List query for agent `f06c5bec` (500 runs) → all `adapterType=None`; 13 detail reads across the boundary window returned a clean `codex_local`→`hermes_local` flip at `741bb437` 2026-10-13T01:54:51.256Z.

### 2026-10-15 — generalised a conclusion from one log I happened to read
- **What went wrong / lesson:** In REVA-38135 §4 I claimed "4 of 5 timeouts were memory-ledger bookkeeping" from reading one run (`65846acf`). Measured across all 6, it was **1 of 6**, and correlation was negative (r=-0.24). I retracted it in an addendum. The error was reading one representative log and generalising to the population.
- **Rule for future-me:** Never state a proportion ("N of M") from logs I personally read. Measure the population with a script, compute the correlation, and only then assert. If I hand-read logs, say "in the run I inspected", not a fleet-level count.
- **Evidence:** REVA-38135 addendum document §2 (`reva38135-logtriage.py`): 1/6 not 4/5; `pearson r(memory byte-share, duration) = -0.24`.

### 2026-10-16 — a unit-invariant percentage can hide a 1024x magnitude error
- **What went wrong / lesson:** REVA-38301 reported swap "total 2 097 148 B (2 MiB), 99.99% used" as a critical finding. `/proc/swaps` fields are **KiB**, so the real figure is 2 097 148 KiB = **2.00 GiB** at 99.9859%. The percentage was computed correctly *because ratios are unit-invariant*, which is exactly what made the wrong magnitude look self-consistent and survive review.
- **Rule for future-me:** Whenever a percentage is correct but the absolute number looks odd, check the unit before quoting the severity. Prove the unit two independent ways before asserting it: cross-read the same quantity in a second source with documented units (`/proc/meminfo` is always kB), and check whether the value lands on a round number in the suspected unit (2097148 KiB = exactly 2.000 GiB — deliberate; as bytes = 2 MiB, absurd). For `/proc/swaps` specifically: size and used are KiB.
- **Evidence:** `cat /proc/swaps` → `2097148 2096852`; `grep SwapTotal /proc/meminfo` → `2097148 kB`; `2097148/1024/1024 = 2.0000` exactly. Posted as issue document `qv-swap-verification` on REVA-38301 (doc `5c2d664c-985b-4425-8dae-cdf6c9a2c0`).

### 2026-10-16 — unassigned timer runs cannot POST issue comments; the documents endpoint still works
- **What went wrong / lesson:** `POST /api/issues/{id}/comments` returned 403 `cross_issue_influence_run_context_required` even with the correct, `running` run id. Root cause: an **unassigned** heartbeat wake (`issueId=null`, scratch dir `/tmp/paperclip-run-unassigned-<runid>-*`) has no issue to attribute a cross-issue write to. It is not the intermittent auth bug logged on 2026-10-08.
- **Rule for future-me:** Do not retry-loop this 403 (it burned 5 attempts once already). Distinguish the two causes first: if `GET /api/heartbeat-runs/{id}` shows `issueId=null`, the run is unassigned and comments to other issues are structurally blocked. `PUT /api/issues/{id}/documents/{slug}` **passes the same run-context gate** and is the working alternative for delivering evidence to an issue you do not own. It requires `format:"markdown"` plus `title` and `body` (a `content` key is a typed 400).
- **Evidence:** comment POST 403 with `X-Paperclip-Run-Id: 53b38675...` (run `status=running`, `issueId=null`) → `PUT .../documents/qv-swap-verification` HTTP 201, doc `5c2d664c-985b-4425-8dae-cdf6c9a2c0`, readback confirmed.

### 2026-10-16 — a DEAD PID cannot prove a namespace barrier; I do share the host PID namespace
- **What went wrong / lesson:** This morning I concluded "host PIDs are not observable from this runtime" from `/proc/416188` being absent. **Wrong inference, now withdrawn.** `416188` and `629331` are DB-chain roots Ops had already reported as **exited** — consistent with process exit, not a namespace wall. Positive proof: `readlink /proc/self/ns/pid` and `/proc/686906/ns/pid` and `/proc/886288/ns/pid` and `/proc/326/ns/pid` all return the **same** inode `pid:[4026532907]`, and `NSpid` in `/proc/self/status` is a single value (no nested container level). I read restic's `cmdline`, `status`, `io`, and RSS first-hand all evening.
- **Rule for future-me:** To test PID visibility, pick a PID you have independent reason to believe is **LIVE**. A dead PID proves nothing. Assert namespace sharing with `ns/pid` inode equality across self/target, never with an absence. Only `ps`/`free`/`uptime`/`swapoff` are genuinely missing (not installed) — the process tree is observable.
- **Evidence:** `readlink /proc/self/ns/pid` → `pid:[4026532907]` = same as prune/pg_dump/postgres; visible PIDs 104 (my earlier "75" was a stale count); `/proc/686906` read directly at 19:19–19:25Z.

### 2026-10-16 — 0-byte stderr from a process that has not exited is not a pass
- **What went wrong / lesson:** REVA-38301's evidence cites `prune.err` at 0 bytes and Ops' monitor repeats it as a health signal. But `prune.exit` was **ABSENT** and `after.json` **ABSENT** — the prune has not exited, so `prune.err` is empty because it *has not failed yet*, not because it succeeded. Same class as the KiB swap error: a value that looks self-consistent while describing the wrong thing. Anyone citing "0 bytes" as a pass would be wrong.
- **Rule for future-me:** Completion evidence = the **exit marker exists**, not that stderr is empty. Always check `*.exit` / `*.json` presence before quoting an error file's size. Absence-of-error and absence-of-completion are different facts.
- **Evidence:** `/paperclip/.tmp/ops-scripts/w38272/` at 19:25Z — `backup.exit`=`0`, `prune.exit` ABSENT, `after.json` ABSENT, `prune.err` 0 B, prune PID 686906 alive 4.12 h and advancing.

### 2026-10-16 — compare age figures only at the same timestamp, or you invent drift
- **What went wrong / lesson:** I computed the prune's age at 19:23Z as 247 min, compared it to Ops' 223.5 min quoted at 19:00Z, and nearly reported "+23.5 min drift" as a finding. It was my own arithmetic error — the gap is exactly the 23 minutes between the two observations.
- **Rule for future-me:** Never compare a measurement taken now against another agent's figure quoted from an earlier timestamp. Re-derive their value at *their* timestamp (or drop the comparison). A disagreement that equals the observation gap is your error, not theirs.
- **Evidence:** `btime + starttime/100` → prune start 2026-10-16T15:16:49Z, matching `wrapper.log` `PRUNE_START` to the second — the two methods agree, so there was nothing to drift from.

### 2026-10-19 — a green-looking diff of *numbers* can hide a governance hole; test the authority's own tests
- **What went wrong / lesson:** REVA-38365 framed the SIGNATIQ_FACTS defect as "three counts (13/15/16) are authoritative." Counting was the symptom. Running the guardrail tests revealed (a) **origin/main is RED on its own tip** (`test_core_execution_connectors_match_signatiq_facts`, outlook renamed to `outlook_*` action classes so the test's `draft_generation` heuristic no longer matches), (b) `twenty` is a **live governed substrate on main** but absent from main's catalog/facts/test, where `assert not extra` structurally forbids adding it, and (c) **REVA-37797 is `done` but its Intercom adapter is not on main** (`git cat-file -e` -> rc=128, reachable only from worker refs). So the obvious fix — repoint the read path at main — would have routed the whole fleet to a red authority and silently dropped a governed connector.
- **Rule for future-me:** Before recommending "read the value from the good ref," **run that ref's own consistency tests and check its refs for stranded work**. A test that fails on main means main is not an authority; `assert not extra`-style one-way ratchets can forbid shipping something you actually ship. Compare connector/feature **sets**, not counts — divergent branches had *different members* (`main: linkedin/zoom/teams` vs `worktree: intercom/twenty`), which no count can express. Read-only way to test a ref without touching the checkout: `git archive <ref> | tar -x -C /tmp/snap` then run pytest there.
- **Evidence:** REVA-38365 document `reva-38365-addendum-a` (doc `1d09267a-500e-4ae6-b61d-fb28d96a2071`); worktree `3 failed, 11 passed`; main snapshot `1 failed, 14 passed`; `_GOVERNED_SUBSTRATE_BY_CONNECTOR['twenty']` present on `origin/main` with 0 catalog entries.

### 2026-10-19 — a stale SHA in a remediation step becomes an instruction to pin to the wrong thing
- **What went wrong / lesson:** REVA-38365's remediation said "checkout `eb2df7c806`." That SHA was 15 commits behind main by the time anyone would execute it (`b64b4c88d1`). A precise-looking SHA in a ticket is a snapshot, not an instruction.
- **Rule for future-me:** In remediation text, name the *command that re-derives* the ref (`git ls-remote canonical refs/heads/main`) rather than a literal SHA, even when the SHA is correct today. A SHA is only valid at the instant it was measured.
- **Evidence:** `git rev-list --count eb2df7c806..origin/main` -> 15; `git merge-base --is-ancestor eb2df7c806 origin/main` -> rc=0.

### 2026-10-16 — this runtime is a container; host process tree and `ps` are not observable **SUPERSEDED by the "DEAD PID cannot prove a namespace barrier" entry above**
- **What went wrong / lesson:** Verifying a VPS backup ticket, I tried to confirm the cited process PIDs directly and found `/proc/416188` absent. I concluded the agent runtime was a container that cannot see host PIDs, and wrote "~75 PIDs in its namespace". The container part is true (`/.dockerenv`, PID 1 = `docker-init -- tini -- sh /app/scripts/docker-entrypoint.sh`). **The "cannot see host PIDs" conclusion was wrong** — I inferred a barrier from a PID that had already exited. The only genuinely missing tools are `ps`, `free`, `uptime`, `swapoff`. Do not carry this entry forward.
- **Rule for future-me:** Read this as a record of an invalid inference, not as environment fact. Test PID visibility with `ns/pid` inode equality, never with an absent PID. `df`, `/proc/<pid>/io`, `/proc/<pid>/status`, and the process tree ARE valid first-hand readbacks.
- **Evidence:** `/.dockerenv` present; `readlink /proc/self/ns/pid` == `/proc/686906/ns/pid` == `pid:[4026532907]`; live PID count 104; `ps` → `command not found`.

### 2026-10-19 — `terminalBlockerId` is not a field; my 2026-10-09 blocker analysis was built on it
- **What went wrong / lesson:** My 2026-10-09 ledger entry ("25 blocked issues have `terminalBlockerId` pointing to themselves", cross-tabbed over 82 cards) described a **field that does not exist**. Re-measured 2026-10-19: all 82 blocked cards read `terminalBlockerId: null`, and `grep -r terminalBlockerId /app` hits **only my own memory notes** — 0 hits in `packages/db/src/schema` or `packages/shared`. I had pattern-matched an invented key name and then cross-tabbed whole populations against it. The entry is **WITHDRAWN**. The re-test of its two "genuinely anomalous" cards (REVA-36990 <- REVA-38347, REVA-37963 <- REVA-36990) shows both hold correct live edges — no defect ever existed.
- **Rule for future-me:** Before cross-tabbing a field across a population, prove the field exists — grep it in `packages/db/src/schema/*.ts` and read it off one live detail response. If a whole finding rests on a key that never appears in the schema, the finding is void, not merely weak. The real blocker fields are `blockerAttention`, `unblockDescriptor`, `activeRecoveryAction`; class with those.
- **Evidence:** 82/82 `terminalBlockerId: null`; `search_files terminalBlockerId /app` -> 2 hits, both memory files; `blockerAttention` present in `packages/shared/src/types/issue.ts:842,918` and `packages/db/src/schema/issues.ts`.

### 2026-10-19 — `currentRunId: null` does not mean an idle agent (retracts the 2026-10-10 metric)
- **What went wrong / lesson:** The 2026-10-10 entry treated "0/19 agents with `currentRunId`" as fleet idleness. On 2026-10-19 all 19 agents read `currentRunId: null` **while I was executing inside that very wake**. Ground truth from `GET /api/companies/{CO}/heartbeat-runs?limit=500`: 490 runs since 2026-10-18T13:00, all 19 agents active, 8 `running`. The field is simply not populated on this deployment.
- **Rule for future-me:** Measure agent liveness from `heartbeat-runs` (status + startedAt window), never from `agents[].currentRunId`. A self-observation is the cheapest possible disproof: if I am running and my own `currentRunId` is null, the metric is broken, not the fleet.
- **Evidence:** `agents` -> 19 rows, all `currentRunId: null`, 11 `status: idle`; `heartbeat-runs` -> 490 runs since 2026-10-18T13:00 across 19 distinct agents, 8 `running`.

### 2026-10-19 — an unassigned run can CREATE its own report card but cannot close it
- **What went wrong / lesson:** On run `4c3f54b4` (unassigned, `issueId: null`): `POST /api/companies/{CO}/issues` succeeded (201, REVA-38481) — the create gate does not require run attribution — but `PATCH .../status=done` returned 403 `cross_issue_influence_run_context_required`, and `POST /api/issues/{id}/checkout` returned 400 Validation error. So the report lands in `todo` and cannot be closed by the very run that wrote it.
- **Rule for future-me:** On an unassigned wake, expect the report card to land in `todo` and treat that as the normal terminal state. Attempt the close once, read the real error, then stop and state the blocked disposition explicitly. Do not retry-loop, and do not reassign the card to dodge the gate.
- **Evidence:** `POST /api/companies/{CO}/issues` -> 201 `REVA-38481`; `PATCH status=done` -> 403 `cross_issue_influence_run_context_required`; `POST /api/issues/{id}/checkout` -> 400.
