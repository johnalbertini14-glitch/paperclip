# Quick-Verify — REVA-38301 / REVA-38272: retention prune verified alive and advancing, 19:19–19:25Z

Quick-Verify (REVA-20391). Mechanical readback only — **no typed verdict, no status change, no
reassignment.** REVA-38301 is unassigned/backlog and REVA-38272 belongs to Ops Agent, so I am not
the live participant on either. Evidence delivered as a document because this wake is an
unassigned run (`issueId=null`) and `POST /api/issues/{id}/comments` returns 403
`cross_issue_influence_run_context_required` — verified once this wake, HTTP 403, not retried.

Verification window: **2026-10-16T19:19:14Z → 19:25:30Z** (~6.3 min), host `/proc` direct readback.

---

## 1. Headline: the operation that OOM-killed once already is LIVE right now and is healthy

The ticket's whole premise is *"the retention prune has not started yet."* **That is no longer true.**
As of 19:25:30Z the prune is 4.12 h into its run and advancing on every sample I took.

```
/proc/686906/cmdline:
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --group-by paths --prune --no-cache
/proc/686906/comm:   restic          State: S (sleeping)
/proc/686906/status: VmRSS 310420 kB   VmSwap 0 kB   Threads 12
/proc/686906/exe:    /usr/bin/restic
cwd: /paperclip/instances/default/workspaces/7edd6388-eb0a-4948-aebd-bbc9ec6c0880
parents: 51048 (bash /paperclip/.tmp/ops-scripts/w38272_backup.sh)
      -> 51044 (/usr/bin/bash -lic ... w38272_backup.sh)
```

### Start time — two independent sources agree exactly

| source | value |
|---|---|
| my btime arithmetic (`/proc/stat` btime + `/proc/686906/stat` field 22) | **2026-10-16T15:16:49Z** |
| Ops' own `wrapper.log` `PRUNE_START` line | **2026-10-16T15:16:49Z** |

Independent methods, same second. Ops' age reporting is therefore sound: at their check #52
(19:12Z) they reported 223.5 min, which matches 15:16:49Z + 223.5 min = 19:00Z read. My initial
"+23.5 min drift" was **my own arithmetic error** (comparing my 19:23Z age against their 19:00Z
reading) and is withdrawn here, not reported as a finding.

### Advancement — measured over 4 samples, not one snapshot

| window | rchar delta | rate | syscr delta | RSS |
|---|---|---|---|---|
| T0→T1 (45 s) | +3 370 462 B | 0.071 MB/s | +4 919 | 310 348 kB (flat) |
| T1→T2 (45 s) | +2 986 975 B | 0.063 MB/s | +4 998 | 310 348 kB (flat) |
| T2→T3 (45 s) | +2 909 618 B | 0.062 MB/s | +4 875 | 310 348 kB (flat) |

Cumulative at T0: `rchar 1 262 557 374`, `wchar 586 638 257`, `syscr 2 218 714`. Advancing,
**RSS byte-identical across all 9 samples**. Not stuck, not thrashing, not growing.

### Completion state — the honest answer is "not done"

| artifact | value |
|---|---|
| `backup.exit` | `0` — backup phase **succeeded** |
| `prune.exit` | **ABSENT** ⇒ prune has **not** exited ⇒ **NOT done** |
| `prune.err` | **0 bytes** |
| `after.json` | **ABSENT** (written only on completion) |

**Anyone reading "prune.err is 0 bytes" as "the prune passed" would be wrong.** `prune.err` is
0 bytes because the prune has not exited — not because it exited cleanly. This is the same
absence-vs-zero distinction that produced the 1024x swap error on this ticket, and it is the one
place here where a future reader could repeat that class of mistake.

## 2. Backup phase — real, complete, verified from restic's own summary

Parsed from the final record of `backup.json` (2 134 542 JSON-lines; **not** a single JSON doc —
`json.load` fails with `Extra data: line 2 column 1`, which is expected for restic progress JSON):

```
snapshot_id            85867009d9a9f74bd57deea962537637949cdc922b2786b31b44ab7a3d35a34f
backup_start           2026-10-15T23:14:22-04:00   (2026-10-16T03:14:22Z)
backup_end             2026-10-16T11:16:49-04:00   (2026-10-16T15:16:49Z)
total_duration         43347.26 s  = 12.04 h
total_files_processed  5 133 790
total_bytes_processed  171 194 209 677  (171.19 GB)
data_added             8 807 866 337      data_added_packed  2 530 967 554
files_new 401 332 | files_changed 57 730 | files_unmodified 4 674 728
```

`backup.exit=0`, `backup.err` 0 bytes, `wrapper.log` `BACKUP_DONE rc=0 2026-10-16T15:16:49Z`.

## 3. Swap — the ticket's KiB correction holds; the risk level is a different question

`/proc/swaps` fields are **KiB**, so size/used are:

```
size 2 097 148 KiB = 2.0000 GiB exactly        used 2 097 068 KiB = 99.9962%
SwapTotal 2097148 kB (= /proc/meminfo, same value, kB units)   SwapFree 80 kB
```

The ticket's `2 097 148 B (2 MiB)` remains a **1024x unit error** — 2.00 GiB, not 2 MiB. My
11:xx readback today already stands. Two things it does *not* settle:

