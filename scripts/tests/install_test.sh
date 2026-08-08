#!/usr/bin/env bash
# Hermetic tests for scripts/install.sh.
#
# Every external tool the installer touches (curl, shasum, sw_vers, unzip, xattr, open,
# pgrep, pkill) is stubbed on PATH, and $HOME is redirected into a sandbox, so nothing
# reaches the network and nothing is written outside the temp directory. The point is to
# pin down the provenance branches and the destructive-delete guards, which are the parts
# that decide whether a user ends up running an unverified binary.
#
# Usage: ./scripts/tests/install_test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALLER="$REPO_ROOT/scripts/install.sh"
FAKE_DIGEST="1111111111111111111111111111111111111111111111111111111111111111"

PASS=0
FAIL=0

fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }
pass() { echo "  ok: $*"; PASS=$((PASS + 1)); }

assert_contains() {
  if printf '%s' "$1" | grep -q -- "$2"; then pass "$3"; else
    fail "$3 (output did not contain '$2')"
  fi
}

assert_not_contains() {
  if printf '%s' "$1" | grep -q -- "$2"; then fail "$3 (unexpectedly contained '$2')"; else
    pass "$3"
  fi
}

assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (expected '$2', got '$1')"; fi
}

assert_installed() {
  if [ -d "$SANDBOX/home/Applications/ClaudeOMeter.app" ]; then pass "$1"; else fail "$1"; fi
}

assert_not_installed() {
  if [ -d "$SANDBOX/home/Applications/ClaudeOMeter.app" ]; then fail "$1"; else pass "$1"; fi
}

# Builds a sandbox with stubbed tools.
#   $1 = provenance mode: attested | unattested | ratelimited | offline | flaky
#   $2 = macOS version reported by sw_vers (default 14.4)
#
# The attestations stub answers with a body followed by an HTTP status line, matching what
# the installer's `curl -w '\n%{http_code}'` produces, so the status-code parsing in
# check_provenance is exercised rather than bypassed.
make_sandbox() {
  local mode="$1" macos="${2:-14.4}"
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/bin" "$SANDBOX/home"
  COUNTER="$SANDBOX/curl-attempts"

  cat > "$SANDBOX/bin/sw_vers" <<EOF
#!/usr/bin/env bash
echo "$macos"
EOF

  cat > "$SANDBOX/bin/shasum" <<EOF
#!/usr/bin/env bash
echo "$FAKE_DIGEST  -"
EOF

  # Routes by URL: the redirect probe, the asset download, and the attestations lookup.
  cat > "$SANDBOX/bin/curl" <<EOF
#!/usr/bin/env bash
args="\$*"
out=""
prev=""
for a in "\$@"; do
  if [ "\$prev" = "-o" ]; then out="\$a"; fi
  prev="\$a"
done

case "\$args" in
  *api.github.com*attestations*)
    n=\$(cat "$COUNTER" 2>/dev/null || echo 0)
    n=\$((n + 1))
    echo "\$n" > "$COUNTER"
    case "$mode" in
      attested)
        printf '%s\n200\n' '{"attestations":[{"bundle":{"mediaType":"application/vnd.dev.sigstore.bundle.v0.3+json"}}]}'
        ;;
      unattested)
        # What GitHub really returns for a digest it has never attested.
        printf '%s\n404\n' '{"message":"Not Found","status":"404"}'
        ;;
      ratelimited)
        printf '%s\n403\n' '{"message":"API rate limit exceeded for 203.0.113.1"}'
        ;;
      offline)
        printf '\n000\n'
        exit 7
        ;;
      flaky)
        # Two transport failures, then a real answer, to prove retry recovers.
        if [ "\$n" -lt 3 ]; then printf '\n000\n'; exit 7; fi
        printf '%s\n200\n' '{"attestations":[{"bundle":{}}]}'
        ;;
    esac
    exit 0
    ;;
  *releases/latest*)
    echo "https://github.com/celadorastudios/claude-o-meter/releases/tag/v0.12.0"
    exit 0
    ;;
  *releases/download*)
    [ -n "\$out" ] && echo "fake-zip-bytes" > "\$out"
    exit 0
    ;;
esac
exit 0
EOF

  # Materialises the .app the installer expects to find after extraction.
  cat > "$SANDBOX/bin/unzip" <<'EOF'
