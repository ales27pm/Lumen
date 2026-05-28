import XCTest
@testable import Lumen

final class ContactsLookupToolPolicyTests: XCTestCase {
    func testBackgroundDenied() async {
        let tool = ContactsLookupTool()
        let inv = ToolInvocation(id: UUID(), toolID: "contacts.lookup", arguments: ["query":"john"], source: .backgroundTrigger, conversationID: nil, turnID: nil, createdAt: Date())
        let res = await tool.execute(invocation: inv, context: .init(isForeground: false, appState: nil, modelContext: nil, permissionRegistry: .shared, metricsStore: .shared))
        XCTAssertEqual(res.status, .denied)
    }
}
