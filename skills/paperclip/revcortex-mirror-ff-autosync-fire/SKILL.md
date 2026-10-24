---
name: revcortex-mirror-ff-autosync-fire
description: Run and close the recurring revcortex-work.git fast-forward-only auto-sync fire (routine e85cb91b, cron "4 */4 * * *") — the exit-0 no-op / exit-1 divergence contract, the read-only instrument set, and the escalation route to the CTO publication lane. Use when a "RevCortex mirror ff-only auto-sync (REVA-35874)" card is assigned, or when the installed script /paperclip/services/revcortex-mirror-autosync.sh must be fired and its result proven.
category: paperclip
trigger: A card titled "RevCortex mirror ff-only auto-sync (REVA-35874)" is assigned, or the routine revcortex-mirror-autosync fires and its exit code must be turned into an evidence-bearing closeout.
---

# revcortex-work.git ff-only auto-sync fire

Routine `e85cb91b` (cron `4 */4 * * *`, UTC). Card family: "RevCortex mirror ff-only auto-sync
(REVA-35874)". Script: `/paperclip/services/revcortex-mirror-autosync.sh`; mirror:
`/paperclip/repos/revcortex-work.git`.

## The contract (from REVA-35874)

- **Exit 0** = clean fast-forward, or a no-op (mirror main already at upstream). Comment the stdout,
  close the card `done`.
- **Exit 1** = mirror main diverged (not an ancestor of upstream). The script **refuses** to update.
  Comment the WARNING stderr and route ONE typed blocker for CTO/Ops manual reconciliation,
  leaving **mirror and assignment unchanged**.
- **Never** force-push, force-update, `update-ref`, push, or mutate a PR. The stop condition is
  "if keeping this in sync ever requires a non-fast-forward update, STOP".

## Route shape (exit 1)

`status=blocked` + `blockedByIssueIds=[REVA-38627]` + the evidence comment **in one atomic PATCH**.
Sibling cards (REVA-38622/631/638/644/651) all did exactly this. `blockedBy` (joined, on the GET
response) is the authoritative read-back; the GET renders `blockedByIssueIds: null` even when the
edge is set.

## Instrument set (all read-only)

```bash
G=/paperclip/repos/revcortex-work.git
# authoritative upstream ref state, NO api credential needed
git --git-dir=$G ls-remote github-ssh refs/heads/main
git --git-dir=$G ls-remote github-ssh refs/pull/612/head refs/pull/612/merge
# divergence shape
git --git-dir=$G merge-base --is-ancestor refs/heads/main refs/remotes/origin/main; echo $?
git --git-dir=$G rev-list --left-right --count refs/heads/main...refs/remotes/origin/main
git --git-dir=$G merge-base refs/heads/main refs/remotes/origin/main
# whole-tree ref census (objectname diff catches ANY repointed ref)
git --git-dir=$G for-each-ref --format='%(refname) %(objectname)' > pre.txt   # and post.txt
```

**`merge-tree --write-tree` is NOT read-only — it WRITES unreferenced objects into the
target repo.** This skill used to call it a "read-only merge simulation, zero writes".
That is false. On REVA-38680 my post-fire diagnostic wrote 5 loose objects into the
**production mirror** (fsck: dangling; 0 of 11 597 refs pointed at them; loose count
unchanged). **Always run it in a throwaway bare repo** (`git init --bare` + fetch the
refs you need), never against the shared production mirror. If you already ran it
against production, disclose it in the closeout rather than claiming a read-only run.

`git ls-remote` over SSH is authoritative for ref state and needs **no API credential** — `GH_TOKEN`
is absent in this runtime, so a GitHub REST 404 would NOT mean "the PR/ref is gone".

## Pitfalls (each one cost a round trip)

