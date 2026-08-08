/* Secret and PII scan.
 *
 * Ported from celadorastudios/partsbin and celadora.net so the three repos fail the same
 * way on the same things. Two jobs, because they fail differently:
 *
 *   1. Credentials. gitleaks covers this better than anything hand-rolled and runs
 *      alongside in CI; the patterns here are a cheap zero-dependency backstop that
 *      works with no network and no install.
 *
 *   2. Personal data. This is the part gitleaks does NOT do, and it matters more here
 *      than in the sibling repos. Claude-o-Meter reads Claude Code transcripts out of
 *      ~/.claude/projects/**\/*.jsonl. Those files contain conversation text, absolute
 *      home-directory paths, project names, and occasionally credentials that were
 *      pasted into a session. A fixture captured from a real machine to reproduce a
 *      parsing bug is the realistic way that ends up committed, and git history outlives
 *      any later decision to delete it.
 *
 * Detection is by SHAPE, never by listing the private values, since writing them here to
 * grep for them would leak them.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

/* CHECK_SECRETS_ROOT lets the test suite point the scanner at a fixture tree containing
   planted secrets. Without it a passing run proves nothing: a scanner that silently stops
   matching looks exactly like a clean repo. */
const ROOT = process.env.CHECK_SECRETS_ROOT
  ? path.resolve(process.env.CHECK_SECRETS_ROOT)
  : path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

const SKIP_DIRS = new Set(['.git', '.build', '.swiftpm', 'dist', 'node_modules', 'DerivedData']);
const TEXT = /\.(swift|sh|bash|zsh|yml|yaml|json|jsonl|md|txt|toml|plist|entitlements|xcconfig|resolved)$/;

/* Values that are public ON PURPOSE, or placeholders that only look like the real thing.
   Each needs a reason, because an allowlist is how a scanner quietly stops working. */
const ALLOWED = [
  'noreply@anthropic.com', // commit trailer used throughout this repo's history
  '/Users/me/', // placeholder home path in UpdateInstallerTests
  '/Users/you/', // placeholder home path in docs
  '/Users/runner/', // GitHub Actions macOS runner, appears in CI logs and paths
  '203.0.113.1', // RFC 5737 documentation address, used in a test fixture
];

/* Shape-based exemptions, for cases where the finding is structurally a false positive
   rather than a specific known value. */
const ALLOWED_PATTERNS = [
  // Retina asset suffixes parse as an email: claude-icon@2x.png -> @2x.png
  { re: /@\d+x\.(?:png|jpg|jpeg|gif|pdf|svg)\b/i, why: 'retina image asset suffix, not an email' },
  // Swift/shell interpolation rather than a literal path: /Users/\(name), /Users/$USER
  { re: /\/Users\/[\\$]/, why: 'interpolated path, not a real home directory' },
];

