# AGENTS.md

Guidance for coding agents working in this repo. Claude Code loads it via the `@AGENTS.md` import in `CLAUDE.md`.

## Stack

Swift 6.0 (`swift-tools-version`), macOS 14+, SwiftUI, SwiftPM. Menu-bar app, no external package dependencies.

## Commands

```bash
swift test --filter ClaudeOMeterTests/testParseLineDedupsByMessageID  # single test
swift test                     # all tests
swift run                      # dev run (Dock icon visible — useful for iteration)
./scripts/build_app.sh         # build distributable .app (no Dock icon, ad-hoc signed)
open dist/ClaudeOMeter.app
```

## Architecture

One-way data flow: `TranscriptScanner → Aggregator → UsageStore → SwiftUI Views`.

- **`TranscriptScanner`** — reads `~/.claude/projects/**/*.jsonl` incrementally via per-file byte cursors (`ScanState.cursors`); global dedup by `message.id` in `ScanState.seenIDs`.
- **`Aggregator`** — pure fold of `[UsageRecord]` → `[String: DailyAggregate]`, no side effects (trivially testable).
- **`UsageStore`** (`@MainActor`) — single source of truth; a 60s timer scans off-main, then `apply()` folds new records, prunes, fires alerts/tips, and persists.
- **`Persistence`** — owns `~/Library/Application Support/ClaudeOMeter/`: `state.json` (full snapshot) + user-editable `pricing.json`.
- **`PricingTable`** (`Pricing.swift`) — exact raw-model key → family key → fallback; `Aggregator.recost` re-applies exact prices after a pricing reload.

## Key invariants

- **Dedup is essential**: the same `message.id` appears across JSONL files when sessions resume/compact; raw line counts overstate cost 2×+. Always go through `ScanState.seenIDs`.
- **`<synthetic>` messages cost $0**: `ModelNormalizer.syntheticFamily` is checked in `PricingTable.cost` before any arithmetic.
- **Byte cursors must never skip past the last newline**: partial trailing lines are re-read on the next scan pass.
- **Aggregate by local calendar day, not UTC**: `DayBucket.localDay(fromISO:)` converts each line's UTC timestamp.
- **Bundle resources**: `Persistence.loadPricing()` uses `Bundle.main.url(forResource:subdirectory:)` with the SwiftPM sub-bundle name `ClaudeOMeter_ClaudeOMeter.bundle` (not `Bundle.module`) — codesign requires resources under `Contents/`.

## Testing

Tests use **XCTest** (`Tests/ClaudeOMeterTests/`). No mocking — `Aggregator` is a pure function tested directly against fixtures. Run `swift test`; add cases beside the existing dedup/aggregation tests.

## Git workflow

Conventional commits (`feat/fix/refactor/docs/test/chore/perf/ci`), PR-based, `master` base branch. Analyze the full commit range with `git diff master...HEAD` when writing PR summaries.
