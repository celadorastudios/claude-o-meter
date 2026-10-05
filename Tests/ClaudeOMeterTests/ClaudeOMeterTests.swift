import XCTest
@testable import ClaudeOMeter

final class ClaudeOMeterTests: XCTestCase {

    // MARK: - Model normalization

    func testNormalizationHandlesBedrockAndVersions() {
        XCTAssertEqual(ModelNormalizer.family(for: "claude-opus-4-8"), "opus")
        XCTAssertEqual(ModelNormalizer.family(for: "bedrock/us.anthropic.claude-opus-4-8"), "opus")
        XCTAssertEqual(ModelNormalizer.family(for: "claude-sonnet-4-5-20250929"), "sonnet")
        XCTAssertEqual(ModelNormalizer.family(for: "bedrock/us.anthropic.claude-sonnet-4-5-20250929-v1:0"), "sonnet")
        XCTAssertEqual(ModelNormalizer.family(for: "claude-haiku-4-5-20251001"), "haiku")
        XCTAssertEqual(ModelNormalizer.family(for: "<synthetic>"), "synthetic")
    }

    func testNormalizationBedrockSonnet46() {
        // Primary Bedrock model used in production — must not fall through to "unknown".
        XCTAssertEqual(ModelNormalizer.family(for: "bedrock/us.anthropic.claude-sonnet-4-6"), "sonnet")
        XCTAssertEqual(ModelNormalizer.family(for: "bedrock/us.anthropic.claude-sonnet-4-6-20251224"), "sonnet")
    }

    func testNormalizationFableFamily() {
        XCTAssertEqual(ModelNormalizer.family(for: "claude-fable-4-0"), "fable")
        XCTAssertEqual(ModelNormalizer.family(for: "bedrock/us.anthropic.claude-fable-4-0"), "fable")
        XCTAssertEqual(ModelNormalizer.family(for: "claude-mythos-1-0"), "fable")
    }

    func testNormalizationGPTModels() {
        XCTAssertEqual(ModelNormalizer.family(for: "openai.gpt-5.6-luna"), "luna")
        XCTAssertEqual(ModelNormalizer.family(for: "openai.gpt-5.6-terra"), "terra")
        XCTAssertEqual(ModelNormalizer.family(for: "openai.gpt-5.6-sol"), "sol")
    }

    func testNormalizationUnknownReturnsFallback() {
        XCTAssertEqual(ModelNormalizer.family(for: "some-future-model-xyz"), "unknown")
        XCTAssertEqual(ModelNormalizer.family(for: ""), "unknown")
    }

    func testNormalizationCaseInsensitive() {
        XCTAssertEqual(ModelNormalizer.family(for: "Claude-Opus-4-8"), "opus")
        XCTAssertEqual(ModelNormalizer.family(for: "CLAUDE-SONNET-4-6"), "sonnet")
    }

    func testNormalizationDeprecatedOpusStillNormalizesToOpusFamily() {
        // claude-opus-4-1 normalizes to "opus" family; exact-key pricing kicks in via PricingTable.
        XCTAssertEqual(ModelNormalizer.family(for: "claude-opus-4-1"), "opus")
    }

    // MARK: - Pricing: current families (corrected rates)

    func testOpusInputRateIsCorrect() {
        // Bug fix: opus was incorrectly priced at $15/M. Correct rate is $5/M.
        let pricing = PricingTable.default
        let usage = TokenUsage(input: 1_000_000)
        XCTAssertEqual(pricing.cost(of: usage, family: "opus", rawModel: "claude-opus-4-8"), 5.0, accuracy: 1e-9)
    }

    func testOpusOutputRateIsCorrect() {
        // Bug fix: opus was incorrectly priced at $75/M output. Correct rate is $25/M.
        let pricing = PricingTable.default
        let usage = TokenUsage(output: 1_000_000)
        XCTAssertEqual(pricing.cost(of: usage, family: "opus", rawModel: "claude-opus-4-8"), 25.0, accuracy: 1e-9)
    }

    func testOpusAllTiers() {
        let pricing = PricingTable.default
        let usage = TokenUsage(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000,
                               cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000)
        // 5 + 25 + 0.5 + 6.25 + 10 = 46.75
        XCTAssertEqual(pricing.cost(of: usage, family: "opus", rawModel: "claude-opus-4-8"), 46.75, accuracy: 1e-9)
    }

    func testSonnetRates() {
        let pricing = PricingTable.default
        let inputUsage = TokenUsage(input: 1_000_000)
        let outputUsage = TokenUsage(output: 1_000_000)
        XCTAssertEqual(pricing.cost(of: inputUsage, family: "sonnet", rawModel: "claude-sonnet-4-6"), 3.0, accuracy: 1e-9)
        XCTAssertEqual(pricing.cost(of: outputUsage, family: "sonnet", rawModel: "claude-sonnet-4-6"), 15.0, accuracy: 1e-9)
    }

    func testSonnetBedrockModelUsesCorrectRates() {
        // Bedrock model strings must resolve to correct sonnet pricing, not unknown fallback.
        let pricing = PricingTable.default
        let usage = TokenUsage(input: 1_000_000)
        XCTAssertEqual(
            pricing.cost(of: usage, family: "sonnet", rawModel: "bedrock/us.anthropic.claude-sonnet-4-6"),
            3.0, accuracy: 1e-9
        )
    }

    func testSonnetAllTiers() {
        let pricing = PricingTable.default
        let usage = TokenUsage(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000,
                               cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000)
        // 3 + 15 + 0.3 + 3.75 + 6 = 28.05
        XCTAssertEqual(pricing.cost(of: usage, family: "sonnet", rawModel: "claude-sonnet-4-6"), 28.05, accuracy: 1e-9)
    }

    func testHaikuRates() {
        let pricing = PricingTable.default
        let inputUsage = TokenUsage(input: 1_000_000)
        let outputUsage = TokenUsage(output: 1_000_000)
        XCTAssertEqual(pricing.cost(of: inputUsage, family: "haiku", rawModel: "claude-haiku-4-5"), 1.0, accuracy: 1e-9)
        XCTAssertEqual(pricing.cost(of: outputUsage, family: "haiku", rawModel: "claude-haiku-4-5"), 5.0, accuracy: 1e-9)
    }

    func testHaikuAllTiers() {
        let pricing = PricingTable.default
        let usage = TokenUsage(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000,
                               cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000)
        // 1 + 5 + 0.1 + 1.25 + 2 = 9.35
        XCTAssertEqual(pricing.cost(of: usage, family: "haiku", rawModel: "claude-haiku-4-5"), 9.35, accuracy: 1e-9)
    }

    func testFableRates() {
        let pricing = PricingTable.default
        let inputUsage = TokenUsage(input: 1_000_000)
        let outputUsage = TokenUsage(output: 1_000_000)
        XCTAssertEqual(pricing.cost(of: inputUsage, family: "fable", rawModel: "claude-fable-4-0"), 10.0, accuracy: 1e-9)
        XCTAssertEqual(pricing.cost(of: outputUsage, family: "fable", rawModel: "claude-fable-4-0"), 50.0, accuracy: 1e-9)
    }

    func testFableAllTiers() {
        let pricing = PricingTable.default
        let usage = TokenUsage(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000,
                               cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000)
        // 10 + 50 + 1.0 + 12.5 + 20 = 93.5
        XCTAssertEqual(pricing.cost(of: usage, family: "fable", rawModel: "claude-fable-4-0"), 93.5, accuracy: 1e-9)
    }

