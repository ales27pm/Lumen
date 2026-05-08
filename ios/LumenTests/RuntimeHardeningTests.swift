import XCTest
@testable import Lumen

final class RuntimeHardeningTests: XCTestCase {
    func testModelStorageDocumentsDirectoryThrowsWhenUnavailable() {
        XCTAssertThrowsError(try ModelStorage.documentsDirectoryURL(candidateDirectories: [])) { error in
            XCTAssertEqual(error as? ModelStorage.StorageError, .documentDirectoryUnavailable)
        }
    }

    func testFileStoreDocumentsDirectoryThrowsWhenUnavailable() {
        XCTAssertThrowsError(try FileStore.documentsDirectoryURL(candidateDirectories: [])) { error in
            XCTAssertEqual(error as? FileStore.FileStoreError, .documentDirectoryUnavailable)
        }
    }

    func testLocationReferenceExtractorReturnsFailureForInvalidPattern() {
        let result = LocationReferenceExtractor.makeCoordinateRegex(pattern: "[")
        guard case let .failure(error) = result else {
            return XCTFail("Expected regex compilation to fail")
        }
        XCTAssertEqual(error, .invalidPattern("["))
    }
}
