# Contributing to ClaudeOMeter

Thanks for your interest. This is a small tool — contributions are welcome, but please read this first so we stay on the same page.

## What belongs here

- Bug fixes with a clear reproduction case
- Pricing table updates when Anthropic publishes new rates
- New model normalisation rules (new model ID patterns from Bedrock, Vertex, etc.)
- UX improvements to the popover that fit the existing design
- Additional usage pattern detectors in `PatternDetector.swift`
- Test coverage gaps

## What probably doesn't

- Features that require a network connection or external service
- Rewriting the build system or SwiftPM structure without a strong reason
- UI redesigns that change the information architecture significantly

If you're unsure, open an issue first.

---

## Getting started

```bash
git clone https://github.com/celadorastudios/claude-o-meter.git
cd claude-o-meter

# Build the .app (recommended — required for notifications and full functionality)
./scripts/build_app.sh
open dist/ClaudeOMeter.app

# Run tests
swift test
```

> **Note:** `swift run` crashes at runtime because `UNUserNotificationCenter` requires a proper app bundle. Use `./scripts/build_app.sh` for all development runs.

Requirements: macOS 14+, Swift toolchain (`xcode-select --install`).

---

## Pull request checklist

- [ ] `swift build` succeeds with no warnings
- [ ] `swift test` passes
- [ ] New logic has unit tests (cost math, model normalisation, pattern detection, etc.)
- [ ] No hardcoded pricing — changes to default prices go in `Sources/ClaudeOMeter/Resources/pricing.json`
- [ ] No new network calls — this tool is intentionally offline
- [ ] Commit messages follow the format in use: `type: description` (feat, fix, refactor, docs, test, chore)

---

## Code style

- Swift standard library only — no third-party dependencies
- Prefer value types; keep mutations explicit
- Small focused files (see existing layout in `Sources/ClaudeOMeter/`)
- No comments explaining *what* the code does — only *why* when the reason is non-obvious
- New views go in `Sources/ClaudeOMeter/Views/`

---

## Reporting bugs

Open a GitHub issue with:
1. macOS version and Swift toolchain version (`swift --version`)
2. What you expected vs what happened
3. Steps to reproduce
4. Diagnostic logs — open the app, go to **Settings → Copy Diagnostic Logs**, and paste the output. For deeper inspection, filter `Console.app` by `ClaudeOMeter`.

---

## Pricing updates

The default pricing table lives in `Sources/ClaudeOMeter/Resources/pricing.json`. If Anthropic publishes new rates, open a PR updating that file with a link to the source. Users override their personal copy in `~/Library/Application Support/ClaudeOMeter/pricing.json` — the bundled file only seeds new installs.
