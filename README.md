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

> **Claude Pro / Max subscription users:** If you pay Anthropic a flat monthly fee, your transcripts do not contain per-token cost data and Claude-o-Meter will show \$0.00 for everything. Subscription plan support (token-usage tracking, shadow pricing) is [planned for a future release](https://github.com/celadorastudios/claude-o-meter/issues/2) but not yet implemented.

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
curl -fsSL https://raw.githubusercontent.com/celadorastudios/claude-o-meter/master/scripts/install.sh | bash
```

This downloads the latest release, installs it to `~/Applications/`, clears the Gatekeeper quarantine flag automatically, and launches the app. No `sudo` required.

> **Manual install:** Download `ClaudeOMeter.zip` from [Releases](https://github.com/celadorastudios/claude-o-meter/releases), unzip, drag `ClaudeOMeter.app` to `~/Applications/`, then run `xattr -dr com.apple.quarantine ~/Applications/ClaudeOMeter.app` before launching.
>
> `~/Applications` is the recommended location. It needs no admin rights, so the app can update itself without ever asking for your password. `/Applications` works too, and updates follow the app wherever you put it, but writing there requires admin rights.

### Why the quarantine step is needed

The app is ad-hoc signed rather than signed with an Apple Developer ID, so macOS cannot
attribute it to a registered developer and Gatekeeper blocks it on first launch. Clearing
the quarantine flag is what gets past that.

Because you are being asked to disable a safety check, you should be able to confirm the
download is genuinely ours. Every release is published with GitHub build provenance, which
ties the zip to the exact commit and workflow run that produced it.

**The installer checks this for you, and so does the in-app updater.** Neither needs any
tooling you do not already have, just `curl` and `shasum` on the command line and the
system frameworks in the app.

The check is required, not advisory: if provenance cannot be confirmed, nothing is
installed and your existing copy is left untouched. Two different failures are reported
separately, because they mean different things.

| What you see | What it means |
| --- | --- |
| `no build provenance found` | GitHub answered, and it holds no attestation for this file. Either it did not come from this repository's release workflow, or it was modified afterwards. Do not run it. |
| `could not reach GitHub to verify` | The check could not be completed (offline, rate limited, or an outage). This says nothing about the file itself. Retry. |

The second case still refuses to install, which is deliberate. Anyone able to substitute
the release asset is also able to block `api.github.com`, so treating an unreachable API
as a pass would hand the exact adversary this check exists to stop a one-host bypass. If
you understand that and need to proceed anyway during an outage, set
`CLAUDEOMETER_INSECURE=1`.

To check a manual download yourself:

```bash
shasum -a 256 ClaudeOMeter.zip                     # note the digest
curl -s https://api.github.com/repos/celadorastudios/claude-o-meter/attestations/sha256:<digest>
```

A response containing an attestation bundle means GitHub confirms that file came out of
this repository's release workflow. If you have the GitHub CLI, `gh attestation verify
ClaudeOMeter.zip --repo celadorastudios/claude-o-meter` does the full offline cryptographic
check instead, but it is not required.

---

## Build from source

Requires macOS 14+ and Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/celadorastudios/claude-o-meter.git
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

The exact Mantle routes for [GPT-6.1 Sol](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-6-1-sol.html), [GPT-6 Sol](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-6-sol.html), and [GPT-6 Luna](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-6-luna.html) use AWS regional Standard prices.
Their keys are `bedrock_mantle/openai.gpt-6.1-sol`, `bedrock_mantle/openai.gpt-6-sol`, and `bedrock_mantle/openai.gpt-6-luna`.
Each has an explicit `[1m]` variant with the same rates; the suffix changes capacity, not the billing tier.

| Model | Request input tokens | Input | Output | Cache Read | Cache Write (30m) |
|---|---|------:|-------:|-----------:|------------------:|
| GPT-6.1 Sol | Up to 272,000 | $2.20 | $11.00 | $0.11 | $2.75 |
| GPT-6.1 Sol | More than 272,000 | $4.40 | $16.50 | $0.22 | $5.50 |
| GPT-6 Sol | Up to 272,000 | $2.20 | $11.00 | $0.22 | $2.75 |
| GPT-6 Sol | More than 272,000 | $4.40 | $16.50 | $0.44 | $5.50 |
| GPT-6 Luna | Up to 272,000 | $0.11 | $0.55 | $0.011 | $0.1375 |
| GPT-6 Luna | More than 272,000 | $0.22 | $0.825 | $0.022 | $0.275 |

The input threshold includes fresh input, cache reads, and cache writes, but not output tokens.
Above the threshold, the higher rates apply to the whole request.
The scanner stores unsplit 30-minute cache writes in the existing `cacheWrite5m` bucket.
Both transcript cache-write buckets use the model's single 30-minute write rate; a `cacheWrite1h` label does not make those tokens free or imply a supported one-hour TTL.
These regional prices already include the premium, so the domestic flag does not add it again for these six exact routes.
Other OpenAI routes retain their existing lookup behavior; Global inference and Ultrafast are not covered by these overrides.

The Bedrock Sonnet 5.5 entries also include [AWS's cache-read price reduction](https://aws.amazon.com/bedrock/pricing/) from October 7, 2026.
For `us.anthropic.claude-sonnet-5-5`, cache reads cost $0.22/M before that UTC date and $0.11/M from that date.
For `global.anthropic.claude-sonnet-5-5`, they cost $0.20/M before that date and $0.10/M from that date.
The prior Global read rate follows from the documented 50% reduction.
Other token rates are unchanged, and a missing request date uses the earlier base price.
These dated entries do not change the bare direct-API entry `claude-sonnet-5-5` or the generic family defaults.

This table is not a complete AWS price catalog.
Haiku 5.5, GPT-6.1 Terra, and GPT-5.6 route-specific updates are not bundled because their complete context-band rules have not been established for this calculation.

**Enterprise / EDP discount:** set `"discountPercent": 20` in `pricing.json` for 20% off all computed costs.

### Configure model prices and price changes

An exact entry in `models` can price a new model without a code change.
The lookup checks the full model ID first, then the ID without its provider prefix, then its family, then the fallback.
Use lowercase keys and explicit entries for differently billed routes.
An unfamiliar model family can still display as `Unknown*` even when an exact entry supplies its prices.

The optional `longContextThreshold` and `longContext` fields configure two whole-request price bands.
The threshold counts fresh input and all cache tokens, not output.
Requests above the threshold use the higher band for every token.
Use these fields only when the provider documents those rules.
Cache-write fields price the reported transcript buckets; they do not infer an unreported cache lifetime.

To change rates from a known date, add complete prices under `modelPriceHistory` for the same model key.
Each `effectiveFrom` is an inclusive UTC date in `YYYY-MM-DD` format.
The latest revision on or before the request's UTC date applies.
The base entry in `models` applies before the first revision or when the request date is unknown.
A revision replaces the whole model price, including any context band and fast multiplier; it does not inherit omitted fields.

This example uses hypothetical rates, not a provider price list:

```json
{
  "models": {
    "vendor/example-model": {
      "input": 2,
      "output": 10,
      "cacheRead": 0.2,
      "cacheWrite5m": 2.5,
      "cacheWrite1h": 4
    }
  },
  "modelPriceHistory": {
    "vendor/example-model": [
      {
        "effectiveFrom": "2026-11-01",
        "price": {
          "input": 2,
          "output": 10,
          "cacheRead": 0.1,
          "cacheWrite5m": 2.5,
          "cacheWrite1h": 4
        }
      }
    ]
  }
}
```

Add these entries to your existing file; do not replace the whole table with the example.
Edit a base entry to correct a rate for all recorded dates that have no applicable revision.
Add a dated revision for a real price change, so earlier requests keep their earlier rates.
Dates must be real calendar dates, must not repeat for one model key, and must have a corresponding base entry.
Revised rates must be nonnegative, and a revised context band must include both its threshold and rates.
Base entries still use the permissive legacy decoder; check that a base context band includes both fields, because an incomplete band uses short rates without a validation error.
Prices are configured locally; the app does not fetch provider prices.

### Pricing upgrades and stored history

A newer bundled pricing version adds new model entries and updates defaults that the user has not edited.
The app uses `pricing-defaults.json` beside the editable file to identify the previous defaults.
It preserves custom model prices, dated revisions, discounts, and table settings, and backs up `pricing.json` before an upgrade.
On the first upgrade without a recorded baseline, it preserves existing prices because it cannot tell defaults from custom edits.
Existing short-only overrides therefore stay short-only; add verified context bands explicitly if you want them.
A malformed editable file is left unchanged; the app logs the error and uses bundled prices in memory.

The accounting upgrade rebuilds stored history from surviving local transcripts once, including project totals.
No manual reset is needed.
Deleted transcripts cannot be rebuilt during that migration.
After the upgrade, model and project usage retain the original UTC rate day, prompt length, and surcharge flags, so later pricing changes can recalculate retained history without reading the transcripts again.
Charts still group costs by local calendar day.
The retained pricing groups contain token totals, not message IDs, message text, or full timestamps, and expire with the 31-day history window.
Exact prompt lengths can produce nearly one group per request, stored for each model and project.
This increases snapshot size and save time, but preserves the inputs needed if a model later gains a context band.

Reload pricing recalculates model totals, project totals, and surcharges.
Startup also detects pricing-content changes even when the pricing version is unchanged.
Legacy aggregates without the required pricing inputs use conservative model estimates and retain stored project dollars until a full rescan.
The context-bloat advisory remains a conservative short-context estimate because its taxable token slices do not retain request lengths or UTC rate dates.

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

Feedback and PRs welcome. Open an issue or ping [@celadorastudios](https://github.com/celadorastudios).

---

## License

MIT