    func testGPTRatesAndZeroCachePricing() {
        let pricing = PricingTable.default
        let usage = TokenUsage(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000,
                               cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000)

        XCTAssertEqual(pricing.cost(of: usage, family: "luna", rawModel: "openai.gpt-5.6-luna"), 7.7, accuracy: 1e-9)
        XCTAssertEqual(pricing.cost(of: usage, family: "terra", rawModel: "openai.gpt-5.6-terra"), 19.25, accuracy: 1e-9)
        XCTAssertEqual(pricing.cost(of: usage, family: "sol", rawModel: "openai.gpt-5.6-sol"), 38.5, accuracy: 1e-9)
    }

    // MARK: - Pricing: exact-key override (deprecated claude-opus-4-1)

    func testDeprecatedOpusExactKeyPricing() {
        // claude-opus-4-1 uses legacy $15/$75 via an exact-key override, not the family $5/$25 rate.
        let pricing = PricingTable.default
        let inputUsage = TokenUsage(input: 1_000_000)
        let outputUsage = TokenUsage(output: 1_000_000)
        XCTAssertEqual(pricing.cost(of: inputUsage, family: "opus", rawModel: "claude-opus-4-1"), 15.0, accuracy: 1e-9)
        XCTAssertEqual(pricing.cost(of: outputUsage, family: "opus", rawModel: "claude-opus-4-1"), 75.0, accuracy: 1e-9)
    }

    func testDeprecatedOpusExactKeyAllTiers() {
        let pricing = PricingTable.default
        let usage = TokenUsage(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000,
                               cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000)
        // 15 + 75 + 1.5 + 18.75 + 30 = 140.25
        XCTAssertEqual(pricing.cost(of: usage, family: "opus", rawModel: "claude-opus-4-1"), 140.25, accuracy: 1e-9)
    }

    func testCurrentOpusDoesNotUseDeprecatedRate() {
        // claude-opus-4-8 has an exact-key entry (for fastMultiplier) but at the same $5/$25 rate as the family.
        let pricing = PricingTable.default
        let usage = TokenUsage(input: 1_000_000)
        XCTAssertEqual(pricing.cost(of: usage, family: "opus", rawModel: "claude-opus-4-8"), 5.0, accuracy: 1e-9)
        XCTAssertNotNil(pricing.models["claude-opus-4-8"], "claude-opus-4-8 has an exact-key entry for fastMultiplier")
    }

    // MARK: - Pricing: fallback for unknown models

    func testUnknownModelFallbackPricing() {
        let pricing = PricingTable.default
        let usage = TokenUsage(input: 1_000_000)
        // Fallback = current opus rate ($5/M input)
        XCTAssertEqual(pricing.cost(of: usage, family: "unknown", rawModel: "some-future-model"), 5.0, accuracy: 1e-9)
    }

    func testFallbackIsOpusRate() {
        // Fallback should equal the opus family rate so unknown models are not over- or under-charged.
        let pricing = PricingTable.default
        let opusRate = pricing.models["opus"]!
        let fallback = pricing.fallback!
        XCTAssertEqual(opusRate.input, fallback.input)
        XCTAssertEqual(opusRate.output, fallback.output)
        XCTAssertEqual(opusRate.cacheRead, fallback.cacheRead)
    }

    // MARK: - Pricing: discount

    func testDiscountPercentAppliesToTotal() {
        var pricing = PricingTable.default
        pricing.discountPercent = 20
        let usage = TokenUsage(input: 1_000_000) // base $5 for current opus
        XCTAssertEqual(pricing.cost(of: usage, family: "opus", rawModel: "claude-opus-4-8"), 4.0, accuracy: 1e-9)
    }

    func testDiscountNilDefaultsToZero() {
        var pricing = PricingTable.default
        pricing.discountPercent = nil
        let usage = TokenUsage(output: 1_000_000) // $25 for opus
        XCTAssertEqual(pricing.cost(of: usage, family: "opus", rawModel: "claude-opus-4-8"), 25.0, accuracy: 1e-9)
    }

    func testDiscountClampsAt100Percent() {
        var pricing = PricingTable.default
        pricing.discountPercent = 150 // should clamp → free
        let usage = TokenUsage(output: 1_000_000)
        XCTAssertEqual(pricing.cost(of: usage, family: "opus", rawModel: "claude-opus-4-8"), 0.0, accuracy: 1e-9)
    }

    func testDiscountZeroMeansFullPrice() {
        var pricing = PricingTable.default
        pricing.discountPercent = 0
        let usage = TokenUsage(input: 1_000_000)
        XCTAssertEqual(pricing.cost(of: usage, family: "opus", rawModel: "claude-opus-4-8"), 5.0, accuracy: 1e-9)
    }

    func testDiscountAppliesAfterExactKeyLookup() {
        var pricing = PricingTable.default
        pricing.discountPercent = 50
        let usage = TokenUsage(input: 1_000_000)
        // claude-opus-4-1 base $15, 50% off = $7.5
        XCTAssertEqual(pricing.cost(of: usage, family: "opus", rawModel: "claude-opus-4-1"), 7.5, accuracy: 1e-9)
    }

    // MARK: - Pricing: synthetic costs $0

    func testSyntheticCostsZero() {
        let pricing = PricingTable.default
        let usage = TokenUsage(input: 1_000_000, output: 1_000_000)
        XCTAssertEqual(pricing.cost(of: usage, family: "synthetic", rawModel: "<synthetic>"), 0)
    }

    func testSyntheticCostsZeroRegardlessOfTokenCount() {
        let pricing = PricingTable.default
        let usage = TokenUsage(input: 10_000_000, output: 10_000_000, cacheRead: 10_000_000,
                               cacheWrite5m: 10_000_000, cacheWrite1h: 10_000_000)
        XCTAssertEqual(pricing.cost(of: usage, family: "synthetic", rawModel: "<synthetic>"), 0)
    }

    // MARK: - Pricing: version field

    func testDefaultPricingTableHasVersion() {
        XCTAssertNotNil(PricingTable.default.version)
        XCTAssertGreaterThan(PricingTable.default.version!, 0)
    }

    // MARK: - Parsing

    func testParseLineDedupsByMessageID() {
        let line = #"{"type":"assistant","timestamp":"2026-06-18T13:23:34.197Z","message":{"id":"msg_1","model":"claude-opus-4-8","usage":{"input_tokens":10,"output_tokens":925,"cache_read_input_tokens":0,"cache_creation_input_tokens":83074}}}"#
        let data = Data(line.utf8)

        let rec = TranscriptScanner.parseCandidate(data)
        XCTAssertNotNil(rec)
        XCTAssertEqual(rec?.usage.input, 10)
        XCTAssertEqual(rec?.usage.output, 925)
        XCTAssertEqual(rec?.model, "opus")
        XCTAssertEqual(rec?.id, "msg_1")

        var seenIDs: [String: String] = [:]
        if let r = rec { seenIDs[r.id] = r.day }
        let second = TranscriptScanner.parseCandidate(data)
        XCTAssertNotNil(second)
        XCTAssertNotNil(seenIDs[second!.id])
    }

