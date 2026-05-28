import Foundation

struct AssistantGroundingContext: Codable, Sendable {
    let memoryCount: Int
    let ragCount: Int
    let toolCount: Int
    let estimatedChars: Int
}