1. **A positive control must be able to fail.** Stamp the synthetic row at the **window midpoint**,
   not `time.time()`. A control stamped outside the closed fire window matches 0 and proves nothing
   (I hit this on REVA-38662). Negative control: anchor it **1 h before the OLDEST file in the census**
   (`min(mtimes) - 3600`), NOT at an arbitrary offset from the window — `window_start - 30d` matched
   66 legitimately old pre-existing files on REVA-38671 and would have proved nothing. Add LATE
   (`end +24h`, 60 s) and EARLY (`start -24h`, 60 s) controls too. **Measurement scope and baseline
   scope must be the same path set** — a `refs/`+`logs/` baseline diffed against a whole-tree walk
   invents "new" files (`.pytest_cache/…`, 71 of them on REVA-38671).
 **REVA-38694: my control harness was SELF-INFLATED.** I stamped `negative.txt` at `neg_lo-3600`,
 `early.txt` at `start-24h` and `late.txt` at `end+24h` — i.e. **each control file was stamped
 inside its own control window**, so all three "negatives" fired and I nearly read them as three
 real in-window writes. **A control's synthetic row must be stamped INSIDE the window being
 measured (positive) and OUTSIDE every window being tested (negatives).** Rebuilt correctly:
 positive at the midpoint fired (1), negative/early/late read 0. Symptom to watch for: **all
 controls firing at once means the harness is wrong, not the data.**
 **Bonus:** `git fsck` on the mirror reports 5 dangling commits + 1 dangling tree that are
 **pre-existing** (mtime 2026-10-23T00:24:59Z = the REVA-38680 diagnostic; the tree `c09038f6…`
 is REVA-38680's simulated-merge tree). **Join every dangling object against the PRE-fire census
 before attributing it to the fire** — `fsck` output is not a timeline.
2. **`FETCH_HEAD` lives outside `refs/` and `logs/`.** A ref-only or logs-only in-window census reads
   0 even on a fire that definitely fetched. The fetch-did-run proof is `FETCH_HEAD` mtime inside
   the window plus its content (`<sha>\t\tbranch 'main' of github.com:…`).
3. **The mirror is SHALLOW** (boundary `9b8b12a4`). An ancestry verdict can be graft-truncated, so
   prove it is not: `merge-base --is-ancestor <shallow-boundary> <merge-base>` must be rc=0, i.e. the
   merge-base sits above the boundary.
4. **`refs/pull/N/merge` is a MOVING target.** It changed `39ce7f18` → `da1cbe2a` between two fires.
   Re-read it every wake; never quote a prior card's synthetic-merge SHA. Also: the *PR head* being
   contained upstream does NOT mean the *mirror tip* is — check the mirror tip specifically.
5. **A left-right count is a point-in-time measurement, NOT a diagnosis.** REVA-38622/38662 recorded
   `3/0` and concluded "sibling duplicate merge, permanent". REVA-38671 measured **3 ahead / 21
   behind** and disproved it: `445bcf5d` vs `refs/pull/612/merge` = **DIFFERENT_PARENTS** (first parent
   differs) and **DIFFERENT_TREE** (`diff --stat` = 11 files / 761 insertions, NOT empty). It is an
   ordinary two-sided divergence that upstream deepened by merging #609/#613/#525 on a different
   first-parent lineage. **Re-derive parents AND tree every fire before naming a failure mode.**
   Corollary: `pull/N/merge` has parents `(main@fetch-time, <pr-head>)` and GitHub mints a NEW merge
   commit, so `is-ancestor <mirror-tip> -> pull/N/merge` = rc=1 ⇒ **merging the PR never re-uses the
   mirror's local merge and cannot heal this class of divergence.** Cheap proof the mirror's commit
   exists nowhere upstream: `git ls-remote github-ssh | grep -c <sha>` over all 3040 refs = 0.
6. **Re-count "Nth consecutive card" from card BODIES, and state the criterion.** Prior cards claimed
   "5th" and "6th" for the same run of cards; re-counting from the bodies gave 5. Count *membership*
   (does the body state the condition), not string presence, and do not inherit the number.
7. **The installed runtime copy ≠ the branch source.** Installed 2097 B sha256 `d5f133e5…` (has the
   REVA-37445 SSH-remote fix, fetches into `refs/remotes/origin/main`); the unmerged branch
   `ops/reva-32980-mirror-autosync:scripts/ops/revcortex-mirror-autosync.sh` is 1135 B sha256
   `2e20defb…` and still says `git fetch origin`. Report the drift; the installed copy is what runs.
8. **`git fetch <remote-name>` in a throwaway clone** fails with `fatal: 'github-ssh' does not appear
   to be a git repository` — use the full URL `git@github.com:owner/repo.git`.
9. **semgrep ruleset ROOT must not be used** — it loads `.github/workflows/semgrep-rules-format.yml`,
   whose bare `on:` semgrep rejects as a YAML-1.1 boolean, and that config-load error masquerades as a
   clean scan. Use the subdirectories `generic yaml python javascript jvm go`. Always run a positive
   control (`curl --insecure` + a hardcoded token ⇒ `generic.curl-insecure`).
10. **The `security-scan` skill now RESOLVES in this profile** (`security-scan--f0b4457c74`). It was
    unresolvable when this skill was first written; re-check with `skill_view(name='security-scan')`
    every fire rather than assuming either way. Its scan command points at the ruleset SUBDIRECTORIES
    (`generic python javascript go yaml`) — do not pass the ruleset ROOT (see #9). Run it against a
    **copy** of the installed script and always add a positive control.
    **REVA-38694: `skill_view` could NOT resolve it** — neither `security-scan` nor
    `security-scan--f0b4457c74` nor `security-scan--f0b4457c74/security-scan`. The SKILL.md is on
    disk at **`/paperclip/.claude/skills/security-scan/SKILL.md`** (a `.claude` path, not a Hermes
    profile skill dir) — **read it directly with `read_file` when `skill_view` fails**, and run its
    exact command. `skill_manage(action='patch')` also could not resolve
    `revcortex-mirror-ff-autosync-fire` for editing even though `skills_list(category='paperclip')`
    shows it — **patch the SKILL.md with the `patch` tool at
    `/paperclip/.hermes/skills/paperclip/revcortex-mirror-ff-autosync-fire/SKILL.md`** and verify the
    numbering afterwards (a botched patch once doubled pitfall 11 and deleted 12; re-read the
    numbered list and assert 1..N exactly once, no duplicates).
11. **The fetch writes ONLY `FETCH_HEAD` — verify, don't assume a broader write.** The script's
    explicit refspec argument (`refs/heads/main:refs/remotes/origin/main`) overrides
    `remote.github-ssh.fetch` (`+refs/heads/*:refs/remotes/github-ssh/*`) for that fetch, so the
    `refs/remotes/github-ssh/*` namespace is **not** written. There is no reflog file at
    `logs/refs/remotes/origin/main` at all, so a `logs/`-scoped census sees **zero** change — which
    is why the whole-tree census is required.
    **REVA-38694 addition — a changed DIRECTORY is not a write.** The whole-tree census reported
    CHANGED = 2: `FETCH_HEAD` (103 B, in-window) and the **`objects/` DIRECTORY** mtime. Measured in
    a throwaway bare repo: a `git fetch` bumps the `objects/` **dir** mtime while `objects/pack`
    mtime is unchanged and the loose-file count stays 0 — the exact production signature. **Split
    files from directories in the census before calling a directory-mtime change an object write,
    and walk the `objects/` subtree explicitly to count in-window FILES (it was 0).**
    **Keep production read-only for mechanism probes.** I briefly created+removed
    `objects/tmp_probe_xyz` in the PRODUCTION mirror to test the dir-mtime mechanism, which bumped
    the production dir mtime. Harmless (no object, no ref, loose count unchanged) but it was a
    mutation of the shared mirror after the fire window — run that probe in `git init --bare`
    instead and disclose if it already happened.
12. **`git count-objects -v` reports `garbage: 1` on this mirror and that is PRE-EXISTING**, not
    fire damage: `objects/pack/tmp_pack_Bk2dLd` (332 787 712 B, mtime 2026-09-28). Read its mtime
    before attributing it to the run.
13. **Label every numeric census field in its field name.** A harness that puts `mtime_ns` into a
    field called `post_size` turns an unchanged 103 B file into an apparent 1.8 PB "size change".
    Record the authoritative size in a separate field (`fetch_head_size_post`) and say which is which.
    **REVA-38694 addition — the `q=` route is a FUZZY matcher, not a substring filter.** Bogus control
    `q=zzznotarealquery9999zzz` returned **1 row (REVA-38683, Daily VPS backup) that does NOT
    contain the token**. A nonzero bogus-control row count is a property of the search, not a finding
    — assert token absence in the returned rows instead of asserting row count 0. Exact-title dedup
    needs the 7-status sweep (`/companies/{cid}/issues?q=…&status=<s>` per status), not `q=` alone.
14. **Comment pre-flight**: the first line must be markdown-shaped (`#`, `**`, or blank) or the
    pre-flight guard rejects it. The fix belongs in the **body**, not the guard. A prose first line
    failed the guard on REVA-38662. **Also: name a boolean label for the DESIRABLE polarity.** I
    printed `contains_REDACTED=True` when the string was absent (inverted label) — verify the
    negative explicitly rather than trusting the label you printed.
15. **`/tmp/pca.py GET /issues?q=...` is HTTP 400** — search must be company-scoped:
    `/companies/{cid}/issues?q=...`. And `page=` does not advance on that route; use a status sweep
    (`?status=blocked` etc.) for a complete census.
    **`GET /companies/{cid}/heartbeat-runs` with NO query param TIMED OUT (120 s) on REVA-38694;
    with `?limit=100` it returned in seconds.** Add `?limit=`.
16. **`GET /issues/{id}/comments` returns rows NEWEST-FIRST.** Verify your comment by
    **content-hash over the sorted list of sha16 prefixes**, never by index or by filtering on the id
    the write returned.
17. **A sibling card can carry the same blocker edge but sit at the WRONG status.** REVA-38680 ran
    the same exit-1 fire, carries `blockedBy=[REVA-38627]` and its evidence comment, but its
    `status` is `todo`, not `blocked`. Report the inconsistency in your comment — do NOT mutate
    another card's lifecycle (cross-agent issue mutation is a separate gate).
18. **The `Paperclip` API list/search routes return JSON containing raw control characters**, so
    `json.loads` raises `Invalid control character`. Load with `json.loads(text, strict=False)`
    (and write to a file first rather than piping through a terminal, which truncates).

## The escalation route (do not re-file)

- Blocker **REVA-38627** (blocked, high, assignee CTO) carries the identical root cause and is itself
  `blockedBy` **REVA-38510** (the Clay publication lane). Link to it; file nothing new (REVA-25780).
- **REVA-38627's own title says "sibling merge" — that reading is DISPROVEN (REVA-38671).** It is
  still the right card to *link* (open, high, CTO), but the remedy in its body is wrong: it claims
  the branch advance alone no longer suffices because upstream moved 21 commits onto a different
  first-parent lineage. That is FALSE — see "THE REMEDY IS TWO STEPS AND NEEDS **NO MIRROR REF
  WRITE**" below (proven on REVA-38680, re-derived independently on REVA-38688). Say so explicitly
  in the run comment so the CTO does not act on the stale remedy.
- When the blocker already exists, the exit-1 route is **ONE atomic PATCH and nothing else**:
  `PATCH /issues/{id}` = `{"status":"blocked","blockedByIssueIds":["<blocker-uuid>"],"comment":"…"}`
  → 200. No new card, no second interaction, no comment-first-then-mutate, assignment untouched.
- Owner channel on REVA-38510: interaction **`c436647c-99a2-4a9a-a23a-52e324332634`**
  (pending / human_only / wake_assignee, idempotency `reva-38510-reconciliation-445bcf5d-v1`).
  **Do not create a second interaction and do not re-ask it.**
- The single decision needed: authorize the **non-force branch-head advance** of PR #612's branch
  `89445b153` → `445bcf5d` (a fast-forward, `is-ancestor` rc=0, no history rewrite), then merge
  PR #612 so upstream contains the mirror's Clay merge and the ff-only routine resumes. Merging
  PR #612 **as it stands does not heal it**.

## THE REMEDY IS TWO STEPS AND NEEDS **NO MIRROR REF WRITE** (PROVEN REVA-38680)

REVA-38671 concluded the opposite — that upstream's 21-commit move onto a different
first-parent lineage made the branch advance insufficient, so the mirror had to be
**re-pointed by hand** (a deliberate non-ff ref write, the class REVA-35874 forbids).
**That premise is false, and the proof is cheap.** The mirror tip `445bcf5d` is a
**merge** commit whose **second parent IS the PR #612 head** `89445b153`. So:

1. advance the PR #612 branch head `89445b153` → `445bcf5d` (true ff, rc=0, 42 commits);
2. merge PR #612 with CI green.

The resulting upstream merge commit contains `445bcf5d` **by ancestry**, so the script's
own guard `merge-base --is-ancestor refs/heads/main refs/remotes/origin/main` returns
**rc=0** and **the mirror re-points itself** on the next fire. No human mirror ref
write, and specifically no non-ff one.

Proof, in a throwaway bare repo (`merge-tree --write-tree` — see the write warning above):
`merge-tree --write-tree <upstream> 445bcf5d` rc=0 tree `c09038f6`; simulated merge commit
`6637e9e8`; `is-ancestor(445bcf5d -> that merge)` = **rc=0**; Clay blob `033a8ad2` present
in the merged upstream. **Control:** merging PR #612 **as it stands** (head `89445b153`)
⇒ `is-ancestor(445bcf5d -> merge)` = **rc=1** ⇒ does NOT heal. `refs/pull/612/merge`
stays `da1cbe2a` (GitHub mints it from the *base* branch) ⇒ it can never contain the tip.

**Rule: an inherited remedy is a HYPOTHESIS.** When a prior card says a forbidden-write is
*necessary*, prove the necessity in a throwaway before carrying it forward. "Upstream moved
onto a different lineage" does not defeat a merge that *contains* the mirror's tip.

## Count the consecutive fires from the STRUCTURED signal, not from prose

Proven criterion: **`status=blocked` AND `blockedBy=[REVA-38627]`** ⇒ 7 prior cards
(REVA-38622/631/638/644/651/662/671) + this one = 8th, on REVA-38680. **REVA-38688 is the 9th
fire at this stop condition**: 8th by that structured criterion (the same 7 priors, all still
`blocked` with the same edge) plus REVA-38680, which ran the same fire with the same blocker edge
but whose `status` sits at `todo`. **State both numbers with their criteria** — "9th fire, 8th by
the structured criterion" — rather than quoting a single unqualified ordinal.
**REVA-38694 is the 10th fire at this stop condition, 9th by the structured criterion.** The
9th-by-criterion set is the same 8 (38622/631/638/644/651/662/671/688) — REVA-38680 is excluded by
the criterion because its `status` is `todo` — plus this card. Re-derive the set each fire from
the live cards; do not inherit the count. A 7-status exact-title sweep
(`/companies/{cid}/issues?q=<title>&status=<s>` for each of the 7 statuses) is what produces it:
REVA-38694 measured blocked 8 / todo 1 / in_progress 1 / in_review 0 / backlog 0 / done 334 /
cancelled 25 = 369 exact-title cards, open family 10.

Two body-text criteria both failed and must not be used again: "body contains `EXIT_CODE=0`"
flagged 21 cards (cards quote **prior** fires' exit codes inside comparison tables), and a
regex for the card's own fire block returned `None` for 18 of 25 cards (older cards lack a
uniform `EXIT_CODE=` token). **A count derived from prose is a guess wearing a citation; use
the lifecycle field.** REVA-38671 reported "14th" under a body-membership criterion that is
not reproducible — say so rather than asserting it wrong, and do not compare the two numbers.

## A mutating-call TIMEOUT is not a failed write

The atomic PATCH (17.5 KB comment) exceeded the 180 s client timeout. The immediate GET
showed `status=in_progress` with the comment present and `blockedBy` already set — the write
was **mid-flight, not lost**. A re-read 20 s later showed `status=blocked`, `statusVersion=2`,
`blockedTransitionAt` set, locks released. **After a mutating-call timeout, GET the issue
before retrying** — a blind retry risks a double comment.

- Absence of authority must be **proven by enumeration** of `GET /companies/{cid}/approvals`
  (427 rows): `445bcf5d` = 1 hit = **`rejected`**; `89445b153`/`pull/612` = 0 hits; the `approved`
  `806ce463` explicitly "authorizes no direct ref mutation". An empty approval list would mean blind,
  not absent — assert non-empty first.

## Approval absence, proven by enumeration

`GET /companies/{cid}/approvals` → **428 rows** (2026-10-23; it was 427 earlier — **re-read the
count every fire, never quote a remembered number**). Scanned every payload: `445bcf5d` = 1 hit =
**`rejected`** (`7cf44da3`, PR #549 branch update) ⇒ **not** an authorisation. `89445b153` /
`pull/612` = 0 hits. `revcortex-work` = 2 hits, both `approved`, but scoped to a DIFFERENT action
class (the fetch-refspec / remote-URL script lane: `0d9176d7`, `806ce463` — the latter says
verbatim "this request authorizes no direct ref mutation"). **An `approved` approval in another
action class is NOT authority for a ref write** — match the approval's SCOPE to the action, not
the repo name. No approval names a mirror `update-ref`, a force-push, or a reconciliation ref write
⇒ Ops has **no authority** to reconcile; the decision stays with CTO/board on REVA-38510.

## The remedy proof is PER-FIRE, not a fixed set of SHAs

`merge-tree --write-tree` results differ per run because the simulated merge commit is
timestamped: REVA-38680 got tree `c09038f6` / merge `6637e9e8`; REVA-38688 got the **same tree**
`c09038f6` / a **different** merge commit `37ef8398`. The **tree** is the stable artefact; the
merge commit SHA is not. Quote the tree and the ancestry **rc**, and recompute both. Never quote
a prior card's simulated-merge SHA as if it were this run's.

## Verify before closing

- [ ] fire exit code, stdout/stderr byte counts, and the window captured
- [ ] whole-tree file census + `for-each-ref` objectname diff: mirror unmoved, 0 refs repointed
- [ ] `FETCH_HEAD` mtime in-window + content ⇒ the fetch ran
- [ ] both controls fire (positive inside the window; negative with a different parameter)
- [ ] early + late narrow controls also fire (control-only counts, 0 real files)
- [ ] divergence re-derived: both `is-ancestor` directions, `--left-right --count`, merge-base
- [ ] shallow-boundary check (merge-base above the boundary)
- [ ] `ls-remote` upstream agrees with the fetched ref
- [ ] remedy **precondition** re-derived, not just the remedy's direction
- [ ] approval absence proven by enumeration (assert non-empty) **and each hit's SCOPE read** —
      an `approved` approval in a different action class is not authority for a ref write
- [ ] semgrep clean on a COPY + positive control fired
- [ ] ONE atomic PATCH: `status` + `blockedByIssueIds` + the evidence comment
- [ ] readback by content-hash; mirror + assignment unchanged
- [ ] `count-objects -v` garbage entry checked by MTIME (the `tmp_pack_*` file is pre-existing)