    func testParseCandidateBedrockModel() {
        let line = #"{"type":"assistant","timestamp":"2026-06-18T12:00:00.000Z","message":{"id":"msg_bedrock","model":"bedrock/us.anthropic.claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":200}}}"#
        let rec = TranscriptScanner.parseCandidate(Data(line.utf8))
        XCTAssertNotNil(rec)
        XCTAssertEqual(rec?.model, "sonnet")
        XCTAssertEqual(rec?.usage.input, 100)
        XCTAssertEqual(rec?.usage.output, 200)
    }

    func testParseCandidateDeprecatedOpus() {
        let line = #"{"type":"assistant","timestamp":"2026-06-18T12:00:00.000Z","message":{"id":"msg_old_opus","model":"claude-opus-4-1","usage":{"input_tokens":500,"output_tokens":1000}}}"#
        let rec = TranscriptScanner.parseCandidate(Data(line.utf8))
        XCTAssertNotNil(rec)
        // Family is "opus" but rawModel is "claude-opus-4-1" — exact-key pricing applies downstream.
        XCTAssertEqual(rec?.model, "opus")
        XCTAssertEqual(rec?.rawModel, "claude-opus-4-1")
    }

    func testParseUsagePrefersCacheBreakdown() {
        let u: [String: Any] = [
            "input_tokens": 5,
            "output_tokens": 6,
            "cache_read_input_tokens": 7,
            "cache_creation_input_tokens": 100,
            "cache_creation": ["ephemeral_5m_input_tokens": 60, "ephemeral_1h_input_tokens": 40],
        ]
        let usage = TranscriptScanner.parseUsage(u)
        XCTAssertEqual(usage.cacheWrite5m, 60)
        XCTAssertEqual(usage.cacheWrite1h, 40)
        XCTAssertEqual(usage.cacheRead, 7)
    }

    func testParseUsageFallsBackWhenNoBreakdown() {
        let u: [String: Any] = ["cache_creation_input_tokens": 100]
        let usage = TranscriptScanner.parseUsage(u)
        XCTAssertEqual(usage.cacheWrite5m, 100)
        XCTAssertEqual(usage.cacheWrite1h, 0)
    }

    func testParseCandidateIgnoresNonAssistant() {
        let line = #"{"type":"user","timestamp":"2026-06-18T12:00:00.000Z","message":{"id":"msg_u","role":"user","content":"hello"}}"#
        let rec = TranscriptScanner.parseCandidate(Data(line.utf8))
        XCTAssertNil(rec)
    }

    func testParseCandidateIgnoresMalformed() {
        XCTAssertNil(TranscriptScanner.parseCandidate(Data("not json".utf8)))
        XCTAssertNil(TranscriptScanner.parseCandidate(Data("{}".utf8)))
        XCTAssertNil(TranscriptScanner.parseCandidate(Data("".utf8)))
    }

    // MARK: - Aggregation

    func testFoldAccumulatesPerModelAndDay() {
        var aggs: [String: DailyAggregate] = [:]
        let r1 = UsageRecord(id: "a", day: "2026-06-20", hour: 0, model: "opus", rawModel: "claude-opus-4-8",
                             usage: TokenUsage(input: 1_000_000), projectDir: "")
        let r2 = UsageRecord(id: "b", day: "2026-06-20", hour: 0, model: "opus", rawModel: "claude-opus-4-8",
                             usage: TokenUsage(output: 1_000_000), projectDir: "")
        Aggregator.fold(records: [r1, r2], into: &aggs, pricing: .default)

        let day = aggs["2026-06-20"]
        XCTAssertNotNil(day)
        XCTAssertEqual(day?.perModel["opus"]?.usage.input, 1_000_000)
        XCTAssertEqual(day?.perModel["opus"]?.usage.output, 1_000_000)
        // opus 4.5+: $5 (input) + $25 (output) = $30
        XCTAssertEqual(day?.totalCost ?? 0, 30.0, accuracy: 1e-9)
    }

    func testFoldMultipleDays() {
        var aggs: [String: DailyAggregate] = [:]
        let r1 = UsageRecord(id: "a", day: "2026-06-19", hour: 0, model: "sonnet", rawModel: "claude-sonnet-4-6",
                             usage: TokenUsage(input: 1_000_000), projectDir: "")
        let r2 = UsageRecord(id: "b", day: "2026-06-20", hour: 0, model: "sonnet", rawModel: "claude-sonnet-4-6",
                             usage: TokenUsage(input: 1_000_000), projectDir: "")
        Aggregator.fold(records: [r1, r2], into: &aggs, pricing: .default)
        XCTAssertEqual(aggs.count, 2)
        XCTAssertEqual(aggs["2026-06-19"]?.totalCost ?? 0, 3.0, accuracy: 1e-9)
        XCTAssertEqual(aggs["2026-06-20"]?.totalCost ?? 0, 3.0, accuracy: 1e-9)
    }

    func testFoldDeprecatedOpusUsesExactKeyRate() {
        // Verifies that aggregation correctly prices claude-opus-4-1 at $15/M, not $5/M.
        var aggs: [String: DailyAggregate] = [:]
        let r = UsageRecord(id: "a", day: "2026-06-20", hour: 0, model: "opus", rawModel: "claude-opus-4-1",
                            usage: TokenUsage(input: 1_000_000), projectDir: "")
        Aggregator.fold(records: [r], into: &aggs, pricing: .default)
        XCTAssertEqual(aggs["2026-06-20"]?.totalCost ?? 0, 15.0, accuracy: 1e-9)
    }

    func testFoldCurrentOpusUsesNewRate() {
        // Verifies claude-opus-4-8 is priced at $5/M (not the old incorrect $15/M).
        var aggs: [String: DailyAggregate] = [:]
        let r = UsageRecord(id: "a", day: "2026-06-20", hour: 0, model: "opus", rawModel: "claude-opus-4-8",
                            usage: TokenUsage(input: 1_000_000), projectDir: "")
        Aggregator.fold(records: [r], into: &aggs, pricing: .default)
        XCTAssertEqual(aggs["2026-06-20"]?.totalCost ?? 0, 5.0, accuracy: 1e-9)
    }

    // MARK: - Context tax (taxable cache-read)

    func testTaxableCacheReadZeroBelowCap() {
        // ctx = 100k input + 50k cacheRead = 150k, under the 200k cap → no tax.
        let r = UsageRecord(id: "a", day: "2026-06-20", hour: 0, model: "opus", rawModel: "claude-opus-4-8",
                            usage: TokenUsage(input: 100_000, cacheRead: 50_000), projectDir: "")
        XCTAssertEqual(Aggregator.taxableCacheRead(for: r), 0)
    }

    func testTaxableCacheReadAboveCap() {
        // ctx = 300k (all cacheRead). over = (300k-200k)/300k = 1/3.
        // taxable = round(300k × 1/3) = 100_000.
        let r = UsageRecord(id: "a", day: "2026-06-20", hour: 0, model: "opus", rawModel: "claude-opus-4-8",
                            usage: TokenUsage(cacheRead: 300_000), projectDir: "")
        XCTAssertEqual(Aggregator.taxableCacheRead(for: r), 100_000)
    }

    func testTaxableCacheReadZeroForSynthetic() {
        let r = UsageRecord(id: "a", day: "2026-06-20", hour: 0, model: ModelNormalizer.syntheticFamily,
                            rawModel: "<synthetic>",
                            usage: TokenUsage(cacheRead: 300_000), projectDir: "")
        XCTAssertEqual(Aggregator.taxableCacheRead(for: r), 0)
    }

