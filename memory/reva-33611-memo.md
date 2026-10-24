# Research Memo: ProspectDetail.tsx

**Surface:** `/frontend/src/pages/ProspectDetail.tsx`
**Route:** `/prospects/:id`
**Last CWA code-fix:** REVA-30691 (2026-08-16)
**IR status:** FRESH — no prior IR audit on record
**SIGNATIQ_FACTS.md:** Last Verified 2026-06-17 (cited throughout)

---

## (a) Surface Purpose + External/Internal

**Internal operator surface.** Route `/prospects/:id` is authenticated SPA only. Never exposed to unauthenticated users or external-facing content.

**Purpose — three-part operator workflow:**
1. **Enrichment display** — firmographic, contact, and signal-score data from enrichment connectors (Apollo, Clearbit, Crunchbase)
2. **Activity timeline** — cursor-paginated chronological event feed from the GTM signal layer
3. **Outbound engagement** — playbook enrollment + approval-gated outreach composer

---

## (b) Integration Points — MCP Tools / Connectors

**API calls (via `../lib/api`):**

| Endpoint | Used for |
|---|---|
| `api.getProspect(id)` | Core prospect record |
| `api.getProspectSignalScore(id)` | Signal scoring panel |
| `api.getProspectTimeline(id, cursor)` | Activity timeline (cursor-paginated) |
| `api.getPlaybooks()` | Playbook selector list |
| `api.getProspectApprovals(id)` | Approval state for outreach gate |
| `api.createApproval(payload)` | Submit approval request |
| `api.enrollProspectPlaybook(id, payload)` | Enroll prospect in playbook |

**Connector families (L110-114):** HubSpot, Salesforce, Gmail, Outlook, Gong, Slack, Qualified, Drift, Outreach, Apollo, Clearbit, Crunchbase, Public Web Research — matches 13 GTM connector families per SIGNATIQ_FACTS.md (L20, Last Verified 2026-06-17).

**Enrichment data schema** — `EnrichmentData` interface (L18-37): firstName, lastName, email, title, company, industry, location, LinkedIn, phone, companySize, revenue, funding. Source connectors: Apollo, Clearbit, Crunchbase (inferred from data shape and CONNECTOR_FAMILIES constant).

**MCP tools:** No direct MCP invocation in this component; connector data flows through the API layer.

---

## (c) Banned-Token Scan

| Token | Result |
|---|---|
| `RevCortex` | **CLEAN** — zero occurrences |
| `EngageAI` | **CLEAN** — zero occurrences |
| `117` (word boundary) | **CLEAN** — zero occurrences |

Clean. Consistent with REVA-30691 prior work.

---

## (d) Signatiq Brand Consistency on Operator Copy

| Location | Text | Assessment |
|---|---|---|
| L108 comment | `// ─── Connector badge strip (13 families)` | **OK** — "13 families" matches canonical count (SIGNATIQ_FACTS.md L20) |
| L110-114 | 13 connector families verbatim | **OK** — consistent with SIGNATIQ_FACTS.md L24-37 |
| L499, L632, L667, L724, L774 | Neutral UI labels | **OK** — no brand misstatements |
| L813 | Preview placeholder | **OK** — no banned copy |

No `RevCortex`, `EngageAI`, or `117` references. Brand copy is consistent.

---

## (e) Governance / Compliance Surface Notes

**Approval gating — outreach:**
- L284: `canSendOutreach = approvalsData.some(a => a.type === 'external_send' && a.status === 'approved')` — outreach composer disabled until `external_send` approval is `'approved'`
- L436-442: Send Outreach button locked behind `canSendOutreach`; tooltip: "Requires approval — click Request Approval first"

**Approval request submission:**
- L304-310: `handleRequestApproval()` calls `api.createApproval({ actionType: 'crm_mutation', ... })` — hardcoded `actionType: 'crm_mutation'`

**Governance alignment (SIGNATIQ_FACTS.md L64-76):**

| Action Class | Default Policy | Implementation |
|---|---|---|
| CRM Mutation | approval | `actionType: 'crm_mutation'` submitted (L306) |
| External Send | approval | `canSendOutreach` gate checks `type: 'external_send', status: 'approved'` (L284) |

**Compliance notes:**
- Timeline events display a `source` badge (L467) — operator can identify which connector/system generated each event
- No PII transmitted to external services from this component; enrichment fetched from internal API
- Approval notes stay within the approval API; no external logging
- `external_send` gate is correctly wired for outreach governance

---

## (f) Gap / Risk

**GAP-1: Approval type mismatch — `crm_mutation` submitted, `external_send` required (MEDIUM)**

`handleRequestApproval()` (L304-310) hardcodes `actionType: 'crm_mutation'`. `canSendOutreach` (L284) checks for `type: 'external_send'`. A user can submit a `crm_mutation` approval request, get it approved, and still find the Send Outreach button locked — because the gate only recognizes `external_send` approvals.

**Impact:** Outreach workflow dead-ends after obtaining approval. Misleading UX — "Request Approval" is adjacent to "Send Outreach" but requests the wrong approval type.

**Fix path:** `handleRequestApproval()` should pass `actionType: 'external_send'` in the outreach context, or the backend should normalize `crm_mutation` -> `external_send` for outreach-context approvals.

---

**GAP-2: Connector families hardcoded constant — drift risk (LOW)**

L110-114 duplicates the 13 connector families as a local constant. SIGNATIQ_FACTS.md and `backend/core/gtm_runtime.py` `CONNECTOR_CATALOG` are the canonical source. CI guard in `test_signatiq_facts_guardrails.py` does not cover this client-side constant. New connector families would not auto-appear in the badge strip.

**Fix path:** Import from a shared constants module rather than duplicating the array locally.

---

**GAP-3: Outreach preview placeholder is static (LOW)**

L811-816: static placeholder text, no actual template substitution. Acceptable as stub; should not ship to production without real template rendering.

---

**No-risk findings:**
- No banned tokens
- No hardcoded credentials or secrets
- No direct external service calls from component
- Dark mode classes present and consistent with design token approach
- `window.innerWidth` check in accordion default (L506) — client-side hydration quirk, no data leakage

---

## Summary

`ProspectDetail.tsx` is a clean, well-structured internal operator surface. Banned-token scan clean. Brand copy consistent with Signatiq's canonical 13-connector count (SIGNATIQ_FACTS.md, Last Verified 2026-06-17). Governance gates correctly wired for both `crm_mutation` and `external_send` approval types. One functional gap: the approval type submitted (`crm_mutation`) does not match the type the outreach gate enforces (`external_send`), which could prevent operators from completing the outreach flow after obtaining approval.

**Recommendation:** File follow-up to fix GAP-1 (approval type mismatch) before outreach workflow ships to production operators.

---

*Research memo — Internal Researcher, 2026-08-30. File read: `/paperclip/repos/RevCortex/frontend/src/pages/ProspectDetail.tsx` (835 lines). No code changes made.*
