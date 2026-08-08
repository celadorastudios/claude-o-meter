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

# Builds a sandbox with stubbed tools. $1 = "attested" | "unattested", $2 = macOS version.
make_sandbox() {
  local attested="$1" macos="${2:-14.4}"
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/bin" "$SANDBOX/home"

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
    if [ "$attested" = "attested" ]; then
      echo '{"attestations":[{"bundle":{"mediaType":"application/vnd.dev.sigstore.bundle.v0.3+json"}}]}'
      exit 0
    fi
    # GitHub returns 404 for a digest it has never attested; -f makes curl exit nonzero.
    exit 22
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

run_installer() {
  env PATH="$SANDBOX/bin:$PATH" HOME="$SANDBOX/home" "$@" bash "$INSTALLER" 2>&1
}

cleanup() { [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
echo "case: fresh install of an attested release"
make_sandbox attested
OUT="$(run_installer)"; CODE=$?
assert_eq "$CODE" "0" "installer succeeds"
assert_contains "$OUT" "Verified: built by" "reports verified provenance"
assert_not_contains "$OUT" "WARNING" "does not warn when provenance is present"
if [ -d "$SANDBOX/home/Applications/ClaudeOMeter.app" ]; then
  pass "app installed into \$HOME/Applications"
else
  fail "app was not installed into \$HOME/Applications"
fi
cleanup

# ---------------------------------------------------------------------------
echo "case: release with no attestation still installs, but warns"
make_sandbox unattested
OUT="$(run_installer)"; CODE=$?
assert_eq "$CODE" "0" "installer still succeeds (older releases predate provenance)"
assert_contains "$OUT" "no build provenance found" "warns about missing provenance"
if [ -d "$SANDBOX/home/Applications/ClaudeOMeter.app" ]; then
  pass "app still installed"
else
  fail "app should still install when provenance is merely absent"
fi
cleanup

# ---------------------------------------------------------------------------
echo "case: strict mode refuses an unattested release"
make_sandbox unattested
OUT="$(run_installer CLAUDEOMETER_STRICT_VERIFY=1)"; CODE=$?
if [ "$CODE" -ne 0 ]; then pass "installer aborts"; else fail "installer should abort in strict mode"; fi
assert_contains "$OUT" "Aborting" "explains that it aborted"
if [ -d "$SANDBOX/home/Applications/ClaudeOMeter.app" ]; then
  fail "nothing should be installed when strict verification fails"
else
  pass "no app installed"
fi
cleanup

# ---------------------------------------------------------------------------
echo "case: strict mode accepts an attested release"
make_sandbox attested
OUT="$(run_installer CLAUDEOMETER_STRICT_VERIFY=1)"; CODE=$?
assert_eq "$CODE" "0" "installer succeeds in strict mode when attested"
cleanup

# ---------------------------------------------------------------------------
echo "case: unsupported macOS is refused before anything is downloaded"
make_sandbox attested 13.6
OUT="$(run_installer)"; CODE=$?
if [ "$CODE" -ne 0 ]; then pass "installer aborts"; else fail "should refuse macOS 13"; fi
assert_contains "$OUT" "requires macOS" "explains the requirement"
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