const RULES = [
  // --- credentials -------------------------------------------------------
  { id: 'private-key', re: /-----BEGIN (?:RSA |EC |OPENSSH |PGP )?PRIVATE KEY-----/, note: 'private key block' },
  { id: 'github-token', re: /\bgh[pousr]_[A-Za-z0-9]{16,}\b/, note: 'GitHub token' },
  { id: 'aws-key', re: /\bAKIA[0-9A-Z]{16}\b/, note: 'AWS access key id' },
  { id: 'slack-token', re: /\bxox[abprs]-[A-Za-z0-9-]{10,}\b/, note: 'Slack token' },
  { id: 'stripe-key', re: /\b[sr]k_(?:live|test)_[A-Za-z0-9]{16,}\b/, note: 'Stripe key' },
  { id: 'google-api-key', re: /\bAIza[0-9A-Za-z_-]{35}\b/, note: 'Google API key' },
  { id: 'openai-key', re: /\bsk-(?:proj-)?[A-Za-z0-9_-]{32,}\b/, note: 'OpenAI-style key' },
  { id: 'jwt', re: /\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\./, note: 'JWT' },
  {
    id: 'assigned-secret',
    re: /\b(?:api[_-]?key|secret|passwd|password|token|auth)\s*[:=]\s*["'][^"'\s]{12,}["']/i,
    note: 'hard-coded credential',
  },

  /* The one this repo is most exposed to. A Claude Code transcript can contain a key the
     user pasted into a session, so a fixture lifted from a real ~/.claude directory is a
     plausible way an Anthropic key reaches this repo. */
  {
    id: 'anthropic-key',
    re: /\bsk-ant-(?:api|oat|admin)\d{2}-[A-Za-z0-9_-]{20,}\b/,
    note: 'Anthropic API key',
  },

  // --- personal data -----------------------------------------------------
  { id: 'email', re: /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/, note: 'email address' },

  /* Absolute home paths name a real person and are exactly what leaks out of a captured
     transcript fixture, where every entry carries the cwd it was recorded in. */
  {
    id: 'home-path',
    re: /\/Users\/(?!me\/|you\/|user\/|runner\/|shared\/)[A-Za-z0-9._-]{2,}\//,
    note: 'absolute home directory path (names a real user)',
  },

  { id: 'phone-us', re: /(?:\+1[-. ]?)?\(?\b[2-9]\d{2}\)?[-. ]\d{3}[-. ]\d{4}\b/, note: 'US phone number' },
  {
    id: 'street-address',
    re: /\b\d{1,5}\s+[A-Z][A-Za-z.]*(?:\s+[A-Z][A-Za-z.]*)*\s+(?:Street|St|Avenue|Ave|Road|Rd|Lane|Ln|Drive|Dr|Court|Ct|Boulevard|Blvd|Way|Terrace|Ter|Circle|Cir)\b\.?/,
    note: 'street address',
  },
  { id: 'ssn', re: /\b\d{3}-\d{2}-\d{4}\b/, note: 'SSN-shaped number' },
];

function files(dir = '') {
  const out = [];
  for (const e of fs.readdirSync(path.join(ROOT, dir), { withFileTypes: true })) {
    if (e.name.startsWith('.') && e.name !== '.github') continue;
    const rel = dir ? `${dir}/${e.name}` : e.name;
    if (e.isDirectory()) {
      if (SKIP_DIRS.has(e.name)) continue;
      out.push(...files(rel));
    } else if (TEXT.test(e.name)) {
      out.push(rel);
    }
  }
  return out;
}

const hits = [];
const scanned = files();

/* Files that necessarily contain matching text: the rules themselves, and the fixtures
   that prove the rules still fire. Everything else in the repo is fair game. */
const SELF_EXEMPT = new Set([
  'scripts/check-secrets.mjs',
  'scripts/tests/check_secrets_test.sh',
]);

for (const rel of scanned) {
  if (SELF_EXEMPT.has(rel)) continue;
  const lines = fs.readFileSync(path.join(ROOT, rel), 'utf8').split(/\r?\n/);
  lines.forEach((line, i) => {
    for (const rule of RULES) {
      const m = line.match(rule.re);
      if (!m) continue;
      if (ALLOWED.some((a) => m[0].includes(a) || line.includes(a))) continue;
      if (ALLOWED_PATTERNS.some((p) => p.re.test(m[0]) || p.re.test(line))) continue;
      hits.push({ rel, line: i + 1, rule, found: m[0] });
    }
  });
}

/* Redact before printing. A CI log is as readable as the repo to anyone who can see the
   run, so a scanner that echoes the secret it caught has just published it a second time. */
function redact(s) {
  if (s.length <= 8) return '*'.repeat(s.length);
  return s.slice(0, 3) + '*'.repeat(Math.min(s.length - 6, 20)) + s.slice(-3);
}

if (hits.length === 0) {
  console.log(`secrets: OK (${scanned.length} text files scanned, ${RULES.length} rules)`);
  process.exit(0);
}

console.error(`secrets: ${hits.length} finding(s)\n`);
for (const h of hits) {
  console.error(`  ${h.rel}:${h.line}  [${h.rule.id}] ${h.rule.note}`);
  console.error(`      ${redact(h.found)}`);
}
console.error('\nIf a finding is intentional and safe to publish, add it to ALLOWED');
console.error('in scripts/check-secrets.mjs with a comment saying why.');
process.exit(1);
