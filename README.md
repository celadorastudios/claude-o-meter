# Claude-o-Meter

A macOS menu-bar app that tracks your [Claude Code](https://claude.ai/code) API spend in real time — locally, privately, no API keys required.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange)

---

## Who is this for?

Claude-o-Meter is built for developers who are **billed per-token** for Claude Code usage:

- **AWS Bedrock** — Claude models via your AWS account
- **LiteLLM** — self-hosted or managed proxy routing to Claude
- **Anthropic API** — direct API keys with pay-as-you-go billing

Claude Code writes per-token cost data into its local JSONL transcripts for these access methods, which is what Claude-o-Meter reads and aggregates.

> **Claude Pro / Max subscription users:** If you pay Anthropic a flat monthly fee, your transcripts do not contain per-token cost data and Claude-o-Meter will show \$0.00 for everything. Subscription plan support (token-usage tracking, shadow pricing) is [planned for a future release](https://github.com/Deklin/claude-o-meter/issues/11) but not yet implemented.

---

## What it does

Claude Code writes detailed usage logs to `~/.claude/projects/**/*.jsonl`. Claude-o-Meter reads those files incrementally and shows you a live cost breakdown in your menu bar.

| | |
|---|---|
| **Menu bar** | Today's cost; turns red when you exceed your daily budget |
| **3-stat header** | TODAY / MONTH / 30 DAYS at a glance |
| **History chart** | 30-day daily spend by model, or cumulative view |
| **Projects panel** | Per-project cost breakdown with model breakdown, tap to drill down |
| **Spend trend badge** | % up/down vs your prior 7-day average |
| **Usage tips** | Flags Opus-heavy sessions, low cache hit rate, spend spikes |
| **Budget alerts** | macOS notifications when you cross a daily or monthly limit |
| **Editable pricing** | JSON file — supports enterprise/EDP discounts and custom rates |
| **100% local** | Nothing leaves your machine |

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Deklin/claude-o-meter/master/scripts/install.sh | bash
```

This downloads the latest release, installs it to `~/Applications/`, clears the Gatekeeper quarantine flag automatically, and launches the app. No `sudo` required.

> **Manual install:** Download `ClaudeOMeter.zip` from [Releases](https://github.com/Deklin/claude-o-meter/releases), unzip, drag `ClaudeOMeter.app` to `~/Applications/` or `/Applications/`, then run `xattr -dr com.apple.quarantine ~/Applications/ClaudeOMeter.app` before launching.

---

## Build from source

Requires macOS 14+ and Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/Deklin/claude-o-meter.git
cd claude-o-meter

# Build distributable .app (no Dock icon, ad-hoc signed)
./scripts/build_app.sh
open dist/ClaudeOMeter.app

# Dev run (Dock icon visible — useful for iteration)
swift run

# Run tests
swift test
```

---

## Pricing

Default rates are Anthropic API list prices and GPT model-tier rates (USD / 1M tokens). On first launch, Claude-o-Meter writes an editable copy to:

```
~/Library/Application Support/ClaudeOMeter/pricing.json
```

Edit that file and click **Settings → Reload pricing** to apply changes without restarting.

### Current defaults

| Family | Input | Output | Cache Read | Cache Write (5m) | Cache Write (1h) |
|--------|------:|------:|-----------:|-----------------:|-----------------:|
| fable  | $10   | $50   | $1.00      | $12.50           | $20.00           |
| opus   | $5    | $25   | $0.50      | $6.25            | $10.00           |
| sonnet | $3    | $15   | $0.30      | $3.75            | $6.00            |
| haiku  | $1    | $5    | $0.10      | $1.25            | $2.00            |
| luna   | $1.10 | $6.60 | $0          | $0               | $0               |
| terra  | $2.75 | $16.50 | $0         | $0               | $0               |
| sol    | $5.50 | $33.00 | $0         | $0               | $0               |

`claude-opus-4-1` (deprecated model) keeps its legacy $15/$75 rate via an exact-key override.

**Enterprise / EDP discount:** set `"discountPercent": 20` in `pricing.json` for 20% off all computed costs.

When a new build ships with corrected rates, the app auto-upgrades your local `pricing.json` on first launch while preserving your `discountPercent`.

**Verify rates against your own contract** — Bedrock and Vertex rates differ from API list prices.

---

## How it works

```
TranscriptScanner  →  Aggregator  →  UsageStore  →  SwiftUI Views
      (disk)          (pure fold)   (ObservableObject)
```

1. **Incremental scan** — per-file byte cursors mean only newly appended bytes are parsed on each 60s refresh. Thousands of transcript files don't get re-read on every tick.
2. **Dedup by `message.id`** — Claude Code copies transcript lines into resumed and compacted sessions. The same API response can appear in multiple files; each `message.id` is counted exactly once (last occurrence per scan batch wins, so streamed responses always use their final complete token count).
3. **Local day bucketing** — UTC timestamps are converted to local calendar day so spending aligns with your actual workday.
4. **Model normalisation** — raw model strings (`bedrock/us.anthropic.claude-sonnet-4-6`, `openai.gpt-5.6-terra`, etc.) are mapped to a family (`opus`/`sonnet`/`haiku`/`fable`/`luna`/`terra`/`sol`). `<synthetic>` messages cost $0.
5. **State persistence** — scan cursors, seen IDs, aggregates, and settings live in `~/Library/Application Support/ClaudeOMeter/`. Upgrading from an older version migrates state automatically so history and alert settings are preserved.

---

## Alerts & tips

**Budget alerts** fire once per day (daily limit) or once per month (monthly limit) via macOS notifications. Configure limits in **Settings → Spend Alerts**.

**Usage tips** fire at most weekly or monthly and surface patterns like:
- Opus is a large share of recent spend → consider Sonnet for everyday tasks
- Cache hit rate is high → positive reinforcement
- Spend spike vs previous week → flag for review

Disable tips in Settings → Show usage tips.

---

## Project layout

| Directory | Purpose |
|---|---|
| `App/` | Entry point, logging, launch-at-login |
| `Models/` | Domain types and pricing/cost math |
| `Scanner/` | Incremental JSONL reader, dedup, aggregation |
| `Store/` | Observable state and persistence |
| `Alerts/` | Budget thresholds and usage pattern tips |
| `Updates/` | GitHub release polling and auto-install |
| `Views/` | SwiftUI panels, charts, and shared helpers |

```
Resources/
  pricing.json              Bundled default pricing table
scripts/
  build_app.sh              Assembles, signs, and zips ClaudeOMeter.app
Tests/ClaudeOMeterTests/    Unit tests (swift test)
```

---

## Troubleshooting

### macOS blocks the app on first launch

This only applies if you installed manually. The one-line installer clears Gatekeeper automatically.

The app is ad-hoc signed (not notarized). macOS will block it on first launch — this is standard for apps distributed outside the Mac App Store and does not mean the app is harmful.

**Option A — Terminal (fastest)**

```bash
xattr -dr com.apple.quarantine ~/Applications/ClaudeOMeter.app
```

Then double-click the app as normal.

**Option B — System Settings**

1. Click **Done** on the blocked dialog (do _not_ click Move to Bin)
2. Open **System Settings → Privacy & Security**
3. Scroll to the **Security** section — you'll see _"ClaudeOMeter was blocked from use because it is not from an identified developer"_
4. Click **Open Anyway** and authenticate with Touch ID or your password

**Option C — Right-click to open**

Right-click `ClaudeOMeter.app` → **Open** → click **Open** in the confirmation dialog.

### Common issues

| Symptom | Fix |
|---|---|
| Menu bar shows `$0.00` indefinitely | Check that Claude Code has written files to `~/.claude/projects/`. Wait up to 60 seconds for the first scan. |
| Costs look wrong after a pricing change | Open Settings → **Edit pricing.json**, make your changes, then click **Reload pricing**. |
| No budget alert fired | Open **System Settings → Notifications** and ensure notifications are allowed for ClaudeOMeter. |
| `Unknown*` note appears in the popover | A model ID wasn't matched by the normaliser — add its exact key to `pricing.json` and reload. |
| App doesn't appear in menu bar after launch | macOS may have hidden it due to menu bar space constraints. Try closing other menu bar items or reducing icon clutter. |
| Notifications permission prompt never appeared | Go to **System Settings → Notifications → ClaudeOMeter** and enable notifications manually, then use **Settings → Send test alert** to verify. |

### Checking logs

Open **Settings → Copy Diagnostic Logs** to copy the in-memory session log to your clipboard — this is the easiest way to share diagnostics when filing a bug report.

For deeper inspection, open **Console.app**, filter by `ClaudeOMeter`, and reproduce the issue. The app logs scan errors, pricing failures, and notification issues there.

---

## Contributing

Feedback and PRs welcome. Open an issue or ping [@Deklin](https://github.com/Deklin).

---

## License

MIT
