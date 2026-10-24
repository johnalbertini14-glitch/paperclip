---
name: paperclip-supersede-flag-guard
description: Create Paperclip interactions with supersedeOnUserComment=false so machine-written cron nudges cannot expire a pending human-facing ask; includes the population test that proves the flag is the control, and the confounder to avoid.
---

# Keep a human wait alive: `supersedeOnUserComment: false`

## When this fires

Any time you create an interaction intended to be answered by a **person** and to
survive more than ~2.5 hours:

```bash
POST /api/issues/{id}/interactions
```

Fields that matter (proven 2026-10-20, all validated by the API):

| field | limit | note |
|---|---|---|
| `payload.summary` | **<= 1000 chars** | 400 `Validation error`, `details[0].path=["summary"]`, `code=too_big` |
| `title` | <= 200 chars | assert client-side before POST |
| `resolverPolicy` | `"human_only"` | required for a credential/repo/config decision Ops must not make |
| `continuationPolicy` | `"wake_assignee"` | wakes you only after acceptance |
| `payload.supersedeOnUserComment` | bool | **`false` = cron-proof. Default in most examples is `true`.** |

`summary` is validated but `payload.detailsMarkdown` is not — put the full matrix
in `detailsMarkdown` and keep `summary` to the decision plus its pointer.

## The finding (REVA-38434, corrected 2026-10-20)

`supersedeOnUserComment` is a **requester-supplied payload field**, and it is the
control for the cron supersede kill. Measured across the entire open corpus
(145 cards end-proven, 171 interactions):

| `result.outcome` | `supersedeOnUserComment` | n |
|---|---|---|
| `superseded_by_comment` | `true`  | **11** |
| `superseded_by_comment` | `false` | **0**  |
| `superseded_by_newer_request` | `false` | 20 |
| `issue_closed` | `false` | 1 |

Every cron-comment kill carried the flag; none did not. A flag-false ask survived
**18** subsequent cron comments on REVA-34050 and was still `pending`.

So a machine comment resolving a `human_only` gate is a real platform defect —
keep REVA-38434 open — but **the deaths are gated by a flag the requester chose**.
"Every replacement dies, stop re-raising" is the wrong conclusion.

## Rules

1. **Set `supersedeOnUserComment: false`** for any ask meant to outlive one
   cron-nudge cadence. Re-prove by reading `payload` back after the POST.
2. **Put the interaction on the OPEN root card**, never on an execution card you
   are about to close — terminal status expires it independently of this flag.
3. **Verify by re-fetching** `GET /issues/{id}/interactions` and reading
   `status`, `effectiveResolverPolicy`, `continuationPolicy`, and the flag back.
   Never trust the POST response alone.
4. **If a cron comment lands on the card, re-read the interaction's status first.**
   Do not re-raise until you have checked whether it actually died.

## The confounder that produced a wrong answer first

Do **not** build the exposure cohort as "the card had a cron comment after this
interaction row was created". That is card-wide history, unrelated to the kill,
and it yielded 26 false "discriminating cases" that appeared to prove the flag
does not protect.

Build the cohort from the **kill event** instead: read `result.outcome` and the
`result.commentId`, fetch that comment, and check whether it is
cron-authored (`authorAgentId: null` + `authorUserId` = the board/automation
identity + body matching a `[CRON]`/`Hermes cron` template). Then cross-tab
`(supersedeOnUserComment, status, result.outcome)` over every interaction on every
open card.

## API shape notes for this route

- `GET /issues/{id}` has **no** `interactions` key. Interactions are a separate
  route. Assert the key is present before treating absence as meaning.
- Comment rows carry `authorAgentId` / `authorUserId`; a cron nudge shows
  `authorAgentId: null`, `runId: null`, and `authorUserId` = the automation identity.
- Related platform cards: REVA-38434 (supersede kill), REVA-38450 (nudge re-post
  cadence), REVA-38101 (executionBlocker). Per REVA-25780, evidence goes on the
  existing card — do not file a sibling.