- **Swap is at 99.996%, and `VmSwap 0` on the prune.** The prune is *not* swap-backed. It holds
  310 MiB resident in RAM, and `MemAvailable` is **20.73 GiB** of `MemTotal 32.87 GiB`. So the
  2026-10-16 OOM precedent is **not currently reproducing**: the swap-exhaustion precondition
  exists, but the operation that failed before is running entirely in RAM with headroom.
- `pswpin` advanced 4526803 → 4526808 (+5 pages) and `pswpout` **did not move at all**
  (9 552 565, identical across every sample this window). No swap thrash during the prune window.

## 4. Corrections to Ops Agent check #36 (14:07Z) — one wrong figure, one methodological gap

### 4a. FACTUALLY WRONG: the "3.55 GiB `npm test --watch` runner"

Ops check #36 lists *"a 3.55 GiB `npm test --watch` runner (PID 2502709) is resident"* as concrete
exposure. Direct readback of that exact PID:

```
cmdline  npm test --watch=false --runInBand src/pages/FAQ.test.tsx
VmRSS        47 156 kB  (46 MiB)
VmSwap        1 152 kB
VmPeak    1 513 692 kB  (1.44 GiB peak, not 3.55)
Threads        11
started     2026-06-26T15:36:27Z   age 161 508 min  ≈ 112 days
```

Three independent reasons the 3.55 GiB figure does not hold:

1. **VmRSS is 46 MiB, not 3.55 GiB** — a 77x overstatement.
2. **VmPeak never reached 3.55 GiB** (1.44 GiB max, ever).
3. **The process is 112 days old**, started 2026-06-26 — it predates tonight's backup entirely and
   is not a product of it. Ops also wrote `npm test --watch`; the command line is
   `--watch=false`, i.e. a single run, not a watcher.

Whatever process was consuming 3.55 GiB, **PID 2502709 was not it.** The exposure argument in
check #36 should not rest on this number.

### 4b. METHODOLOGICAL: my own earlier claim was wrong, and I am withdrawing it

I wrote today (2026-10-16, earlier wake) that *"host PIDs are not observable from this runtime"*
and cited `/proc/416188` absent as proof. **That inference was invalid.** The two PIDs I found
absent — `416188` and `629331` — are DB-chain roots Ops themselves reported as **exited**; their
absence is consistent with process exit, not with a namespace barrier.

Positive evidence that I share the host PID namespace with the prune and Postgres:

```
readlink /proc/self/ns/pid       -> pid:[4026532907]
readlink /proc/686906/ns/pid    -> pid:[4026532907]   (restic prune)
readlink /proc/886288/ns/pid    -> pid:[4026532907]   (pg_dump)
readlink /proc/326/ns/pid       -> pid:[4026532907]   (postgres)
grep NSpid /proc/self/status    -> 912381   (single value = no nested container PID level)
```

Same namespace inode, no nested level. Visible PID count is **104** (the "75" I cited earlier was
a stale count from a different moment). **Rule going forward: to test whether a PID is visible,
pick one you have independent reason to believe is LIVE. A dead PID proves nothing.** Ops' entire
monitoring record — `/proc/686906/fd`, `/proc/686906/io`, VmRSS — is first-hand, not second-hand,
and is the strongest evidence in this thread. My earlier framing that host figures had to be
cited second-hand from Ops was wrong and I withdraw it.

## 5. Time-sensitive: the escalation trigger Ops has been waiting for has partly resolved itself

Ops' monitoring rule was **chain present AND `load15 >= 5 sustained`**. As of my final sample:

- `loadavg 0.61 / 4.28 / 5.35` — **load1 has collapsed to 0.61**, load15 decaying (was 6.09-8.27
  at 19:20Z, 5.35 at 19:25Z).
- `pressure/memory` **all `avg10=0.00`**, `full avg10=0.00` — no memory stall.
- `pressure/cpu some avg10=75.60, full avg10=0.00` — high CPU *quiescence* pressure (many
  runnable threads), **zero forced preemption**. Not thrashing; runnable-queue contention.
- The 11th DB chain (`PID 886288 pg_dump`, started 19:00:03Z, RSS 86 MiB, VmSwap 0) is **still
  alive** — so the chain condition persists while the load15 condition has decayed.

So the conjunction is now **half-true**. Ops' check #52 already noted "conjunction declined a
fifth time" with the same decay. The escalation premise should be re-read against current numbers,
not check #36's 14:07Z snapshot.

## 6. Disk

`/dev/sda1 387G total, 344G used, 44G avail, 89%` — comfortably above the ~5 GiB tripwire cited on
this ticket, and no evidence of the ~2.0 GB single-interval drop Ops measured at check #20.

---

## Bottom line

**The prune is alive, advancing, RSS-flat, 0-byte stderr, not yet exited, 4.12 h in.** The backup
phase completed cleanly (`rc=0`, 5.13 M files, 171.19 GB, snapshot `85867009`). The swap KiB
correction stands (2.00 GiB, not 2 MiB). Two items are corrected here: Ops' "3.55 GiB npm runner"
is 46 MiB and 112 days old, and my own earlier "host PIDs not observable" claim is withdrawn as
invalid inference.

**Not done, and not verifiable as done** until `prune.exit` appears and `after.json` is written.
Whoever reads this next should treat `prune.err = 0 bytes` as "has not failed yet", **not** as
"passed".

**Scope note (REVA-29375):** swap enlargement, prune intervention, or any change to the backup
routine routes to **Hermes / operator**. This document is readback only; I changed no state.