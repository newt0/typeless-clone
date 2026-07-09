import Testing
import Foundation
@testable import KoeCore

@Suite("Percentiles")
struct PercentilesTests {
    @Test("empty input yields nil")
    func empty() {
        #expect(Percentiles.value([], percentile: 50) == nil)
    }

    @Test("nearest-rank P50/P95 over a known distribution")
    func nearestRank() {
        let values = Array(1...100).shuffled()
        #expect(Percentiles.value(values, percentile: 50) == 50)
        #expect(Percentiles.value(values, percentile: 95) == 95)
        #expect(Percentiles.value([7], percentile: 95) == 7)
    }
}

@Suite("DictationSample")
struct DictationSampleTests {
    @Test("durations become milliseconds; missing stamps become nil")
    func sampleFromMetrics() {
        var metrics = DictationMetrics()
        let base = Date(timeIntervalSince1970: 1_000)
        metrics.tKeyUp = base
        metrics.tSTTFinal = base.addingTimeInterval(0.4)
        metrics.tLLMDone = base.addingTimeInterval(1.2)
        metrics.tInsertDone = base.addingTimeInterval(1.45)
        let sample = DictationSample(
            createdAt: base, utterance: 3, outcome: "pasted",
            degraded: false, appBundleID: "com.apple.TextEdit", metrics: metrics
        )
        #expect(sample.sttFinalizeMs == 400)
        #expect(sample.llmMs == 800)
        #expect(sample.insertionMs == 250)
        #expect(sample.endToEndMs == 1450)
        // No recording-start stamp → derived-from-it fields simply absent.
        #expect(DictationMetrics.gapMs(metrics.tKeyDown, metrics.tKeyUp) == nil)
    }
}
