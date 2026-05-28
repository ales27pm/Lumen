import XCTest
@testable import Lumen

final class LegacyGroundingCacheTests: XCTestCase {
    func testTTLAndIsolation() async {
        let cache = LegacyGroundingCache(ttl: 1)
        let key1 = LegacyGroundingCache.Key(conversationID: UUID(), turnID: UUID(), userHash: 1, background: false)
        let bundle = LegacyGroundingBundle(grounding: .init(memoryCount: 0, ragCount: 0, toolCount: 0, estimatedChars: 0), sections: [], renderedPromptContext: "", secureTools: [], metricsSummary: "")
        await cache.put(key1, bundle: bundle, now: Date())
        XCTAssertNotNil(await cache.get(key1, now: Date()))
        XCTAssertNil(await cache.get(key1, now: Date().addingTimeInterval(2)))
    }
}
