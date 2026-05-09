import Foundation
import Testing
@testable import Lumen

struct E2EScenarioGenerationTests {
    @Test func toolCoverageScenarioIDsAreUnique() {
        let ids = E2ETestScenario.allToolCoverage.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func toolCoverageVariantsPreserveExpectedIntent() {
        let byID = Dictionary(uniqueKeysWithValues: E2ETestScenario.allToolCoverage.map { ($0.id, $0) })
        let baseScenarios = E2ETestScenario.allToolCoverage.filter { !$0.id.contains("-variant-") }
        for base in baseScenarios {
            let variantB = byID["\(base.id)-variant-b"]
            let variantC = byID["\(base.id)-variant-c"]
            #expect(variantB != nil)
            #expect(variantC != nil)
            #expect(variantB?.expectedIntent == base.expectedIntent)
            #expect(variantC?.expectedIntent == base.expectedIntent)
        }
    }

    @Test func toolCoverageCountMatchesThreeVariantsPerBaseScenario() {
        let baseCount = E2ETestScenario.allToolCoverage.filter { !$0.id.contains("-variant-") }.count
        #expect(E2ETestScenario.allToolCoverage.count == baseCount * 3)
    }
}

struct E2EBackwardCompatibilityTests {
    @Test func e2eResultDecodesWithoutPerformanceMatrix() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "scenarioID": "s",
          "title": "t",
          "prompt": "p",
          "expectedIntent": "chat",
          "actualIntent": "chat",
          "passed": true,
          "failures": [],
          "finalText": "ok",
          "missingHints": [],
          "rewriteAttempted": false,
          "rewriteSuccess": false,
          "events": [],
          "startedAt": "2026-01-01T00:00:00Z",
          "finishedAt": "2026-01-01T00:00:01Z",
          "rawFinalPrefix": "",
          "sanitizedFinalPrefix": "",
          "rawFinalHadUnsafeLeakage": false,
          "sanitizedFinalRemovedArtifacts": [],
          "outputHygieneFailures": []
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let result = try decoder.decode(E2ETestResult.self, from: Data(json.utf8))
        #expect(result.performanceMatrix == nil)
    }
}
