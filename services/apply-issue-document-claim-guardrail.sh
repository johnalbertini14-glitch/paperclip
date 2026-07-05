#!/usr/bin/env bash
# REVA-4045: block stale 117+ signal/source/connector claims in issue documents.
# Run after `npm i -g paperclipai` upgrades.
set -euo pipefail

TARGET="/usr/local/lib/node_modules/paperclipai/node_modules/@paperclipai/server/dist/services/documents.js"

if [ ! -f "$TARGET" ]; then
  echo "apply-issue-document-claim-guardrail: WARNING - target file not found, skipping"
  exit 0
fi

NODE_BIN=(node)
if [ ! -w "$TARGET" ]; then
  NODE_BIN=(sudo node)
fi

"${NODE_BIN[@]}" --input-type=module - "$TARGET" <<'NODE'
import fs from "node:fs";

const target = process.argv[2];
let source = fs.readFileSync(target, "utf8");
let changed = false;

const guardMarker = "REVA-4045-issue-document-claim-guardrail";
const guardBlock = `// ${guardMarker}
const REVA_4045_CLAIM_TERM_PATTERN = /\\b(?:gtm|signals?|sources?|connectors?|integrations?)\\b/i;
const REVA_4045_CORRECTIVE_CONTEXT_PATTERN = /\\b(?:audit|blocked|blocker|blocking|claim-safety|correct(?:ed|ion)?|do not use|don't use|fix(?:ed)?|guardrail|incorrect|not approved|not allowed|regress(?:ed|ion)?|reject(?:ed)?|remove(?:d)?|replace(?:d)?|safety|stale|unsupported|unapproved|unverified|wrong)\\b/i;
function reva4045NormalizeSnippet(value) {
    return value.replace(/\\s+/g, " ").trim();
}
function reva4045ClaimContext(text, index, radius = 160) {
    return text.slice(Math.max(0, index - radius), Math.min(text.length, index + radius));
}
function reva4045IssueDocumentClaimViolations(input) {
    const text = [input.title ?? "", input.body ?? ""].join("\\n");
    const violations = [];
    for (const match of text.matchAll(/\\b117\\s*\\+/gi)) {
        const context = reva4045ClaimContext(text, match.index ?? 0);
        if (!REVA_4045_CLAIM_TERM_PATTERN.test(context)) {
            continue;
        }
        if (REVA_4045_CORRECTIVE_CONTEXT_PATTERN.test(context)) {
            continue;
        }
        violations.push({
            claim: match[0],
            context: reva4045NormalizeSnippet(context).slice(0, 240),
        });
    }
    return violations;
}
function assertIssueDocumentClaimSafety(input) {
    const violations = reva4045IssueDocumentClaimViolations(input);
    if (!violations.length) {
        return;
    }
    throw unprocessable("Unsupported product claim blocked in issue document", {
        code: "unsupported_product_claim",
        guardrail: "REVA-4045",
        key: input.key,
        title: input.title ?? null,
        source: input.source ?? "issue_document",
        allowedCopy: "Use 10+ GTM connectors or remove the unqualified signal/source count.",
        violations,
    });
}
export function __reva4045CheckIssueDocumentClaimSafetyForTest(input) {
    assertIssueDocumentClaimSafety(input);
    return { ok: true };
}
`;

if (!source.includes(guardMarker)) {
  const anchor = "function mapIssueDocumentRow(row, includeBody) {";
  if (!source.includes(anchor)) {
    throw new Error("REVA-4045 guard anchor not found");
  }
  source = source.replace(anchor, `${guardBlock}\n${anchor}`);
  changed = true;
}

const upsertNeedle = "const key = normalizeDocumentKey(input.key);\n            const issue = await db";
const upsertReplacement = "const key = normalizeDocumentKey(input.key);\n            assertIssueDocumentClaimSafety({ key, title: input.title ?? null, body: input.body, source: \"upsert\" });\n            const issue = await db";
if (!source.includes("source: \"upsert\" })")) {
  if (!source.includes(upsertNeedle)) {
    throw new Error("REVA-4045 upsert anchor not found");
  }
  source = source.replace(upsertNeedle, upsertReplacement);
  changed = true;
}

const restoreNeedle = "if (!revision)\n                    throw notFound(\"Document revision not found\");\n                if (existing.latestRevisionId === revision.id) {";
const restoreReplacement = "if (!revision)\n                    throw notFound(\"Document revision not found\");\n                assertIssueDocumentClaimSafety({ key, title: revision.title ?? null, body: revision.body, source: \"restore\" });\n                if (existing.latestRevisionId === revision.id) {";
if (!source.includes("source: \"restore\" })")) {
  if (!source.includes(restoreNeedle)) {
    throw new Error("REVA-4045 restore anchor not found");
  }
  source = source.replace(restoreNeedle, restoreReplacement);
  changed = true;
}

if (changed) {
  fs.writeFileSync(target, source);
  console.log("apply-issue-document-claim-guardrail: patched documents.js");
} else {
  console.log("apply-issue-document-claim-guardrail: already applied");
}
NODE

grep -q "REVA-4045-issue-document-claim-guardrail" "$TARGET"
grep -q "source: \"upsert\"" "$TARGET"
grep -q "source: \"restore\"" "$TARGET"

echo "apply-issue-document-claim-guardrail: all patches applied"