    func testTaxableCacheReadZeroWithNoCacheRead() {
        // Above the cap on input alone, but no cache-read to tax.
        let r = UsageRecord(id: "a", day: "2026-06-20", hour: 0, model: "opus", rawModel: "claude-opus-4-8",
                            usage: TokenUsage(input: 300_000), projectDir: "")
        XCTAssertEqual(Aggregator.taxableCacheRead(for: r), 0)
    }

    func testFoldAccumulatesTaxableCacheReadPerFamilyAndProject() {
        var aggs: [String: DailyAggregate] = [:]
        // Two above-cap opus turns in different projects; one below-cap turn adds nothing.
        let r1 = UsageRecord(id: "a", day: "2026-06-20", hour: 0, model: "opus", rawModel: "claude-opus-4-8",
                             usage: TokenUsage(cacheRead: 300_000), projectDir: "proj-a")  // taxable 100k
        let r2 = UsageRecord(id: "b", day: "2026-06-20", hour: 0, model: "opus", rawModel: "claude-opus-4-8",
                             usage: TokenUsage(cacheRead: 400_000), projectDir: "proj-b")  // over=1/2 → 200k
        let r3 = UsageRecord(id: "c", day: "2026-06-20", hour: 0, model: "opus", rawModel: "claude-opus-4-8",
                             usage: TokenUsage(cacheRead: 50_000), projectDir: "proj-a")   // below cap → 0
        Aggregator.fold(records: [r1, r2, r3], into: &aggs, pricing: .default)

        let day = aggs["2026-06-20"]
        XCTAssertEqual(day?.taxableCacheRead["opus"], 300_000)                 // 100k + 200k
        XCTAssertEqual(day?.perProject["proj-a"]?.taxableCacheRead["opus"], 100_000)
        XCTAssertEqual(day?.perProject["proj-b"]?.taxableCacheRead["opus"], 200_000)
    }