#!/usr/bin/env bash
dest=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-d" ]; then dest="$a"; fi
  prev="$a"
done
mkdir -p "$dest/ClaudeOMeter.app/Contents/MacOS"
echo "new-build" > "$dest/ClaudeOMeter.app/Contents/MacOS/marker"
exit 0
EOF

  for tool in xattr open pkill; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/bin/$tool"
  done
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/pgrep"   # nothing running

  chmod +x "$SANDBOX/bin/"*
}

# CLAUDEOMETER_RETRY_DELAY=0 keeps the retry cases instant; the real default is 2s.
run_installer() {
  env PATH="$SANDBOX/bin:$PATH" HOME="$SANDBOX/home" CLAUDEOMETER_RETRY_DELAY=0 \
    "$@" bash "$INSTALLER" 2>&1
}

attempts() { cat "$COUNTER" 2>/dev/null || echo 0; }

cleanup() { [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
echo "case: attested release installs"
make_sandbox attested
OUT="$(run_installer)"; CODE=$?
assert_eq "$CODE" "0" "installer succeeds"
assert_contains "$OUT" "Verified: built by" "reports verified provenance"
assert_not_contains "$OUT" "WARNING" "does not warn when provenance is present"
assert_installed "app installed into \$HOME/Applications"
assert_eq "$(attempts)" "1" "a definitive answer costs exactly one request"
cleanup

# ---------------------------------------------------------------------------
echo "case: unattested release is refused"
# Verification is unconditional now, so a 404 aborts rather than warning.
make_sandbox unattested
OUT="$(run_installer)"; CODE=$?
if [ "$CODE" -ne 0 ]; then pass "installer aborts"; else fail "installer must refuse an unattested release"; fi
assert_contains "$OUT" "no build provenance found" "says the file has no provenance"
assert_not_contains "$OUT" "could not reach GitHub" "does not blame the network for a definitive answer"
assert_not_installed "nothing installed"
assert_eq "$(attempts)" "1" "a 404 is definitive and is not retried"
cleanup

# ---------------------------------------------------------------------------
echo "case: unreachable API is refused, and is reported differently"
# Fails closed: whoever can swap the asset can also block api.github.com.
make_sandbox offline
OUT="$(run_installer)"; CODE=$?
if [ "$CODE" -ne 0 ]; then pass "installer aborts"; else fail "installer must refuse when it cannot verify"; fi
assert_contains "$OUT" "could not reach GitHub" "says the check could not be completed"
assert_contains "$OUT" "does not mean the file is unsafe" "does not accuse the user's download"
assert_not_contains "$OUT" "no build provenance found" "does not report a missing attestation"
assert_contains "$OUT" "CLAUDEOMETER_INSECURE=1" "points at the documented override"
assert_not_installed "nothing installed"
assert_eq "$(attempts)" "3" "a transport failure is retried"
cleanup

# ---------------------------------------------------------------------------
echo "case: rate limiting reads as unverifiable, not as unattested"
# Unauthenticated api.github.com allows 60 requests an hour per IP, so a shared NAT
# can hit this. It must never be mistaken for a missing attestation.
make_sandbox ratelimited
OUT="$(run_installer)"; CODE=$?
if [ "$CODE" -ne 0 ]; then pass "installer aborts"; else fail "installer must refuse on HTTP 403"; fi
assert_contains "$OUT" "could not reach GitHub" "treated as unverifiable"
assert_not_contains "$OUT" "no build provenance found" "not treated as a missing attestation"
assert_eq "$(attempts)" "3" "an indeterminate answer is retried"
cleanup

# ---------------------------------------------------------------------------
echo "case: a transient outage recovers on retry"
make_sandbox flaky
OUT="$(run_installer)"; CODE=$?
assert_eq "$CODE" "0" "installer succeeds once the API answers"
assert_contains "$OUT" "Verified: built by" "reports verified provenance after retrying"
assert_installed "app installed"
assert_eq "$(attempts)" "3" "took three attempts"
cleanup

# ---------------------------------------------------------------------------
echo "case: CLAUDEOMETER_INSECURE=1 overrides a missing attestation"
make_sandbox unattested
OUT="$(run_installer CLAUDEOMETER_INSECURE=1)"; CODE=$?
assert_eq "$CODE" "0" "installer proceeds when the override is set"
assert_contains "$OUT" "WARNING" "warns loudly"
assert_contains "$OUT" "installing anyway" "says it is proceeding unverified"
assert_installed "app installed under the override"
cleanup

# ---------------------------------------------------------------------------
echo "case: CLAUDEOMETER_INSECURE=1 overrides an unreachable API"
make_sandbox offline
OUT="$(run_installer CLAUDEOMETER_INSECURE=1)"; CODE=$?
assert_eq "$CODE" "0" "installer proceeds when the override is set"
assert_contains "$OUT" "WARNING" "warns loudly"
assert_installed "app installed under the override"
cleanup

# ---------------------------------------------------------------------------
echo "case: the override is off unless set to exactly 1"
make_sandbox unattested
OUT="$(run_installer CLAUDEOMETER_INSECURE=0)"; CODE=$?
if [ "$CODE" -ne 0 ]; then pass "CLAUDEOMETER_INSECURE=0 does not bypass"; else fail "0 must not bypass"; fi
OUT="$(run_installer CLAUDEOMETER_INSECURE=yes)"; CODE=$?
if [ "$CODE" -ne 0 ]; then pass "CLAUDEOMETER_INSECURE=yes does not bypass"; else fail "yes must not bypass"; fi
cleanup

# ---------------------------------------------------------------------------
echo "case: unsupported macOS is refused before anything is downloaded"
make_sandbox attested 13.6
OUT="$(run_installer)"; CODE=$?
if [ "$CODE" -ne 0 ]; then pass "installer aborts"; else fail "should refuse macOS 13"; fi
assert_contains "$OUT" "requires macOS" "explains the requirement"
assert_eq "$(attempts)" "0" "nothing was fetched"
cleanup

# ---------------------------------------------------------------------------
echo "case: upgrade over an existing install replaces it"
make_sandbox attested
mkdir -p "$SANDBOX/home/Applications/ClaudeOMeter.app/Contents/MacOS"
echo "old-build" > "$SANDBOX/home/Applications/ClaudeOMeter.app/Contents/MacOS/marker"
OUT="$(run_installer)"; CODE=$?
assert_eq "$CODE" "0" "installer succeeds"
MARKER="$(cat "$SANDBOX/home/Applications/ClaudeOMeter.app/Contents/MacOS/marker" 2>/dev/null)"
assert_eq "$MARKER" "new-build" "existing install replaced with the new build"
cleanup

# ---------------------------------------------------------------------------
echo "case: a failed verification leaves an existing install untouched"
# The check runs before anything is extracted or copied, so a refusal must not
# damage the copy the user is already running.
make_sandbox unattested
mkdir -p "$SANDBOX/home/Applications/ClaudeOMeter.app/Contents/MacOS"
echo "old-build" > "$SANDBOX/home/Applications/ClaudeOMeter.app/Contents/MacOS/marker"
OUT="$(run_installer)"; CODE=$?
if [ "$CODE" -ne 0 ]; then pass "installer aborts"; else fail "should refuse"; fi
MARKER="$(cat "$SANDBOX/home/Applications/ClaudeOMeter.app/Contents/MacOS/marker" 2>/dev/null)"
assert_eq "$MARKER" "old-build" "existing install left intact"
cleanup

# ---------------------------------------------------------------------------
echo "case: safe_rm refuses shallow, empty and traversal paths"
# Source only the guard out of the installer so the real implementation is under test.
GUARD="$(sed -n '/^safe_rm() {/,/^}/p' "$INSTALLER")"
eval "$GUARD"
PROBE="$(mktemp -d)/deep/dir"
mkdir -p "$PROBE"
safe_rm "";             [ -d "$PROBE" ] && pass "empty path deletes nothing"
safe_rm "/";            [ -d / ] && pass "root is protected"
safe_rm "/Applications" ; [ -d "$PROBE" ] && pass "one-level path is protected"
safe_rm "$PROBE/../../.."; [ -d "$PROBE" ] && pass "traversal path is protected"
safe_rm "$PROBE"
if [ -d "$PROBE" ]; then fail "a safe deep path should be removed"; else pass "safe deep path is removed"; fi

# ---------------------------------------------------------------------------
echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
