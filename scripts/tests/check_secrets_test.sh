#!/usr/bin/env bash
# Tests for scripts/check-secrets.mjs.
#
# A secret scanner fails silently: if a regex stops matching, every run goes green and
# looks exactly like a clean repo. So each rule is proved against a planted fixture, and
# each allowlist entry is proved to still let its own case through.
#
# Fixtures are written to a temp tree and the scanner is pointed at it with
# CHECK_SECRETS_ROOT, so nothing here touches the real repo.
#
# Usage: ./scripts/tests/check_secrets_test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCANNER="$REPO_ROOT/scripts/check-secrets.mjs"

PASS=0
FAIL=0
pass() { echo "  ok: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

FIXTURE_ROOT="$(mktemp -d)"
cleanup() { rm -rf "$FIXTURE_ROOT"; }
trap cleanup EXIT

# Runs the scanner over a one-file fixture tree. Echoes output; returns the exit code.
scan() {
  local content="$1" name="${2:-sample.swift}"
  local dir
  dir="$(mktemp -d "$FIXTURE_ROOT/case.XXXXXX")"
  printf '%s\n' "$content" > "$dir/$name"
  CHECK_SECRETS_ROOT="$dir" node "$SCANNER" 2>&1
}

# $1 = fixture content, $2 = rule id expected to fire, $3 = description
assert_caught() {
  local out
  out="$(scan "$1")"
  if printf '%s' "$out" | grep -q "\[$2\]"; then
    pass "$3"
  else
    fail "$3 (rule '$2' did not fire; got: $(printf '%s' "$out" | head -3 | tr '\n' ' '))"
  fi
}

# $1 = fixture content, $2 = description
assert_clean() {
  local out
  out="$(scan "$1")"
  if printf '%s' "$out" | grep -q "^secrets: OK"; then
    pass "$2"
  else
    fail "$2 (unexpected finding: $(printf '%s' "$out" | head -3 | tr '\n' ' '))"
  fi
}

echo "case: credential rules fire"
assert_caught 'let k = "sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"' anthropic-key "Anthropic API key"
assert_caught 'let k = "ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"' github-token "GitHub token"
assert_caught 'let k = "AKIAIOSFODNN7EXAMPLE"' aws-key "AWS access key id"
assert_caught 'let k = "xoxb-1234567890-abcdefghij"' slack-token "Slack token"
assert_caught 'let k = "sk_live_AAAAAAAAAAAAAAAAAAAA"' stripe-key "Stripe key"
assert_caught 'let k = "AIzaBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"' google-api-key "Google API key"
assert_caught 'password = "hunter2hunter2hunter2"' assigned-secret "hard-coded credential"
assert_caught '-----BEGIN OPENSSH PRIVATE KEY-----' private-key "private key block"
assert_caught 'let t = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abc"' jwt "JWT"

echo "case: personal data rules fire"
assert_caught 'let contact = "someone@example.com"' email "email address"
assert_caught 'let cwd = "/Users/jsmith/git/thing"' home-path "absolute home path names a real user"
assert_caught 'let phone = "603-555-0142"' phone-us "US phone number"
assert_caught 'let id = "123-45-6789"' ssn "SSN-shaped number"

echo "case: the transcript-fixture leak this repo is actually exposed to"
# A JSONL line lifted from a real ~/.claude/projects directory carries the cwd it was
# recorded in, and sometimes a key that was pasted into the session.
assert_caught '{"cwd":"/Users/jsmith/git/secret-project","type":"user"}' home-path "captured transcript cwd"
assert_caught '{"content":"my key is sk-ant-api03-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"}' anthropic-key "key pasted into a transcript"

echo "case: allowlisted values still pass"
assert_clean 'Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>' "commit trailer address"
assert_clean 'let home = URL(fileURLWithPath: "/Users/me/Applications/ClaudeOMeter.app")' "placeholder home path"
assert_clean 'for img in "claude-icon@2x.png" "claude-code-icon@2x.png"; do' "retina asset suffix is not an email"
assert_clean 'let p = "/Users/\(user)/Library"' "interpolated path is not a real home directory"
assert_clean 'echo "$HOME/Applications"' "no finding in ordinary shell"

echo "case: the real repo is clean"
if node "$SCANNER" >/dev/null 2>&1; then
  pass "scanner passes against the repo as committed"
else
  fail "scanner reports findings in the repo"
fi

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