    func testDecodesOldAggregateWithoutTaxableCacheRead() {
        // An old state.json predating the context-tax field must decode without throwing —
        // otherwise the whole [String: DailyAggregate] decode fails and wipes history. The
        // missing taxableCacheRead (both on the day and on each project) defaults to empty.
        let json = #"""
        {
          "day": "2026-06-20",
          "perModel": { "opus": { "model": "opus", "rawModel": "claude-opus-4-8",
            "usage": { "input": 1000000, "output": 0, "cacheRead": 0, "cacheWrite5m": 0, "cacheWrite1h": 0 },
            "cost": 5.0 } },
          "perProject": { "proj-a": { "cost": 5.0, "perModel": { "opus": 5.0 } } }
        }
        """#
        let agg = try? JSONDecoder().decode(DailyAggregate.self, from: Data(json.utf8))
        XCTAssertNotNil(agg, "old aggregate without taxableCacheRead must decode")
        XCTAssertEqual(agg?.taxableCacheRead, [:])
        XCTAssertEqual(agg?.perModel["opus"]?.cost ?? 0, 5.0, accuracy: 1e-9)
        XCTAssertEqual(agg?.perProject["proj-a"]?.cost ?? 0, 5.0, accuracy: 1e-9)
        XCTAssertEqual(agg?.perProject["proj-a"]?.perModel["opus"] ?? 0, 5.0, accuracy: 1e-9)
        XCTAssertEqual(agg?.perProject["proj-a"]?.taxableCacheRead, [:])
    }

    func testDecodesOldSettingsWithoutProjectsConfigDirOverride() {
        // An old state.json's AlertSettings predating the transcript-root override must decode
        // without throwing; the missing field defaults to nil (use env var / default root).
        let missing = #"{ "dailyThreshold": 5.0, "tipsEnabled": true, "approachPercent": 80 }"#
        let s1 = try? JSONDecoder().decode(AlertSettings.self, from: Data(missing.utf8))
        XCTAssertNotNil(s1, "old settings without projectsConfigDirOverride must decode")
        XCTAssertNil(s1?.projectsConfigDirOverride)

        // An explicit null decodes to nil as well.
        let explicitNull = #"{ "projectsConfigDirOverride": null }"#
        let s2 = try? JSONDecoder().decode(AlertSettings.self, from: Data(explicitNull.utf8))
        XCTAssertNotNil(s2)
        XCTAssertNil(s2?.projectsConfigDirOverride)

        // A stored string value round-trips.
        let withValue = #"{ "projectsConfigDirOverride": "~/.claude/cpm/profiles/personal" }"#
        let s3 = try? JSONDecoder().decode(AlertSettings.self, from: Data(withValue.utf8))
        XCTAssertEqual(s3?.projectsConfigDirOverride, "~/.claude/cpm/profiles/personal")
    }

    func testPruneDropsOldDays() {
        var aggs: [String: DailyAggregate] = [
            "2026-05-01": DailyAggregate(day: "2026-05-01"),
            "2026-06-20": DailyAggregate(day: "2026-06-20"),
        ]
        Aggregator.prune(&aggs, onOrAfter: "2026-06-01")
        XCTAssertNil(aggs["2026-05-01"])
        XCTAssertNotNil(aggs["2026-06-20"])
    }

    func testRecostUsesStoredRawModel() {
        var pricing = PricingTable(
            models: [
                "opus": ModelPrice(input: 15, output: 75, cacheRead: 1.5, cacheWrite5m: 18.75, cacheWrite1h: 30),
                "claude-opus-4-8": ModelPrice(input: 10, output: 50, cacheRead: 1.0, cacheWrite5m: 12.0, cacheWrite1h: 20),
            ],
            fallback: nil,
            discountPercent: 0
        )
        var aggs: [String: DailyAggregate] = [:]
        let r = UsageRecord(id: "a", day: "2026-06-20", hour: 0, model: "opus", rawModel: "claude-opus-4-8",
                            usage: TokenUsage(input: 1_000_000), projectDir: "")
        Aggregator.fold(records: [r], into: &aggs, pricing: pricing)
        XCTAssertEqual(aggs["2026-06-20"]?.perModel["opus"]?.cost ?? 0, 10.0, accuracy: 1e-9)

        pricing.models["claude-opus-4-8"] = ModelPrice(input: 8, output: 40, cacheRead: 0.8, cacheWrite5m: 10, cacheWrite1h: 16)
        Aggregator.recost(&aggs, pricing: pricing)
        XCTAssertEqual(aggs["2026-06-20"]?.perModel["opus"]?.cost ?? 0, 8.0, accuracy: 1e-9)
    }

    // MARK: - Data-model migration

    func testMigrateBumpsStuckV2AndClearsScanStateAndAggregates() {
        // Reproduces the context_bloat regression: a client stuck at dataVersion 2 with empty
        // taxableCacheRead. Migration must clear scanState + aggregates so the next scan re-folds
        // and backfills context-tax tokens — while preserving settings and alert/tip state.
        var snap = Persistence.Snapshot()
        snap.dataVersion = 2
        snap.aggregates = ["2026-06-20": DailyAggregate(day: "2026-06-20")]
        snap.scanState.cursors = ["/a.jsonl": 100]
        snap.scanState.seenIDs = ["id": "2026-06-20"]
        snap.settings = AlertSettings(dailyThreshold: 25, monthlyThreshold: 300)
        snap.lastAlertDay = ["daily": "2026-06-20"]
        snap.lastTipDay = ["opus_heavy": "2026-06-20"]

        let result = Persistence.migrate(snap)

        XCTAssertTrue(result.didMigrate)
        XCTAssertEqual(result.snapshot.dataVersion, Persistence.currentDataVersion)
        XCTAssertTrue(result.snapshot.aggregates.isEmpty)
        XCTAssertTrue(result.snapshot.scanState.cursors.isEmpty)
        XCTAssertTrue(result.snapshot.scanState.seenIDs.isEmpty)
        XCTAssertEqual(result.snapshot.settings.dailyThreshold, 25)
        XCTAssertEqual(result.snapshot.settings.monthlyThreshold, 300)
        XCTAssertEqual(result.snapshot.lastAlertDay["daily"], "2026-06-20")
        XCTAssertEqual(result.snapshot.lastTipDay["opus_heavy"], "2026-06-20")
    }

    func testMigrateIsNoOpAtCurrentVersion() {
        var snap = Persistence.Snapshot()
        snap.dataVersion = Persistence.currentDataVersion
        snap.aggregates = ["2026-06-20": DailyAggregate(day: "2026-06-20")]
        snap.scanState.cursors = ["/a.jsonl": 100]

        let result = Persistence.migrate(snap)

        XCTAssertFalse(result.didMigrate)
        XCTAssertEqual(result.snapshot.dataVersion, Persistence.currentDataVersion)
        XCTAssertFalse(result.snapshot.aggregates.isEmpty, "current-version data must be left intact")
        XCTAssertFalse(result.snapshot.scanState.cursors.isEmpty)
    }

    func testMigrateFromPreProjectVersionAlsoReScans() {
        var snap = Persistence.Snapshot()
        snap.dataVersion = 0
        snap.aggregates = ["2026-06-20": DailyAggregate(day: "2026-06-20")]

        let result = Persistence.migrate(snap)

        XCTAssertTrue(result.didMigrate)
        XCTAssertEqual(result.snapshot.dataVersion, Persistence.currentDataVersion)
        XCTAssertTrue(result.snapshot.aggregates.isEmpty)
    }

    // MARK: - Day bucketing

    func testLocalDayParsesISO() {
        XCTAssertEqual(DayBucket.localDay(fromISO: "2026-06-18T12:00:00.000Z"), "2026-06-18")
        XCTAssertEqual(DayBucket.localDay(fromISO: "2026-06-18T12:00:00Z"), "2026-06-18")
        XCTAssertNil(DayBucket.localDay(fromISO: "not-a-date"))
    }

    // MARK: - Alerts

    func testDailyAlertFiresOncePerDay() {
        let settings = AlertSettings(dailyThreshold: 10, monthlyThreshold: nil)
        let first = AlertManager.decide(
            todayCost: 12, monthCost: 12, settings: settings, lastAlertDay: [:], today: "2026-06-20")
        XCTAssertEqual(first.notifications.count, 1)
        XCTAssertEqual(first.lastAlertDay["daily"], "2026-06-20")

        let second = AlertManager.decide(
            todayCost: 20, monthCost: 20, settings: settings, lastAlertDay: first.lastAlertDay, today: "2026-06-20")
        XCTAssertTrue(second.notifications.isEmpty)
        XCTAssertEqual(second.lastAlertDay["daily"], "2026-06-20")
    }

    func testNoAlertBelowThreshold() {
        let settings = AlertSettings(dailyThreshold: 50, monthlyThreshold: 100)
        let d = AlertManager.decide(
            todayCost: 10, monthCost: 30, settings: settings, lastAlertDay: [:], today: "2026-06-20")
        XCTAssertTrue(d.notifications.isEmpty)
    }

    func testMonthlyAlertFiresOncePerMonth() {
        let settings = AlertSettings(dailyThreshold: nil, monthlyThreshold: 50)
        let first = AlertManager.decide(
            todayCost: 10, monthCost: 60, settings: settings, lastAlertDay: [:], today: "2026-06-20")
        XCTAssertEqual(first.notifications.count, 1)
        XCTAssertEqual(first.lastAlertDay["monthly"], "2026-06")

        let second = AlertManager.decide(
            todayCost: 10, monthCost: 80, settings: settings, lastAlertDay: first.lastAlertDay, today: "2026-06-25")
        XCTAssertTrue(second.notifications.isEmpty)

        let third = AlertManager.decide(
            todayCost: 10, monthCost: 60, settings: settings, lastAlertDay: first.lastAlertDay, today: "2026-07-01")
        XCTAssertEqual(third.notifications.count, 1)
        XCTAssertEqual(third.lastAlertDay["monthly"], "2026-07")
    }

    // MARK: - Scan state

    func testScanStatePrunes() {
        var state = ScanState()
        state.cursors = ["/exists.jsonl": 10, "/gone.jsonl": 5]
        state.seenIDs = ["old": "2026-05-01", "new": "2026-06-20"]
        state.prune(existingPaths: ["/exists.jsonl"], retainSeenIDsOnOrAfter: "2026-06-01")
        XCTAssertEqual(Array(state.cursors.keys), ["/exists.jsonl"])
        XCTAssertNil(state.seenIDs["old"])
        XCTAssertNotNil(state.seenIDs["new"])
    }

    func testScanStatePrunesEmptyState() {
        var state = ScanState()
        state.prune(existingPaths: [], retainSeenIDsOnOrAfter: "2026-06-01")
        XCTAssertTrue(state.cursors.isEmpty)
        XCTAssertTrue(state.seenIDs.isEmpty)
    }

    func testScanStatePrunesAllRetainedWhenCutoffEarly() {
        var state = ScanState()
        state.cursors = ["/a.jsonl": 1, "/b.jsonl": 2]
        state.seenIDs = ["id1": "2026-06-10", "id2": "2026-06-20"]
        // Cutoff is very old → all IDs retained
        state.prune(existingPaths: ["/a.jsonl", "/b.jsonl"], retainSeenIDsOnOrAfter: "2020-01-01")
        XCTAssertEqual(state.cursors.count, 2)
        XCTAssertEqual(state.seenIDs.count, 2)
    }

    func testScanStatePrunesAllDroppedWhenCutoffFuture() {
        var state = ScanState()
        state.cursors = ["/a.jsonl": 1]
        state.seenIDs = ["id1": "2026-06-10", "id2": "2026-06-20"]
        // Cutoff is past all IDs → all dropped
        state.prune(existingPaths: ["/a.jsonl"], retainSeenIDsOnOrAfter: "2099-01-01")
        XCTAssertTrue(state.seenIDs.isEmpty)
    }

    func testScanStatePrunesExactBoundaryRetained() {
        var state = ScanState()
        state.seenIDs = ["exact": "2026-06-01", "before": "2026-05-31"]
        state.prune(existingPaths: [], retainSeenIDsOnOrAfter: "2026-06-01")
        XCTAssertNotNil(state.seenIDs["exact"], "Entry exactly at cutoff should be retained (>= comparison)")
        XCTAssertNil(state.seenIDs["before"], "Entry before cutoff should be pruned")
    }

    // MARK: - Aggregation edge cases

    func testFoldEmptyRecordsNoOp() {
        var aggs: [String: DailyAggregate] = [:]
        Aggregator.fold(records: [], into: &aggs, pricing: .default)
        XCTAssertTrue(aggs.isEmpty)
    }

    func testFoldEmptyRecordsPreservesExisting() {
        var aggs: [String: DailyAggregate] = [
            "2026-06-20": DailyAggregate(day: "2026-06-20"),
        ]
        Aggregator.fold(records: [], into: &aggs, pricing: .default)
        XCTAssertEqual(aggs.count, 1)
    }

    func testFoldRawModelUpdatedToLatest() {
        // H1 fix: when two records of the same family arrive on the same day with
        // different rawModels, the stored rawModel must be the most recently seen one.
        var aggs: [String: DailyAggregate] = [:]
        let r1 = UsageRecord(id: "a", day: "2026-06-20", hour: 0, model: "opus", rawModel: "claude-opus-4-1",
                             usage: TokenUsage(input: 1_000), projectDir: "")
        let r2 = UsageRecord(id: "b", day: "2026-06-20", hour: 0, model: "opus", rawModel: "claude-opus-4-8",
                             usage: TokenUsage(input: 1_000), projectDir: "")
        Aggregator.fold(records: [r1, r2], into: &aggs, pricing: .default)
        XCTAssertEqual(aggs["2026-06-20"]?.perModel["opus"]?.rawModel, "claude-opus-4-8",
                       "rawModel should be updated to the latest record's value")
    }

    func testProviderPrefixStrippedForExactKeyLookup() {
        let pricing = PricingTable.default
        let usage = TokenUsage(cacheRead: 1_000_000)
        // bedrock/ prefix stripped -> us.anthropic.claude-sonnet-5 -> Bedrock US exact key ($0.22/MTok)
        let bedrockCost = pricing.cost(of: usage, family: "sonnet", rawModel: "bedrock/us.anthropic.claude-sonnet-5")
        XCTAssertEqual(bedrockCost, 0.22, accuracy: 1e-9,
                       "Bedrock-routed sonnet-5 should use us.anthropic rate ($0.22/MTok cacheRead)")
        // Direct API -> claude-sonnet-5 exact key ($0.20/MTok)
        let directCost = pricing.cost(of: usage, family: "sonnet", rawModel: "claude-sonnet-5")
        XCTAssertEqual(directCost, 0.20, accuracy: 1e-9,
                       "Direct-API sonnet-5 should use $0.20/MTok cacheRead")
        XCTAssertEqual(bedrockCost / directCost, 1.1, accuracy: 1e-9,
                       "Bedrock rate should be 10% above direct API rate")
    }

    func testStripProviderPrefix() {
        XCTAssertEqual(ModelNormalizer.stripProviderPrefix("bedrock/us.anthropic.claude-sonnet-5"), "us.anthropic.claude-sonnet-5")
        XCTAssertEqual(ModelNormalizer.stripProviderPrefix("vertex_ai/claude-sonnet-5"), "claude-sonnet-5")
        XCTAssertEqual(ModelNormalizer.stripProviderPrefix("claude-sonnet-5"), "claude-sonnet-5")
        XCTAssertEqual(ModelNormalizer.stripProviderPrefix("anthropic.claude-haiku-4-5"), "anthropic.claude-haiku-4-5")
        XCTAssertEqual(ModelNormalizer.stripProviderPrefix("some-future-model"), "some-future-model")
        XCTAssertEqual(ModelNormalizer.stripProviderPrefix(""), "")
    }

    func testBedrockUSRegionalPricing() {
        let pricing = PricingTable.default
        let usage = TokenUsage(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000)
        // Direct API: $2 + $10 + $0.20 = $12.20
        XCTAssertEqual(pricing.cost(of: usage, family: "sonnet", rawModel: "claude-sonnet-5"), 12.20, accuracy: 1e-9)
        // Bedrock US: $2.20 + $11 + $0.22 = $13.42
        XCTAssertEqual(pricing.cost(of: usage, family: "sonnet", rawModel: "bedrock/us.anthropic.claude-sonnet-5"), 13.42, accuracy: 1e-9)
    }

    func testFoldMixedRawModelsInSameFamilyPricedPerRecord() {
        let pricing = PricingTable.default
        var aggs: [String: DailyAggregate] = [:]
        let r1 = UsageRecord(id: "a", day: "2026-06-20", hour: 0, model: "sonnet",
                             rawModel: "claude-sonnet-5",
                             usage: TokenUsage(cacheRead: 10_000_000), projectDir: "proj")
        let r2 = UsageRecord(id: "b", day: "2026-06-20", hour: 1, model: "sonnet",
                             rawModel: "bedrock/us.anthropic.claude-sonnet-5",
                             usage: TokenUsage(cacheRead: 1_000_000), projectDir: "proj")
        Aggregator.fold(records: [r1, r2], into: &aggs, pricing: pricing)
        let cost = aggs["2026-06-20"]!.perModel["sonnet"]!.cost
        // r1: 10M * $0.20/MTok (direct API) = $2.00
        // r2: 1M * $0.22/MTok (Bedrock US) = $0.22
        XCTAssertEqual(cost, 2.22, accuracy: 1e-9,
                       "Each record must be priced at its own rate (direct vs Bedrock)")
    }

    // MARK: - Semver comparison

    func testSemverNewerPatch() {
        XCTAssertTrue(UpdateChecker.isNewer("0.1.1", than: "0.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.1.0", than: "0.1.1"))
    }

    func testSemverNewerMinor() {
        XCTAssertTrue(UpdateChecker.isNewer("0.2.0", than: "0.1.9"))
        XCTAssertFalse(UpdateChecker.isNewer("0.1.9", than: "0.2.0"))
    }

    func testSemverNewerMajor() {
        XCTAssertTrue(UpdateChecker.isNewer("1.0.0", than: "0.9.9"))
        XCTAssertFalse(UpdateChecker.isNewer("0.9.9", than: "1.0.0"))
    }

    func testSemverTwoDigitComponents() {
        XCTAssertTrue(UpdateChecker.isNewer("1.10.0", than: "1.9.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.9.0", than: "1.10.0"))
    }

    func testSemverEqualNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("1.0.0", than: "1.0.0"))
    }

    func testSemverDevTreatedAsZero() {
        // "dev" parses to [] (no numeric parts), which is equivalent to 0.0.0
        XCTAssertTrue(UpdateChecker.isNewer("0.1.0", than: "dev"))
        XCTAssertTrue(UpdateChecker.isNewer("0.0.1", than: "dev"))
    }

    // MARK: - Fix 1: Sonnet 5 exact-key pricing

    func testSonnet5PricedAtNewRate() {
        let pricing = PricingTable.default
        let usage = TokenUsage(input: 1_000_000, output: 1_000_000)
        // $2 input + $10 output = $12, not the old $3 + $15 = $18
        XCTAssertEqual(pricing.cost(of: usage, family: "sonnet", rawModel: "claude-sonnet-5"), 12.0, accuracy: 1e-9)
    }

    func testSonnet55PricedAtNewRate() {
        let pricing = PricingTable.default
        let usage = TokenUsage(input: 1_000_000, output: 1_000_000)
        XCTAssertEqual(pricing.cost(of: usage, family: "sonnet", rawModel: "claude-sonnet-5-5"), 12.0, accuracy: 1e-9)
    }

    func testSonnet46StillUsesFamilyRate() {
        let pricing = PricingTable.default
        let usage = TokenUsage(input: 1_000_000, output: 1_000_000)
        // $3 + $15 = $18 (family rate, no exact-key override)
        XCTAssertEqual(pricing.cost(of: usage, family: "sonnet", rawModel: "claude-sonnet-4-6"), 18.0, accuracy: 1e-9)
    }

    // MARK: - Fix 2: Opus 5.5 exact-key pricing

    func testOpus55PricedAtNewRate() {
        let pricing = PricingTable.default
        let usage = TokenUsage(input: 1_000_000, output: 1_000_000)
        // $4 input + $20 output = $24, not the family $5 + $25 = $30
        XCTAssertEqual(pricing.cost(of: usage, family: "opus", rawModel: "claude-opus-5-5"), 24.0, accuracy: 1e-9)
    }

    func testOpus55CacheReadRate() {
        let pricing = PricingTable.default
        let usage = TokenUsage(cacheRead: 1_000_000)
        // $0.20/M, not the family $0.50/M
        XCTAssertEqual(pricing.cost(of: usage, family: "opus", rawModel: "claude-opus-5-5"), 0.20, accuracy: 1e-9)
    }

    // MARK: - Fix 5: Fable 5.1 cache-read rate

    func testFable51CacheReadRate() {
        let pricing = PricingTable.default
        let usage = TokenUsage(cacheRead: 1_000_000)
        XCTAssertEqual(pricing.cost(of: usage, family: "fable", rawModel: "claude-fable-5-1"), 0.25, accuracy: 1e-9)
    }

    func testFable5CacheReadStillUsesFamilyRate() {
        let pricing = PricingTable.default
        let usage = TokenUsage(cacheRead: 1_000_000)
        // Older generation uses family $1.00/M
        XCTAssertEqual(pricing.cost(of: usage, family: "fable", rawModel: "claude-fable-5"), 1.00, accuracy: 1e-9)
    }

    // MARK: - Fix 3: Fast-mode surcharge

    func testFastModeOpus48DoubleCost() {
        let pricing = PricingTable.default
        let usage = TokenUsage(input: 1_000_000, output: 1_000_000)
        let baseCost = pricing.cost(of: usage, family: "opus", rawModel: "claude-opus-4-8")
        // base = $5 + $25 = $30

        var aggs: [String: DailyAggregate] = [:]
        let rec = UsageRecord(id: "a", day: "2026-06-20", hour: 0, model: "opus", rawModel: "claude-opus-4-8",
                              usage: usage, projectDir: "", isFast: true)
        Aggregator.fold(records: [rec], into: &aggs, pricing: pricing)
        // Fast doubles the cost: $30 * 2 = $60
        XCTAssertEqual(aggs["2026-06-20"]?.totalCost ?? 0, baseCost * 2, accuracy: 1e-9)
        XCTAssertEqual(aggs["2026-06-20"]?.totalCost ?? 0, 60.0, accuracy: 1e-9)
    }

    func testFastModeSonnet5Unaffected() {
        let pricing = PricingTable.default
        let usage = TokenUsage(input: 1_000_000, output: 1_000_000)
        let baseCost = pricing.cost(of: usage, family: "sonnet", rawModel: "claude-sonnet-5")

        var aggsStd: [String: DailyAggregate] = [:]
        let recStd = UsageRecord(id: "a", day: "2026-06-20", hour: 0, model: "sonnet", rawModel: "claude-sonnet-5",
                                 usage: usage, projectDir: "")
        Aggregator.fold(records: [recStd], into: &aggsStd, pricing: pricing)

        var aggsFast: [String: DailyAggregate] = [:]
        let recFast = UsageRecord(id: "b", day: "2026-06-20", hour: 0, model: "sonnet", rawModel: "claude-sonnet-5",
                                  usage: usage, projectDir: "", isFast: true)
        Aggregator.fold(records: [recFast], into: &aggsFast, pricing: pricing)

        // No fastMultiplier for sonnet → same cost
        XCTAssertEqual(aggsStd["2026-06-20"]?.totalCost ?? 0, baseCost, accuracy: 1e-9)
        XCTAssertEqual(aggsFast["2026-06-20"]?.totalCost ?? 0, baseCost, accuracy: 1e-9)
    }

    // MARK: - Fix 4: Web search cost

    func testWebSearchCostAdded() {
        let pricing = PricingTable.default
        let usage = TokenUsage(input: 1_000_000, webSearchRequests: 3)
        // $5 input + 3 * $0.01 = $5.03
        XCTAssertEqual(pricing.cost(of: usage, family: "opus", rawModel: "claude-opus-4-8"), 5.03, accuracy: 1e-9)
    }

    // MARK: - Fix 6: Domestic surcharge

    func testDomesticSurchargeAdds10Percent() {
        let pricing = PricingTable.default
        let usage = TokenUsage(input: 1_000_000)
        let baseCost = pricing.cost(of: usage, family: "sonnet", rawModel: "claude-sonnet-5")
        // base = $2. Domestic surcharge = 10% = $0.20. Total = $2.20

        var aggs: [String: DailyAggregate] = [:]
        let rec = UsageRecord(id: "a", day: "2026-06-20", hour: 0, model: "sonnet", rawModel: "claude-sonnet-5",
                              usage: usage, projectDir: "", isDomestic: true)
        Aggregator.fold(records: [rec], into: &aggs, pricing: pricing)
        XCTAssertEqual(aggs["2026-06-20"]?.totalCost ?? 0, baseCost * 1.1, accuracy: 1e-9)
    }

    func testFastAndDomesticMultiply() {
        let pricing = PricingTable.default
        let usage = TokenUsage(input: 1_000_000, output: 1_000_000)
        let baseCost = pricing.cost(of: usage, family: "opus", rawModel: "claude-opus-4-8")
        // base = $30. fast=2, domestic=1.1 → 2*1.1 = 2.2x → $66

        var aggs: [String: DailyAggregate] = [:]
        let rec = UsageRecord(id: "a", day: "2026-06-20", hour: 0, model: "opus", rawModel: "claude-opus-4-8",
                              usage: usage, projectDir: "", isFast: true, isDomestic: true)
        Aggregator.fold(records: [rec], into: &aggs, pricing: pricing)
        XCTAssertEqual(aggs["2026-06-20"]?.totalCost ?? 0, baseCost * 2.2, accuracy: 1e-9)
        XCTAssertEqual(aggs["2026-06-20"]?.totalCost ?? 0, 66.0, accuracy: 1e-9)
    }

    // MARK: - Mixed-bucket regression: fast + standard in same day/model

    func testMixedFastAndStandardSameModel() {
        let pricing = PricingTable.default
        let usage = TokenUsage(input: 1_000_000)
        let basePer = pricing.cost(of: usage, family: "opus", rawModel: "claude-opus-4-8")
        // basePer = $5 per record.
        // Record 1: standard → surcharge $0. Record 2: fast → surcharge $5 (2x-1=1x of base).
        // Total = cost(2M input) + surcharge = $10 + $5 = $15

        var aggs: [String: DailyAggregate] = [:]
        let std = UsageRecord(id: "a", day: "2026-06-20", hour: 0, model: "opus", rawModel: "claude-opus-4-8",
                              usage: usage, projectDir: "")
        let fast = UsageRecord(id: "b", day: "2026-06-20", hour: 0, model: "opus", rawModel: "claude-opus-4-8",
                               usage: usage, projectDir: "", isFast: true)
        Aggregator.fold(records: [std, fast], into: &aggs, pricing: pricing)

        let model = aggs["2026-06-20"]?.perModel["opus"]
        XCTAssertNotNil(model)
        // base cost of 2M input = $10, plus surcharge from fast record = $5 → $15
        XCTAssertEqual(model?.cost ?? 0, basePer * 3, accuracy: 1e-9)
        XCTAssertEqual(model?.cost ?? 0, 15.0, accuracy: 1e-9)
        XCTAssertEqual(model?.surchargeUSD ?? 0, basePer, accuracy: 1e-9)
    }

    // MARK: - Recost preserves surchargeUSD

    func testRecostPreservesSurcharge() {
        var pricing = PricingTable.default

        var aggs: [String: DailyAggregate] = [:]
        let usage = TokenUsage(input: 1_000_000)
        let rec = UsageRecord(id: "a", day: "2026-06-20", hour: 0, model: "opus", rawModel: "claude-opus-4-8",
                              usage: usage, projectDir: "", isFast: true)
        Aggregator.fold(records: [rec], into: &aggs, pricing: pricing)

        let origCost = aggs["2026-06-20"]?.perModel["opus"]?.cost ?? 0
        let origSurcharge = aggs["2026-06-20"]?.perModel["opus"]?.surchargeUSD ?? 0
        XCTAssertEqual(origCost, 10.0, accuracy: 1e-9)  // $5 base * 2 fast
        XCTAssertEqual(origSurcharge, 5.0, accuracy: 1e-9)

        // Change base rate
        pricing.models["claude-opus-4-8"] = ModelPrice(input: 8, output: 40, cacheRead: 0.8, cacheWrite5m: 10, cacheWrite1h: 16, fastMultiplier: 2)
        Aggregator.recost(&aggs, pricing: pricing)

        let newCost = aggs["2026-06-20"]?.perModel["opus"]?.cost ?? 0
        let newSurcharge = aggs["2026-06-20"]?.perModel["opus"]?.surchargeUSD ?? 0
        // surchargeUSD preserved at $5 (not recomputed at new rate), base recosted to $8 → $8 + $5 = $13
        XCTAssertEqual(newSurcharge, 5.0, accuracy: 1e-9)
        XCTAssertEqual(newCost, 13.0, accuracy: 1e-9)
    }

    // MARK: - Backward compatibility: pre-change pricing.json decodes through new types

    func testOldPricingJsonDecodesWithNewTypes() {
        let oldJson = """
        {
          "version": 3,
          "models": {
            "fable":  { "input": 10.0, "output": 50.0, "cacheRead": 1.00, "cacheWrite5m": 12.50, "cacheWrite1h": 20.0 },
            "opus":   { "input": 5.0,  "output": 25.0, "cacheRead": 0.50, "cacheWrite5m": 6.25,  "cacheWrite1h": 10.0 },
            "sonnet": { "input": 3.0,  "output": 15.0, "cacheRead": 0.30, "cacheWrite5m": 3.75,  "cacheWrite1h": 6.0  },
            "haiku":  { "input": 1.0,  "output": 5.0,  "cacheRead": 0.10, "cacheWrite5m": 1.25,  "cacheWrite1h": 2.0  },
            "luna":   { "input": 1.1,  "output": 6.6,  "cacheRead": 0.0,  "cacheWrite5m": 0.0, "cacheWrite1h": 0.0 },
            "terra":  { "input": 2.75, "output": 16.5, "cacheRead": 0.0,  "cacheWrite5m": 0.0, "cacheWrite1h": 0.0 },
            "sol":    { "input": 5.5,  "output": 33.0, "cacheRead": 0.0,  "cacheWrite5m": 0.0, "cacheWrite1h": 0.0 },
            "claude-opus-4-1": { "input": 15.0, "output": 75.0, "cacheRead": 1.50, "cacheWrite5m": 18.75, "cacheWrite1h": 30.0 }
          },
          "fallback": { "input": 5.0, "output": 25.0, "cacheRead": 0.50, "cacheWrite5m": 6.25, "cacheWrite1h": 10.0 },
          "discountPercent": 0
        }
        """
        let table = try? JSONDecoder().decode(PricingTable.self, from: Data(oldJson.utf8))
        XCTAssertNotNil(table, "Old pricing.json must decode through new PricingTable type")
        XCTAssertEqual(table?.version, 3)
        XCTAssertNil(table?.webSearchCost)
        XCTAssertNil(table?.usOnlyMultiplier)
        XCTAssertEqual(table?.models["opus"]?.input, 5.0)
        XCTAssertEqual(table?.models["opus"]?.output, 25.0)
        XCTAssertNil(table?.models["opus"]?.fastMultiplier)
        XCTAssertEqual(table?.models["claude-opus-4-1"]?.input, 15.0)

        // web search cost defaults to 0, usOnly defaults to 1 at use sites
        let usage = TokenUsage(input: 1_000_000, webSearchRequests: 5)
        let cost = table?.cost(of: usage, family: "opus", rawModel: "claude-opus-4-8") ?? 0
        // $5 input + 5 * $0 (nil webSearchCost) = $5
        XCTAssertEqual(cost, 5.0, accuracy: 1e-9)
    }

    // MARK: - Backward compatibility: old TokenUsage/ModelUsage JSON without new fields

    func testOldTokenUsageJsonDecodes() {
        let oldJson = #"{"input":100,"output":200,"cacheRead":50,"cacheWrite5m":30,"cacheWrite1h":20}"#
        let usage = try? JSONDecoder().decode(TokenUsage.self, from: Data(oldJson.utf8))
        XCTAssertNotNil(usage, "Old TokenUsage JSON without webSearchRequests must decode")
        XCTAssertEqual(usage?.input, 100)
        XCTAssertEqual(usage?.output, 200)
        XCTAssertEqual(usage?.cacheRead, 50)
        XCTAssertEqual(usage?.cacheWrite5m, 30)
        XCTAssertEqual(usage?.cacheWrite1h, 20)
        XCTAssertEqual(usage?.webSearchRequests, 0)
    }

    func testOldModelUsageJsonDecodes() {
        let oldJson = #"""
        {
          "model": "opus",
          "rawModel": "claude-opus-4-8",
          "usage": { "input": 1000000, "output": 0, "cacheRead": 0, "cacheWrite5m": 0, "cacheWrite1h": 0 },
          "cost": 5.0
        }
        """#
        let mu = try? JSONDecoder().decode(ModelUsage.self, from: Data(oldJson.utf8))
        XCTAssertNotNil(mu, "Old ModelUsage JSON without surchargeUSD must decode")
        XCTAssertEqual(mu?.model, "opus")
        XCTAssertEqual(mu?.cost, 5.0)
        XCTAssertEqual(mu?.surchargeUSD, 0)
        XCTAssertEqual(mu?.usage.webSearchRequests, 0)
    }

    func testOldModelUsageInsideDailyAggregateDecodes() {
        let json = #"""
        {
          "day": "2026-06-20",
          "perModel": { "opus": { "model": "opus", "rawModel": "claude-opus-4-8",
            "usage": { "input": 1000000, "output": 0, "cacheRead": 0, "cacheWrite5m": 0, "cacheWrite1h": 0 },
            "cost": 5.0 } },
          "perProject": {}
        }
        """#
        let agg = try? JSONDecoder().decode(DailyAggregate.self, from: Data(json.utf8))
        XCTAssertNotNil(agg)
        XCTAssertEqual(agg?.perModel["opus"]?.cost, 5.0)
        XCTAssertEqual(agg?.perModel["opus"]?.surchargeUSD, 0)
        XCTAssertEqual(agg?.perModel["opus"]?.usage.input, 1_000_000)
        XCTAssertEqual(agg?.perModel["opus"]?.usage.webSearchRequests, 0)
    }

    // MARK: - Version bump

    func testDefaultPricingTableVersion4() {
        XCTAssertEqual(PricingTable.default.version, 4)
    }
}
