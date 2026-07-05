import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const repoRoot = path.resolve(import.meta.dirname, "..");
const patchScript = fs.readFileSync(
  path.join(repoRoot, "services/apply-issue-document-claim-guardrail.sh"),
  "utf8",
);
const entrypoint = fs.readFileSync(
  path.join(repoRoot, "services/entrypoint-fixed.sh"),
  "utf8",
);

assert.match(patchScript, /REVA-4045-issue-document-claim-guardrail/);
assert.ok(patchScript.includes('source: \\"upsert\\"'));
assert.ok(patchScript.includes('source: \\"restore\\"'));
assert.match(entrypoint, /apply-issue-document-claim-guardrail\.sh/);

const guardMatch = /const guardBlock = `([\s\S]*?)`;\n\nif \(!source\.includes\(guardMarker\)\)/.exec(patchScript);
assert.ok(guardMatch, "guard block template must be extractable from patch script");
const guardBlock = Function(
  "guardMarker",
  `return \`${guardMatch[1]}\`;`,
)("REVA-4045-issue-document-claim-guardrail");

const moduleSource = `
function unprocessable(message, details) {
  const error = new Error(message);
  error.status = 422;
  error.details = details;
  return error;
}
${guardBlock}
`;
const tempModule = path.join(repoRoot, "test-reva4045-guardrail-tmp.mjs");
fs.writeFileSync(tempModule, moduleSource);

try {
  const moduleUrl = `${pathToFileURL(tempModule).href}?t=${Date.now()}`;
  const { __reva4045CheckIssueDocumentClaimSafetyForTest: check } = await import(moduleUrl);

  assert.throws(
    () =>
      check({
        key: "copy-variants",
        title: "Marketing copy",
        body: "Signatiq synthesizes 117+ signal sources into scored account intelligence.",
      }),
    (error) =>
      error.status === 422 &&
      error.details?.code === "unsupported_product_claim" &&
      error.details?.guardrail === "REVA-4045",
  );

  assert.deepEqual(
    check({
      key: "copy-variants",
      title: "Marketing copy",
      body: "Signatiq synthesizes signals from 10+ GTM connectors into scored account intelligence.",
    }),
    { ok: true },
  );

  assert.deepEqual(
    check({
      key: "plan",
      title: "Claim cleanup",
      body: "Remove the incorrect 117+ signals claim and replace it with approved copy.",
    }),
    { ok: true },
  );
} finally {
  fs.rmSync(tempModule, { force: true });
}

console.log("REVA-4045 issue-document claim guardrail regression test passed");
