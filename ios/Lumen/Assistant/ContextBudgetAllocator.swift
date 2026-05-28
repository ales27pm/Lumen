import Foundation

struct ContextBudgetSections: Sendable {
    let system: Int
    let history: Int
    let memories: Int
    let rag: Int
    let tools: Int
    let runtime: Int
}

enum ContextBudgetAllocator {
    static func allocate(maxChars: Int) -> ContextBudgetSections {
        ContextBudgetSections(system: Int(Double(maxChars)*0.18), history: Int(Double(maxChars)*0.34), memories: Int(Double(maxChars)*0.18), rag: Int(Double(maxChars)*0.2), tools: Int(Double(maxChars)*0.06), runtime: maxChars - Int(Double(maxChars)*0.96))
    }
}
